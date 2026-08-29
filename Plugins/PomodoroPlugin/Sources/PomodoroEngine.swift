import Foundation

// MARK: - 番茄钟引擎（纯逻辑，时间由调用方注入，随机源可替换，单元测试友好）

/// 番茄钟阶段：空闲 → 专注 ⇄（随机提示音触发）微休息 → 专注 → 休息 → 专注 …
enum PomodoroPhase: Equatable {
    case idle
    case focus
    case microBreak
    case rest
}

/// 引擎产生的事件（store 据此播放音效 / 记录统计）。
enum PomodoroEvent: Equatable {
    /// 专注开始（会话启动、休息结束、微休息结束回归）。
    case focusStarted
    /// 专注自然完成 → 进入休息（计入今日完成数）。
    case focusCompleted
    /// 手动跳过专注 → 进入休息（播放结束音但不计入完成数）。
    case focusSkipped
    /// 随机提示音触发，进入微休息。
    case microBreakStarted
}

/// 引擎运行参数（由 store 从用户设置换算）。
struct PomodoroEngineConfig: Equatable {
    var focusDuration: TimeInterval
    var restDuration: TimeInterval
    var microBreakDuration: TimeInterval
    /// 随机提示音的间隔区间（秒）；min > max 时由配置净化保证。
    var reminderInterval: ClosedRange<TimeInterval>
}

/// 番茄钟状态机：所有时间锚定绝对时刻（`Date`），不依赖 tick 精度；
/// 暂停/微休息把当前阶段剩余冻结为时长，恢复时重新锚定，计时不受
/// tick 间隔与系统挂起漂移影响。
struct PomodoroEngine {
    private(set) var phase: PomodoroPhase = .idle
    /// 当前阶段结束时刻（暂停期间为 nil）。
    private(set) var phaseEndsAt: Date?
    /// 当前阶段总时长（进度条基准；微休息回归专注时保持原专注总时长，进度连续）。
    private(set) var phaseTotal: TimeInterval = 0
    /// 下次随机提示音时刻（仅专注阶段、未暂停时非 nil）。
    private(set) var nextReminderAt: Date?
    /// 微休息打断时冻结的专注剩余时长（回归专注时恢复）。
    private(set) var frozenFocusRemaining: TimeInterval?
    /// 微休息打断时冻结的专注总时长（进度基准，回归时一并恢复保持连续）。
    private(set) var frozenFocusTotal: TimeInterval?
    /// 暂停时冻结的当前阶段剩余时长。
    private(set) var pausedRemaining: TimeInterval?
    /// 暂停时冻结的随机提示音剩余时长。
    private(set) var pausedReminderRemaining: TimeInterval?

    /// 随机提醒间隔生成器：返回距调度时刻的秒数。生产注入随机实现，
    /// 测试注入固定值；结果被钳制 ≥ 1s 防止退化配置形成提醒风暴。
    var makeReminderInterval: () -> TimeInterval = { 0 }

    // MARK: 查询

    /// 当前阶段剩余时长（暂停时返回冻结值）。
    func remaining(now: Date) -> TimeInterval {
        if let paused = pausedRemaining { return max(paused, 0) }
        guard let endsAt = phaseEndsAt else { return 0 }
        return max(endsAt.timeIntervalSince(now), 0)
    }

    /// 当前阶段进度 0...1。
    func progress(now: Date) -> Double {
        guard phaseTotal > 0 else { return 0 }
        return min(max(1 - remaining(now: now) / phaseTotal, 0), 1)
    }

    // MARK: 状态转移

    /// 开始会话：空闲 → 专注。
    mutating func start(now: Date, config: PomodoroEngineConfig) -> PomodoroEvent? {
        guard phase == .idle else { return nil }
        return beginFocus(now: now, config: config, event: .focusStarted)
    }

    /// 周期驱动：按当前时刻推进阶段转移（每次至多一个转移）。
    mutating func tick(now: Date, config: PomodoroEngineConfig) -> PomodoroEvent? {
        guard pausedRemaining == nil else { return nil }
        switch phase {
        case .idle:
            return nil
        case .focus:
            // 阶段完成优先于提醒（两者同时到期时直接进入休息）。
            if let endsAt = phaseEndsAt, now >= endsAt {
                return beginRest(now: now, config: config, event: .focusCompleted)
            }
            if let reminderAt = nextReminderAt, now >= reminderAt {
                return beginMicroBreak(now: now, config: config)
            }
            return nil
        case .microBreak:
            guard let endsAt = phaseEndsAt, now >= endsAt, let remaining = frozenFocusRemaining else {
                return nil
            }
            return resumeFocus(now: now, remaining: remaining, event: .focusStarted)
        case .rest:
            guard let endsAt = phaseEndsAt, now >= endsAt else { return nil }
            return beginFocus(now: now, config: config, event: .focusStarted)
        }
    }

    /// 跳过当前阶段：专注→休息、微休息→回归专注、休息→专注。暂停中也允许。
    mutating func skip(now: Date, config: PomodoroEngineConfig) -> PomodoroEvent? {
        pausedRemaining = nil
        pausedReminderRemaining = nil
        switch phase {
        case .idle:
            return nil
        case .focus:
            return beginRest(now: now, config: config, event: .focusSkipped)
        case .microBreak:
            guard let remaining = frozenFocusRemaining else { return nil }
            return resumeFocus(now: now, remaining: remaining, event: .focusStarted)
        case .rest:
            return beginFocus(now: now, config: config, event: .focusStarted)
        }
    }

    /// 暂停/恢复当前阶段（专注阶段连同随机提示音一起冻结）。
    mutating func togglePause(now: Date) {
        if let remaining = pausedRemaining {
            phaseEndsAt = now.addingTimeInterval(remaining)
            if let reminderRemaining = pausedReminderRemaining {
                nextReminderAt = now.addingTimeInterval(reminderRemaining)
            }
            pausedRemaining = nil
            pausedReminderRemaining = nil
        } else {
            guard let endsAt = phaseEndsAt else { return }
            pausedRemaining = max(endsAt.timeIntervalSince(now), 0)
            phaseEndsAt = nil
            if let reminderAt = nextReminderAt {
                pausedReminderRemaining = max(reminderAt.timeIntervalSince(now), 0)
                nextReminderAt = nil
            }
        }
    }

    /// 停止会话：回到空闲。
    mutating func stop() {
        phase = .idle
        phaseEndsAt = nil
        phaseTotal = 0
        nextReminderAt = nil
        frozenFocusRemaining = nil
        frozenFocusTotal = nil
        pausedRemaining = nil
        pausedReminderRemaining = nil
    }

    // MARK: 内部转移

    private mutating func beginFocus(now: Date, config: PomodoroEngineConfig, event: PomodoroEvent?) -> PomodoroEvent? {
        phase = .focus
        phaseTotal = config.focusDuration
        phaseEndsAt = now.addingTimeInterval(config.focusDuration)
        nextReminderAt = now.addingTimeInterval(max(makeReminderInterval(), 1))
        frozenFocusRemaining = nil
        frozenFocusTotal = nil
        pausedRemaining = nil
        pausedReminderRemaining = nil
        return event
    }

    private mutating func beginRest(now: Date, config: PomodoroEngineConfig, event: PomodoroEvent?) -> PomodoroEvent? {
        phase = .rest
        phaseTotal = config.restDuration
        phaseEndsAt = now.addingTimeInterval(config.restDuration)
        nextReminderAt = nil
        frozenFocusRemaining = nil
        frozenFocusTotal = nil
        pausedRemaining = nil
        pausedReminderRemaining = nil
        return event
    }

    /// 微休息结束 / 手动跳过微休息：恢复被冻结的专注剩余与总时长（进度连续）。
    private mutating func resumeFocus(now: Date, remaining: TimeInterval, event: PomodoroEvent?) -> PomodoroEvent? {
        phase = .focus
        phaseEndsAt = now.addingTimeInterval(max(remaining, 0.001))
        if let total = frozenFocusTotal, total > 0 {
            phaseTotal = total
        }
        nextReminderAt = now.addingTimeInterval(max(makeReminderInterval(), 1))
        frozenFocusRemaining = nil
        frozenFocusTotal = nil
        pausedRemaining = nil
        pausedReminderRemaining = nil
        return event
    }

    private mutating func beginMicroBreak(now: Date, config: PomodoroEngineConfig) -> PomodoroEvent? {
        let focusRemaining: TimeInterval
        if let endsAt = phaseEndsAt {
            focusRemaining = max(endsAt.timeIntervalSince(now), 0)
        } else {
            focusRemaining = 0
        }
        frozenFocusRemaining = focusRemaining
        frozenFocusTotal = phaseTotal
        phase = .microBreak
        phaseTotal = config.microBreakDuration
        phaseEndsAt = now.addingTimeInterval(config.microBreakDuration)
        nextReminderAt = nil
        return .microBreakStarted
    }
}

// MARK: - 展示辅助（纯函数，测试覆盖）

/// 秒数 → 倒计时文本：不足 1 小时 `mm:ss`，超过则 `h:mm:ss`。
func pomodoroCountdownText(_ seconds: Int) -> String {
    let total = max(seconds, 0)
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
}
