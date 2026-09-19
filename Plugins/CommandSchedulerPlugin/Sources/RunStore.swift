import Foundation
import NotchCenterKit

// MARK: - 输出写入槽（执行期，后台线程）
//
// 决策 5：边跑边 append 落盘。输出不攒内存——`A`（跑完才写）的致命缺陷不是
// "看不到进度"，而是**崩了就什么都没有**；定时任务最需要日志的恰恰是"跑到
// 一半被杀"那种。已产生的输出自然落盘，实时可见是副产品。
//
// 写入策略（比 note 初稿细化的两点，实现时才想清楚）：
// - **文件硬上限 1MB**：超过即停止写入并置 truncated。没有上限的话一条
//   `yes` 就能把磁盘写满。
// - 文件是普通 append-only 日志；"头部 64KB + 尾部 64KB"的投影在**读取时**
//   做（`RunStore.runOutput`），不改变写入路径——这样运行中读文件尾就是最新
//   进度（watch 语义），跑完读文件头尾才是完整上下文。
//
// 线程模型：读管道线程独占 `append`，`finish` 在进程退出后由同一线程调用；
// 仍加锁是因为 `byteCount` 会被主线程读去更新 UI。
final class RunOutputSink: @unchecked Sendable {
    /// 单次运行输出文件的硬上限。
    static let fileLimit = 1 * 1024 * 1024

    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written = 0
    private var didHitLimit = false

    init(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    /// 追加一段输出；超出硬上限后静默丢弃（只置截断标记）。
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !didHitLimit else { return }
        let remaining = Self.fileLimit - written
        guard remaining > 0 else {
            didHitLimit = true
            return
        }
        if data.count > remaining {
            handle.write(data.prefix(remaining))
            written += remaining
            didHitLimit = true
        } else {
            handle.write(data)
            written += data.count
        }
    }

    /// 收尾：关闭句柄。返回（落盘字节数，是否截断）。
    func finish() -> (bytes: Int, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        return (written, didHitLimit)
    }

    /// 已落盘字节数（主线程读去更新 UI 的进度型展示）。
    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return written
    }
}

// MARK: - 索引与输出文件管理（主线程）
//
// 索引与输出分离：run 元数据（时间、状态、退出码、耗时、命令快照、输出文件名）
// 走 `StateStore` 单键 JSON；完整输出走 `resourceDirectory("runs")` 一 run 一文件。
// 单键 JSON 每次追加要读全量再写全量——500 条 × 10KB 就是每次跑完命令重写
// 5MB，不能接受。
@MainActor
final class RunStore {
    /// 每任务保留的 run 条数上限。
    static let runsPerTaskLimit = 50
    /// 输出目录总量上限（字节）。与条数上限并存：50 条 × 1MB 的极端情况下
    /// 条数限制根本拦不住体积。
    static let outputDirectoryLimit = 200 * 1024 * 1024
    /// 读取投影：头部与尾部各保留的窗口。
    static let readWindow = 64 * 1024

    private let stateStore: StateStore
    /// 输出目录；`resourceDirectory` 失败时降级为 nil（索引仍可用，只是没有输出）。
    nonisolated let runsDirectory: URL?

    init(stateStore: StateStore) {
        self.stateStore = stateStore
        runsDirectory = try? stateStore.resourceDirectory(named: "runs")
    }

    // MARK: 任务表

    private static let tasksKey = "tasks"

    func loadTasks() -> [ScheduledTask] {
        stateStore.object([ScheduledTask].self, forKey: Self.tasksKey) ?? []
    }

    func saveTasks(_ tasks: [ScheduledTask]) {
        try? stateStore.setObject(tasks, forKey: Self.tasksKey)
    }

    // MARK: run 索引（每任务一键）

    private static func runsKey(_ taskID: String) -> String {
        // taskID 是 UUID 字符串（十六进制 + 连字符），必然满足 StateStore 的键约束。
        "runs." + taskID
    }

    func loadRuns(taskID: String) -> [TaskRun] {
        stateStore.object([TaskRun].self, forKey: Self.runsKey(taskID)) ?? []
    }

    /// 按开始时刻倒序的全部 run（含各状态）。
    func runsNewestFirst(taskID: String) -> [TaskRun] {
        loadRuns(taskID: taskID).sorted { $0.startedAt > $1.startedAt }
    }

    func latestRun(taskID: String) -> TaskRun? {
        loadRuns(taskID: taskID).max { $0.startedAt < $1.startedAt }
    }

    /// 插入或更新一条 run，并按条数上限裁剪（连输出文件一起删）。
    func upsert(_ run: TaskRun) {
        var runs = loadRuns(taskID: run.taskID)
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        store(runs, taskID: run.taskID)
    }

    /// 批量写回某任务的 run 列表并按条数上限裁剪。
    func store(_ runs: [TaskRun], taskID: String) {
        // 运行中的记录不参与裁剪：它还没有输出文件可删，裁掉会让"正在跑"
        // 的历史凭空消失（UI 里表现为任务突然没有在跑的 run）。
        let running = runs.filter { !$0.status.isFinished }
        var finished = runs.filter { $0.status.isFinished }
        var trimmed: [TaskRun] = []
        if finished.count > Self.runsPerTaskLimit {
            finished.sort { $0.startedAt > $1.startedAt }
            trimmed = Array(finished.suffix(from: Self.runsPerTaskLimit))
            finished = Array(finished.prefix(Self.runsPerTaskLimit))
        }
        try? stateStore.setObject(finished + running, forKey: Self.runsKey(taskID))
        for stale in trimmed {
            removeOutput(forRunID: stale.id)
        }
        enforceOutputDirectoryLimit()
    }

    /// 删除某任务的 run 索引与全部输出（任务被删除时调用）。
    func removeAll(taskID: String) {
        for run in loadRuns(taskID: taskID) {
            removeOutput(forRunID: run.id)
        }
        stateStore.removeValue(forKey: Self.runsKey(taskID))
        stateStore.removeValue(forKey: Self.skipKey(taskID))
    }

    /// 宿主启动时收敛僵尸记录：上次进程崩了/被强杀，历史里会留着永远
    /// `running` 的条目。返回修正条数。
    @discardableResult
    func reconcileInterruptedRuns(tasks: [ScheduledTask], now: Date = Date()) -> Int {
        var fixed = 0
        for task in tasks {
            var runs = loadRuns(taskID: task.id)
            var changed = false
            for index in runs.indices where runs[index].status == .running {
                runs[index].status = .interrupted
                runs[index].endedAt = now
                changed = true
                fixed += 1
            }
            if changed {
                try? stateStore.setObject(runs, forKey: Self.runsKey(task.id))
            }
        }
        return fixed
    }

    // MARK: 错过留痕

    private static func skipKey(_ taskID: String) -> String {
        "skips." + taskID
    }

    func skipLog(taskID: String) -> SkipLog {
        stateStore.object(SkipLog.self, forKey: Self.skipKey(taskID)) ?? SkipLog()
    }

    func recordSkip(taskID: String, reason: SkipLog.Reason, at date: Date = Date()) {
        var log = skipLog(taskID: taskID)
        log.record(reason, at: date)
        try? stateStore.setObject(log, forKey: Self.skipKey(taskID))
    }

    // MARK: 排期起点（每任务一键）
    //
    // 「不补跑」要成立就必须知道上次计时的起点：宿主重启后靠它判断停机期间
    // 是不是漏过时刻。单独一个键而不是写进任务表——否则每触发一次都要重写
    // 整份任务表 JSON。

    private static func fireKey(_ taskID: String) -> String {
        "fire." + taskID
    }

    func lastFired(taskID: String) -> Date? {
        stateStore.object(Date.self, forKey: Self.fireKey(taskID))
    }

    func setLastFired(at date: Date, taskID: String) {
        try? stateStore.setObject(date, forKey: Self.fireKey(taskID))
    }

    // MARK: 输出文件

    nonisolated func outputURL(forRunID id: String) -> URL? {
        runsDirectory?.appendingPathComponent(id + ".log")
    }

    func makeSink(forRunID id: String) -> RunOutputSink? {
        guard let url = outputURL(forRunID: id) else { return nil }
        return RunOutputSink(url: url)
    }

    func removeOutput(forRunID id: String) {
        guard let url = outputURL(forRunID: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 读取一次执行的输出。
    ///
    /// - 运行中（`live`）：读文件**尾部**窗口——看进度要的是最新几行（watch 语义）。
    /// - 已结束：超过「头 + 尾」窗口时投影成 头部 + 省略标记 + 尾部。
    ///   只留头部会切掉报错，只留尾部会切掉上下文。
    func runOutput(for run: TaskRun, live: Bool = false) -> RunOutput {
        guard let url = outputURL(forRunID: run.id),
              let data = try? Data(contentsOf: url) else {
            return RunOutput(text: "", truncated: false, missing: true)
        }
        if live {
            let window = data.suffix(Self.readWindow)
            return RunOutput(
                text: String(decoding: window, as: UTF8.self),
                truncated: run.truncated,
                missing: false
            )
        }
        let window = Self.readWindow
        guard data.count > window * 2 else {
            return RunOutput(
                text: String(decoding: data, as: UTF8.self),
                truncated: run.truncated,
                missing: false
            )
        }
        let head = data.prefix(window)
        let tail = data.suffix(window)
        let omitted = data.count - window * 2
        let marker = "\n⋯ [omitted \(omitted) bytes] ⋯\n"
        let text = String(decoding: head, as: UTF8.self)
            + marker
            + String(decoding: tail, as: UTF8.self)
        return RunOutput(text: text, truncated: true, missing: false)
    }

    /// 输出目录总量上限：超出按最旧删除。与"每任务 50 条"并存——50 × 1MB
    /// 的极端情况下条数限制拦不住体积。
    func enforceOutputDirectoryLimit(limit: Int = RunStore.outputDirectoryLimit) {
        guard let directory = runsDirectory else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var files: [(url: URL, size: Int, modified: Date)] = []
        var total = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > limit else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// 手动清空全部输出（设置浮窗里的维护动作）。
    func clearAllOutput() {
        guard let directory = runsDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              ) else { return }
        for url in entries {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
