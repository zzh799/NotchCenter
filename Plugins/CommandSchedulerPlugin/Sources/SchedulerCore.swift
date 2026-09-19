import AppKit
import Foundation
import NotchCenterKit

// MARK: - 调度核心（插件级单例）
//
// `docs/agents/插件开发约定.md`「共享数据仍放插件级 store，不要按实例复制轮询」：
// 任务表与调度器是插件级单例，不是 per-placement。块摆两块屏上不是两份调度在跑
// 两份命令，而是两个视图观察同一个 ObservableObject（同 OpenCodeUsagePlugin）。
//
// 调度形态（决策 1）：宿主内单 Timer，**唤醒/重启不补跑**。睡醒后已过时刻一律
// 丢弃，不做积压补执行——但**留痕**（决策 4：聚合成「错过 N 次」，不塞流水）。
//
// 「不补跑」的精确实现分两处，缺一处就会变成"悄悄补跑"或"悄悄丢"：
// - Tick：定时器醒来时按 `expectedFire` 判定应到即执行（宿主卡顿导致迟到照跑，
//   不因迟到几秒就吞掉这次）。
// - 唤醒观察：`NSWorkspace.didWakeNotification` 一到就清空待触发并重新排期，
//   于是睡眠期间的那些时刻**不会**在醒来后被补执行，同时逐条记入错过。
@MainActor
final class SchedulerCore: ObservableObject {
    static let shared = SchedulerCore()

    /// 任务级 `timeoutSeconds == nil` 时使用的全局守卫超时（秒）。
    static let defaultTimeoutSeconds = 30 * 60

    // MARK: 对外状态

    @Published private(set) var tasks: [ScheduledTask] = []
    /// taskID → 正在跑的 runID。
    @Published private(set) var runningRunIDs: [String: String] = [:]
    /// taskID → 最近一条 run（任务行上显示"上次结果"）。
    @Published private(set) var latestRuns: [String: TaskRun] = [:]
    /// 数据版本号：任务表/run 记录变动即自增。视图观察它整体重算，
    /// 避免把大数组逐一塞进 @Published（也避免 Equatable 逐元素比较的开销）。
    @Published private(set) var revision: Int = 0

    // MARK: 内部

    private var store: RunStore?
    private var stateStore: StateStore?
    private weak var hostController: (any HostController)?
    private var tickTask: Task<Void, Never>?
    /// taskID → 当前排期对应的触发时刻（内存态，不持久化）。
    private var expectedFire: [String: Date] = [:]
    private var cancellations: [String: ProcessCancellation] = [:]
    private var wakeObserver: NSObjectProtocol?
    /// 全局默认守卫超时（设置浮窗可改）。
    private(set) var defaultTimeout: Int = SchedulerCore.defaultTimeoutSeconds

    private init() {}

    // MARK: 生命周期

    /// 宿主注入服务时调用（幂等：多次 attach 不重复起观察者/定时器）。
    func attach(stateStore: StateStore, hostController: any HostController) {
        if store == nil {
            let resolved = RunStore(stateStore: stateStore)
            store = resolved
            self.stateStore = stateStore
            defaultTimeout = stateStore.object(Int.self, forKey: Self.defaultTimeoutKey) ?? Self.defaultTimeoutSeconds
            tasks = resolved.loadTasks()
            // 僵尸记录收敛：宿主上次崩了/被强杀，历史里会留着永远 running 的条目。
            _ = resolved.reconcileInterruptedRuns(tasks: tasks)
            refreshLatestRuns()
            accountForDowntime()
        }
        self.hostController = hostController
        installWakeObserver()
        refreshActivitySummary()
        reschedule()
    }

    /// 宿主禁用插件/退出前调用：杀运行中的进程组、停排期、收摘要与浮窗。
    func shutdown() {
        tickTask?.cancel()
        tickTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        // 先请求取消（SIGTERM + 5s 后 SIGKILL 兜底），再同步把记录标成 aborted，
        // 不指望后台任务回来收尾——那时插件可能已经卸载了。
        let now = Date()
        for cancellation in cancellations.values {
            cancellation.cancel(.abort)
        }
        cancellations.removeAll()
        let aborting = Set(runningRunIDs.values)
        runningRunIDs.removeAll()
        if let store {
            for task in tasks {
                var runs = store.loadRuns(taskID: task.id)
                var changed = false
                for index in runs.indices where aborting.contains(runs[index].id) {
                    // 被你自己关掉不是失败——记 aborted 而不是 failed。
                    runs[index].status = .aborted
                    runs[index].endedAt = now
                    changed = true
                }
                if changed { store.store(runs, taskID: task.id) }
            }
        }
        hostController?.removeActivitySummary(id: Self.activitySummaryID)
        // 历史浮窗锚在块上，抽屉收起/插件禁用后必须跟着收（否则独立窗口残留在
        // 已消失的块上方）。
        BlockPopover.shared.dismiss()
        bumpRevision()
    }

    // MARK: 任务表维护

    func addTask(_ task: ScheduledTask) {
        tasks.append(task)
        commitTasks()
    }

    /// 覆盖一条任务。改规则/命令即视为新的排期起点：清掉 `expectedFire` 并按
    /// 「从现在起算」重新计时（否则改完规则可能立刻因旧排期到期而误触发一次）。
    func updateTask(_ task: ScheduledTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        expectedFire[task.id] = nil
        store?.setLastFired(at: Date(), taskID: task.id)
        commitTasks()
    }

    func deleteTask(id: String) {
        tasks.removeAll { $0.id == id }
        runningRunIDs[id] = nil
        latestRuns[id] = nil
        expectedFire[id] = nil
        store?.removeAll(taskID: id)
        commitTasks()
    }

    func setEnabled(_ enabled: Bool, taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].isEnabled = enabled
        // 刚启用时把计时起点设为现在：否则一次"启用"会立刻补触发上次的计划。
        store?.setLastFired(at: Date(), taskID: taskID)
        expectedFire[taskID] = nil
        commitTasks()
    }

    func setDefaultTimeout(_ seconds: Int) {
        defaultTimeout = max(seconds, 0)
        try? stateStore?.setObject(defaultTimeout, forKey: Self.defaultTimeoutKey)
        reschedule()
    }

    private func commitTasks() {
        store?.saveTasks(tasks)
        bumpRevision()
        refreshActivitySummary()
        reschedule()
    }

    // MARK: 排期

    /// 某任务的下一次触发时刻（UI 也用它显示"下次触发"）。
    func nextFireDate(for task: ScheduledTask, now: Date = Date()) -> Date? {
        ScheduleModel.next(after: now, rule: task.rule)
    }

    private func reschedule() {
        tickTask?.cancel()
        tickTask = nil
        let now = Date()
        // 只排"最近的一个"：不做全局队列（一个卡死任务不该阻塞所有任务），
        // 触发后再重排即可。
        let upcoming = tasks
            .filter(\.isEnabled)
            .compactMap { task -> (id: String, at: Date)? in
                guard let at = nextFireDate(for: task, now: now) else { return nil }
                return (task.id, at)
            }
            .min { $0.at < $1.at }
        guard let upcoming else { return }
        expectedFire[upcoming.id] = upcoming.at
        let delay = max(upcoming.at.timeIntervalSince(now), 0.05)
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func tick() {
        let now = Date()
        // 到点即执行，不因迟到几秒而吞掉这次（宿主卡顿导致的迟到是允许的；
        // 睡眠导致的迟到由唤醒观察先行清空，不会走到这里）。
        let due = tasks.filter { task in
            guard task.isEnabled, let expected = expectedFire[task.id] else { return false }
            return expected <= now
        }
        for task in due {
            expectedFire[task.id] = nil
            store?.setLastFired(at: now, taskID: task.id)
            fire(task)
        }
        reschedule()
    }

    /// 睡眠/长时间挂起：清空待触发并留痕，不补执行。
    ///
    /// 只在**睡眠**这条路径留痕：宿主被用户主动退出是我们控制不了的事，
    /// 而"机器睡了"是可解释的、用户想知道的那一类错过。
    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWake()
            }
        }
    }

    private func handleWake() {
        let now = Date()
        for task in tasks where task.isEnabled {
            guard let expected = expectedFire[task.id], expected < now else { continue }
            store?.recordSkip(taskID: task.id, reason: .offline)
            store?.setLastFired(at: now, taskID: task.id)
        }
        expectedFire.removeAll()
        bumpRevision()
        reschedule()
    }

    /// 宿主启动时补一次"停机期间的错过"：只记一条，不逐时刻展开。
    ///
    /// 停机一小时、每 1 分钟的任务理论上有 60 次错过，逐条记会把聚合日志灌满，
    /// 而用户真正需要知道的是"这段时间它没跑"——一条足够。
    private func accountForDowntime() {
        guard let store else { return }
        let now = Date()
        var missed = false
        for task in tasks where task.isEnabled {
            guard let lastFired = store.lastFired(taskID: task.id) else { continue }
            guard let next = ScheduleModel.next(after: lastFired, rule: task.rule), next <= now else { continue }
            store.recordSkip(taskID: task.id, reason: .offline, at: next)
            store.setLastFired(at: now, taskID: task.id)
            missed = true
        }
        if missed { bumpRevision() }
    }

    // MARK: 执行

    /// 手动触发（块内「立即运行」/浮窗内动作）。与定时触发共用同一条路径与
    /// 同一套并发规则；撞上正在跑的同一任务时静默忽略（这是你自己点的，不是遗漏）。
    func runNow(taskID: String) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        guard runningRunIDs[task.id] == nil else { return }
        start(task: task, trigger: .manual)
    }

    private func fire(_ task: ScheduledTask) {
        guard runningRunIDs[task.id] == nil else {
            // 上一次还在跑：跳过并留痕。与「不补跑」同源——排队等它结束再补
            // 一次，本质就是补跑。
            store?.recordSkip(taskID: task.id, reason: .running)
            bumpRevision()
            return
        }
        start(task: task, trigger: .scheduled)
    }

    private func start(task: ScheduledTask, trigger: TaskRun.Trigger) {
        guard let store else { return }
        let runID = UUID().uuidString
        let run = TaskRun(
            id: runID,
            taskID: task.id,
            trigger: trigger,
            startedAt: Date(),
            status: .running,
            snapshot: CommandSnapshot(task: task)
        )
        store.upsert(run)
        runningRunIDs[task.id] = runID
        latestRuns[task.id] = run
        bumpRevision()
        refreshActivitySummary()

        // 守卫超时：任务级 0 = 关闭；nil = 全局默认。
        var effective = task
        if task.timeoutSeconds == nil {
            effective.timeoutSeconds = defaultTimeout
        }
        let sink = store.makeSink(forRunID: runID)
        let cancellation = ProcessCancellation()
        cancellations[runID] = cancellation

        // 执行丢后台、收尾回主线程。刻意不让 detached 任务捕获 `self`——它只需要
        // 产出三元组结果，`self` 只在主执行者上下文里被引用（Swift 6 严格并发下
        // 把 MainActor 隔离的 self 送进非隔离闭包是数据竞争）。
        let work = Task.detached(priority: .utility) { () -> (RunOutcome, Int, Bool) in
            let outcome = ProcessRunner.run(task: effective, sink: sink, cancellation: cancellation)
            let written = sink?.finish() ?? (bytes: 0, truncated: false)
            return (outcome, written.bytes, written.truncated)
        }
        Task { [weak self] in
            let (outcome, bytes, truncated) = await work.value
            self?.finish(
                runID: runID,
                taskID: task.id,
                outcome: outcome,
                bytes: bytes,
                truncated: truncated
            )
        }
    }

    private func finish(
        runID: String,
        taskID: String,
        outcome: RunOutcome,
        bytes: Int,
        truncated: Bool
    ) {
        cancellations.removeValue(forKey: runID)
        guard let store else { return }
        var runs = store.loadRuns(taskID: taskID)
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].status = outcome.status
        runs[index].endedAt = Date()
        runs[index].exitCode = outcome.exitCode
        runs[index].outputBytes = bytes
        runs[index].truncated = truncated
        store.upsert(runs[index])
        if runningRunIDs[taskID] == runID {
            runningRunIDs[taskID] = nil
        }
        latestRuns[taskID] = runs[index]
        bumpRevision()
        refreshActivitySummary()
        reschedule()
    }

    // MARK: 派生数据

    private func refreshLatestRuns() {
        guard let store else { return }
        var latest: [String: TaskRun] = [:]
        for task in tasks {
            latest[task.id] = store.latestRun(taskID: task.id)
        }
        latestRuns = latest
    }

    func runs(taskID: String) -> [TaskRun] {
        store?.runsNewestFirst(taskID: taskID) ?? []
    }

    func output(for run: TaskRun) -> RunOutput {
        store?.runOutput(for: run, live: run.status == .running) ?? .empty
    }

    func skipCounts(taskID: String, now: Date = Date()) -> (skipped: Int, missed: Int) {
        store?.skipLog(taskID: taskID).counts(withinHours: 24, now: now) ?? (0, 0)
    }

    func recentSkips(taskID: String, limit: Int = 12) -> [SkipLog.Entry] {
        store?.skipLog(taskID: taskID).recent(limit: limit) ?? []
    }

    func clearAllOutput() {
        store?.clearAllOutput()
    }

    /// 输出目录位置（设置浮窗里「在访达中打开」用）。
    var outputDirectory: URL? { store?.runsDirectory }

    var isRunning: Bool { !runningRunIDs.isEmpty }

    /// 最近一次失败的任务数（任务行红点与摘要警示用）。
    var troubledTaskCount: Int {
        tasks.filter { latestRuns[$0.id]?.status.isTrouble == true }.count
    }

    private func bumpRevision() {
        revision &+= 1
    }

    // MARK: 活动摘要

    private static let activitySummaryID = "command.scheduler.summary"

    /// 摘要只表达"此刻有没有在跑"与"有没有出问题的任务"。
    ///
    /// `ActivitySummary` 没有颜色字段，所以"失败点灯"用符号表达
    /// （`exclamationmark.triangle`）——这是宿主通道能给的最诚实的映射。
    private func refreshActivitySummary() {
        guard let hostController else { return }
        if !runningRunIDs.isEmpty {
            let count = runningRunIDs.count
            hostController.showActivitySummary(ActivitySummary(
                id: Self.activitySummaryID,
                title: LF("scheduler.summary.running", count),
                subtitle: nil,
                symbolName: "clock.arrow.circlepath",
                progress: nil
            ))
        } else if troubledTaskCount > 0 {
            hostController.showActivitySummary(ActivitySummary(
                id: Self.activitySummaryID,
                title: L("scheduler.summary.failed"),
                subtitle: LF("scheduler.summary.failed.count", troubledTaskCount),
                symbolName: "exclamationmark.triangle",
                progress: nil
            ))
        } else {
            hostController.removeActivitySummary(id: Self.activitySummaryID)
        }
    }

    // MARK: 偏好

    private static let defaultTimeoutKey = "defaultTimeoutSeconds"
}
