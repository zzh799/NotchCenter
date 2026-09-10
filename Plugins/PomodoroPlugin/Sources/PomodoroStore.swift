import AppKit
import Combine
import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 番茄钟共享 store（引擎驱动 + 明细持久化 + 活动摘要 + 音效）

/// 待评分会话的最小快照（评分 UI 的全部输入）。
struct PomodoroPendingRating: Equatable {
    let sessionID: String
    /// 本次专注的计划时长（秒）——跳过的专注不评分，所以待评分恒为自然完成。
    let plannedSeconds: Int
    /// 本次专注内的微休息次数（评分时顺带告知"这次休息过几次"）。
    let microBreakCount: Int
}

/// 视图层（紧凑块 / 抽屉块 / 整页块）观察的展示快照。
struct PomodoroDisplay: Equatable {
    var phase: PomodoroPhase = .idle
    /// 当前阶段剩余秒数（向上取整）。
    var remainingSeconds: Int = 0
    /// 当前阶段进度 0...1。
    var progress: Double = 0
    var isPaused: Bool = false
    /// 今日完成的专注次数（由明细 + 日汇总兜底推导，待评分的那条也计入）。
    var completedToday: Int = 0
    /// 待评分会话；非 nil → 评分 UI 出现、`start()` 被拒。
    var pendingRating: PomodoroPendingRating?
}

/// 旧版今日统计（`stats` 键）：被 `PomodoroHistory` 取代，仅用于一次性迁移。
private struct LegacyPomodoroStats: Codable, Equatable {
    var day: String
    var completed: Int
}

/// 会话结束时刻的引擎参数（做明细时用一次）。
@MainActor
final class PomodoroStore: ObservableObject {
    static let shared = PomodoroStore()
    /// 活动摘要标识（宿主按 id 覆盖更新 / 收回）。
    static let summaryID = "pomodoro.summary"

    /// 待评分自愈窗口（Q16-B）：超过这段时间没被处理就自动作废并恢复计时。
    ///
    /// 已知代价：用户完全没放任何评分载体（没放 `pomodoro.timer`、也没放整页
    /// 番茄钟）时最坏会被冻结这么久。取舍见 Agent Note 2026-09-10-plugin-page-blocks。
    static let ratingDeadlineSeconds: TimeInterval = 60 * 60

    private static let configKey = "config"
    private static let historyKey = "history"
    private static let legacyStatsKey = "stats"

    @Published private(set) var config: PomodoroConfig
    @Published private(set) var display = PomodoroDisplay()
    /// 明细档：整页块的历史复盘直接读它。
    @Published private(set) var history = PomodoroHistory()

    private var engine = PomodoroEngine()
    private(set) var sharedStateStore: StateStore?
    private weak var hostController: (any HostController)?
    private let soundPlayer: any PomodoroSoundPlaying
    private var tickTimer: Timer?

    /// 正在进行的专注会话（**未落库**：结束 / 跳过时才生成明细）。丢弃
    /// （`stop()` 中途停止）不产生任何记录。
    private struct ActiveFocus {
        let id: String
        let plannedSeconds: Int
        let startedAt: Date
        /// 本次专注内已结束的微休息明细——随会话一起落库，避免孤儿记录。
        var microBreaks: [PomodoroMicroBreak] = []
    }

    /// 正在进行的微休息（未落库）。
    private struct OpenMicroBreak {
        let id: String
        let plannedSeconds: Int
        let startedAt: Date
    }

    private var activeFocus: ActiveFocus?
    private var openMicroBreak: OpenMicroBreak?

    init(soundPlayer: any PomodoroSoundPlaying = NSSoundPlayer()) {
        self.soundPlayer = soundPlayer
        self.config = PomodoroConfigLogic.sanitized(PomodoroConfig())

        var engine = PomodoroEngine()
        engine.makeReminderInterval = { [weak self] in
            guard let self else { return 0 }
            let interval = self.engineConfig.reminderInterval
            return Double.random(in: interval.lowerBound...max(interval.upperBound, interval.lowerBound))
        }
        // 评分闸门：引擎不认识持久化数据，闸门是它与 store 之间唯一的耦合面。
        engine.isRatingPending = { [weak self] in
            self?.history.pending != nil
        }
        self.engine = engine
    }

    /// attachServices 注入：加载持久化设置与明细（幂等，禁用后再启用会重新调用）。
    func resolve(stateStore: StateStore, hostController: any HostController) {
        sharedStateStore = stateStore
        self.hostController = hostController
        if let stored: PomodoroConfig = stateStore.object(PomodoroConfig.self, forKey: Self.configKey) {
            config = PomodoroConfigLogic.sanitized(stored)
        }
        if let stored: PomodoroHistory = stateStore.object(PomodoroHistory.self, forKey: Self.historyKey) {
            history = stored
        } else {
            migrateLegacyStatsIfNeeded(from: stateStore)
        }
        history.trimToLimit()
        publishDisplay(now: Date())
        // 重启后若还挂着一条早该作废的待评分记录，立刻自愈：否则闸门会冻住
        // `start()`，而发出待评分的那次会话可能已经是几个小时前的事。
        healPendingRatingIfExpired(now: Date())
    }

    /// 旧 `stats` 键（单条 `{day, completed}`）→ 日汇总兜底。
    /// 落成"那一天的一条计数"，**不伪造** N 条无评分明细；迁完即删旧键。
    private func migrateLegacyStatsIfNeeded(from stateStore: StateStore) {
        guard let legacy: LegacyPomodoroStats = stateStore.object(
            LegacyPomodoroStats.self,
            forKey: Self.legacyStatsKey
        ) else { return }
        history.dailyFallbacks = PomodoroHistoryAnalysis.migratingLegacyStats(
            day: legacy.day,
            completed: legacy.completed
        )
        persistHistory()
        stateStore.removeValue(forKey: Self.legacyStatsKey)
    }

    /// 插件被禁用：停止引擎、停表（不卸载数据）；摘要收回由 display 变
    /// idle 触发的 `syncSummary` 统一处理。进行中的会话与待评分记录都保留。
    func suspend() {
        discardActiveFocus()
        engine.stop()
        stopTicking()
        publishDisplay(now: Date())
    }

    // MARK: 用户操作

    func start() {
        guard engine.phase == .idle else { return }
        // 有待评分时**不许**开新专注（Q14-D 的阻塞语义落地）。不弹窗：
        // 评分条本身就在抽屉块 / 整页上，注意力引到那里即可。
        guard history.pending == nil else {
            publishDisplay(now: Date())
            return
        }
        if let event = engine.start(now: Date(), config: engineConfig) {
            handle(event)
        }
        publishDisplay(now: Date())
        startTicking()
    }

    func stop() {
        guard engine.phase != .idle else { return }
        let now = Date()
        // `stop()` 在 `.awaitingRating` 下是允许的（Q15）：待评分记录仍在，
        // `start()` 仍被拒——停的只是计时循环。
        discardActiveFocus()
        engine.stop()
        stopTicking()
        publishDisplay(now: now)
    }

    func togglePause() {
        guard engine.phase != .idle, engine.phase != .awaitingRating else { return }
        engine.togglePause(now: Date())
        publishDisplay(now: Date())
    }

    func skip() {
        guard engine.phase != .idle else { return }
        let now = Date()
        let previousPhase = engine.phase
        if let event = engine.skip(now: now, config: engineConfig) {
            handle(event)
        }
        if previousPhase == .microBreak {
            closeMicroBreak(endedAt: now, outcome: .skippedByUser)
        }
        publishDisplay(now: now)
    }

    /// 设置写入（设置界面滑杆/选择器）：净化后立即持久化。
    /// 变更对当前阶段不打断（阶段结束时刻已锚定），下次调度生效。
    func update(_ mutate: (inout PomodoroConfig) -> Void) {
        var next = config
        mutate(&next)
        let sanitized = PomodoroConfigLogic.sanitized(next)
        guard sanitized != config else { return }
        config = sanitized
        try? sharedStateStore?.setObject(sanitized, forKey: Self.configKey)
    }

    /// 设置界面试听音效。
    func preview(_ soundName: String) {
        soundPlayer.play(soundName)
    }

    // MARK: 评分（不可跳过 / 不可补评）

    /// 给待评价的专注打 1...5 分：会话连同它的微休息明细一起转正入库。
    func ratePending(_ score: Int) {
        guard let pending = history.pending, (1...5).contains(score) else { return }
        var rated = pending
        rated.rating = score
        history.sessions.append(rated)
        history.microBreaks.append(contentsOf: history.pendingMicroBreaks)
        history.pending = nil
        history.pendingMicroBreaks = []
        persistHistory()
        resumeAfterRating()
    }

    /// 删除待评价记录：该会话与它的全部微休息明细一起消失，"今日完成数"
    /// 随之减少（完成数由明细推导，没有独立计数器可对不上）。
    func discardPending() {
        guard history.pending != nil else { return }
        history.pending = nil
        history.pendingMicroBreaks = []
        persistHistory()
        resumeAfterRating()
    }

    /// 处理完待评分后从 `.awaitingRating` 续上下一个专注。
    private func resumeAfterRating() {
        let now = Date()
        if let event = engine.resolveRating(now: now, config: engineConfig) {
            handle(event)
        }
        publishDisplay(now: now)
        if engine.phase != .idle {
            startTicking()
        }
    }

    /// 待评分自愈（Q16-B）：超过 `ratingDeadlineSeconds` 未处理即自动作废
    /// （记录丢弃）并恢复计时。时间起点是**待评分创建那一刻**
    /// （`pending.endedAt` = 专注完成时刻），所以休息期间正常评分不受影响；
    /// 真正的停顿上限是"休息结束 + 60 分钟"。
    private func healPendingRatingIfExpired(now: Date) {
        guard let pending = history.pending,
              now.timeIntervalSince(pending.endedAt) >= Self.ratingDeadlineSeconds else {
            return
        }
        history.pending = nil
        history.pendingMicroBreaks = []
        persistHistory()
        resumeAfterRating()
    }

    // MARK: 引擎驱动

    private var engineConfig: PomodoroEngineConfig {
        PomodoroEngineConfig(
            focusDuration: TimeInterval(config.focusMinutes) * 60,
            restDuration: TimeInterval(config.restMinutes) * 60,
            microBreakDuration: TimeInterval(config.microBreakSeconds),
            reminderInterval:
                TimeInterval(config.reminderMinMinutes) * 60
                ... TimeInterval(config.reminderMaxMinutes) * 60
        )
    }

    private func handle(_ event: PomodoroEvent) {
        let now = Date()
        switch event {
        case .focusStarted:
            // 微休息结束回归的是**同一段**专注（引擎只把冻结的剩余恢复），
            // 所以只有"手上没有进行中会话"时才开新的一段。
            if activeFocus == nil {
                beginActiveFocus(now: now)
            }
            soundPlayer.play(config.startSound)
        case .focusCompleted:
            soundPlayer.play(config.endSound)
            completeActiveFocus(now: now)
        case .focusSkipped:
            soundPlayer.play(config.endSound)
            skipActiveFocus(now: now)
        case .microBreakStarted:
            soundPlayer.play(config.microBreakSound)
            beginMicroBreak(now: now)
        case .awaitingRatingEntered:
            // 闸门是状态提示，不是事件提醒：留给摘要与评分条表达，不配音效。
            break
        }
    }

    private func tick() {
        let now = Date()
        let previousPhase = engine.phase
        if let event = engine.tick(now: now, config: engineConfig) {
            handle(event)
        }
        // 微休息离开的三条路：自然结束（引擎在 tick 里转移）、用户跳过
        // （`skip()` 里收尾）、会话中断（`stop()` / 禁用时整段丢弃）。这里
        // 只负责"tick 把阶段移出了 microBreak"这一种。
        if previousPhase == .microBreak, engine.phase != .microBreak {
            closeMicroBreak(endedAt: now, outcome: .natural)
        }
        healPendingRatingIfExpired(now: now)
        publishDisplay(now: now)
    }

    private func publishDisplay(now: Date) {
        let next = PomodoroDisplay(
            phase: engine.phase,
            remainingSeconds: Int(engine.remaining(now: now).rounded(.up)),
            progress: engine.progress(now: now),
            isPaused: engine.pausedRemaining != nil,
            completedToday: completedToday,
            pendingRating: history.pending.map {
                PomodoroPendingRating(
                    sessionID: $0.id,
                    plannedSeconds: $0.plannedSeconds,
                    microBreakCount: history.pendingMicroBreaks.count
                )
            }
        )
        if next != display {
            display = next
        }
        syncSummary()
    }

    /// 今日完成数：明细里的自然完成 + 迁移来的日汇总兜底 + 待评分的那条。
    /// 删除待评分记录会立刻让这个数减一（Q14 的连带语义）。
    private var completedToday: Int {
        let today = PomodoroHistoryAnalysis.dayString(Date())
        var count = PomodoroHistoryAnalysis.completedCount(onDay: today, history: history)
        if let pending = history.pending,
           pending.outcome == .completed,
           PomodoroHistoryAnalysis.dayString(pending.endedAt) == today {
            count += 1
        }
        return count
    }

    // MARK: 会话生命周期

    /// 开启一段专注明细。开始时刻取引擎锚定的终点减总时长（比"发现转移的
    /// 那一刻"精确，tick 有 0.5s 粒度）。
    private func beginActiveFocus(now: Date) {
        let planned = Int(engineConfig.focusDuration)
        let startedAt = engine.phaseEndsAt?.addingTimeInterval(-TimeInterval(planned)) ?? now
        activeFocus = ActiveFocus(
            id: UUID().uuidString,
            plannedSeconds: planned,
            startedAt: startedAt
        )
    }

    /// 专注自然完成 → 生成**待评分**记录（唯一触发评分的路径）。
    private func completeActiveFocus(now: Date) {
        guard let active = activeFocus else { return }
        activeFocus = nil
        history.pending = PomodoroFocusSession(
            id: active.id,
            plannedSeconds: active.plannedSeconds,
            startedAt: active.startedAt,
            endedAt: now,
            outcome: .completed,
            rating: nil
        )
        history.pendingMicroBreaks = active.microBreaks
        persistHistory()
    }

    /// 专注被手动跳过 → 直接落一条 `skipped` 记录（不评分、不入待评分）。
    private func skipActiveFocus(now: Date) {
        guard let active = activeFocus else { return }
        activeFocus = nil
        history.sessions.append(PomodoroFocusSession(
            id: active.id,
            plannedSeconds: active.plannedSeconds,
            startedAt: active.startedAt,
            endedAt: now,
            outcome: .skipped,
            rating: nil
        ))
        history.microBreaks.append(contentsOf: active.microBreaks)
        persistHistory()
    }

    /// 丢弃进行中的会话（`stop()` / 插件被禁用）：中途放弃的专注不成记录，
    /// 它的微休息明细也一并丢弃——孤立的微休息会污染复盘对照。
    private func discardActiveFocus() {
        activeFocus = nil
        openMicroBreak = nil
    }

    private func beginMicroBreak(now: Date) {
        // 微休息的结束时刻由引擎锚定：开始时刻同样反推，比 tick 观测量精确。
        let planned = config.microBreakSeconds
        let startedAt = engine.phaseEndsAt?.addingTimeInterval(-TimeInterval(planned)) ?? now
        openMicroBreak = OpenMicroBreak(
            id: UUID().uuidString,
            plannedSeconds: planned,
            startedAt: startedAt
        )
    }

    private func closeMicroBreak(endedAt: Date, outcome: PomodoroMicroBreak.Outcome) {
        guard let open = openMicroBreak else { return }
        openMicroBreak = nil
        guard activeFocus != nil else { return }
        let sessionID = activeFocus?.id ?? ""
        // 自然结束以计划时长为准（引擎按锚定时刻精确切换，观测量会略滞后）。
        let ended = outcome == .natural
            ? open.startedAt.addingTimeInterval(TimeInterval(open.plannedSeconds))
            : endedAt
        activeFocus?.microBreaks.append(PomodoroMicroBreak(
            id: open.id,
            sessionID: sessionID,
            plannedSeconds: open.plannedSeconds,
            startedAt: open.startedAt,
            endedAt: ended,
            outcome: outcome
        ))
    }

    private func persistHistory() {
        history.trimToLimit()
        try? sharedStateStore?.setObject(history, forKey: Self.historyKey)
    }

    // MARK: 定时器（0.5s：倒计时秒级平滑 + 阶段转移及时）
    //
    // 待评分自愈也靠它：`.awaitingRating` 冻结期间表照走，否则没有 UI 可达
    // 的用户会被永久冻住。

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: 活动摘要（紧凑带迷你进度；Agent Note 2026-09-03-compact-area-activity-summary）

    /// 已提交摘要的快照键：只在「会改变芯片可见内容」的变化上重新提交——
    /// 阶段 / 暂停 / 剩余整秒任一变化即覆盖更新（同 id 不改变新旧次序），
    /// 其余 tick（进度在秒内细分）不再打搅宿主。空闲且无待评分即收回。
    private var lastSummaryKey: (phase: PomodoroPhase, isPaused: Bool, remainingSeconds: Int)?
    private var summarySubmitted = false

    /// 依据当前 display 同步摘要：空闲收回、运行中 / 等待评价覆盖提交（秒级节流）。
    private func syncSummary() {
        guard let hostController else { return }
        let d = display
        guard d.phase != .idle || d.pendingRating != nil else {
            if summarySubmitted {
                summarySubmitted = false
                lastSummaryKey = nil
                hostController.removeActivitySummary(id: Self.summaryID)
            }
            return
        }
        let key = (d.phase, d.isPaused, d.remainingSeconds)
        if let last = lastSummaryKey, last == key { return }
        lastSummaryKey = key
        summarySubmitted = true
        // 摘要不可交互，所以等待评价时只提示"去哪儿评"，不放评分控件。
        let isAwaiting = d.phase == .awaitingRating || d.pendingRating != nil
        hostController.showActivitySummary(
            ActivitySummary(
                id: Self.summaryID,
                title: PomodoroTheme.phaseTitle(for: d),
                subtitle: isAwaiting
                    ? L("summary.awaitingRating")
                    : pomodoroCountdownText(d.remainingSeconds),
                symbolName: PomodoroTheme.symbol(for: d.phase),
                progress: d.progress
            )
        )
    }
}
