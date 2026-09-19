import XCTest
@testable import PomodoroPlugin

/// 番茄钟引擎状态机回归：阶段转移、随机提醒微休息、专注剩余冻结恢复、
/// 暂停/跳过语义与倒计时格式。全部注入固定随机源与显式时间，无真实定时器。
final class PomodoroEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func config(
        focus: TimeInterval = 1500,
        rest: TimeInterval = 300,
        microBreak: TimeInterval = 10,
        reminderMin: TimeInterval = 180,
        reminderMax: TimeInterval = 300
    ) -> PomodoroEngineConfig {
        PomodoroEngineConfig(
            focusDuration: focus,
            restDuration: rest,
            microBreakDuration: microBreak,
            reminderInterval: reminderMin...max(reminderMax, reminderMin)
        )
    }

    private func makeEngine(reminderInterval: TimeInterval) -> PomodoroEngine {
        var engine = PomodoroEngine()
        engine.makeReminderInterval = { reminderInterval }
        return engine
    }

    // MARK: 启动

    func testStartBeginsFocusAndSchedulesReminder() {
        var engine = makeEngine(reminderInterval: 180)
        XCTAssertEqual(engine.phase, .idle)

        let event = engine.start(now: base, config: config())
        XCTAssertEqual(event, .focusStarted)
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(1500))
        XCTAssertEqual(engine.nextReminderAt, base.addingTimeInterval(180))
        XCTAssertEqual(engine.remaining(now: base), 1500, accuracy: 0.001)
        XCTAssertEqual(engine.progress(now: base), 0, accuracy: 0.0001)

        // 运行中重复 start 无效。
        XCTAssertNil(engine.start(now: base, config: config()))
        XCTAssertEqual(engine.phase, .focus)
    }

    func testReminderIntervalClampedToAtLeastOneSecond() {
        // 默认随机源返回 0：引擎钳制 ≥ 1s，防止退化配置形成提醒风暴。
        var engine = PomodoroEngine()
        _ = engine.start(now: base, config: config())
        XCTAssertEqual(engine.nextReminderAt, base.addingTimeInterval(1))
    }

    // MARK: 随机提醒 → 微休息 → 回归专注

    func testReminderFiresMicroBreakAndResumesRemainingFocus() {
        var engine = makeEngine(reminderInterval: 180)
        engine.start(now: base, config: config())

        // 提醒到期 → 微休息，专注剩余被冻结。
        var event = engine.tick(now: base.addingTimeInterval(181), config: config())
        XCTAssertEqual(event, .microBreakStarted)
        XCTAssertEqual(engine.phase, .microBreak)
        XCTAssertNil(engine.nextReminderAt)
        XCTAssertEqual(engine.frozenFocusRemaining ?? -1, 1500 - 181, accuracy: 0.001)

        // 微休息未结束时 tick 无转移。
        XCTAssertNil(engine.tick(now: base.addingTimeInterval(185), config: config()))
        XCTAssertEqual(engine.phase, .microBreak)

        // 微休息结束 → 回归专注：剩余时间续算，提醒重新调度。
        event = engine.tick(now: base.addingTimeInterval(191), config: config())
        XCTAssertEqual(event, .focusStarted)
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(191 + 1500 - 181))
        XCTAssertEqual(engine.nextReminderAt, base.addingTimeInterval(191 + 180))
        XCTAssertNil(engine.frozenFocusRemaining)

        // 进度基于原专注总时长连续，不因微休息重启。
        let expected = 1 - Double(1500 - 181) / 1500
        XCTAssertEqual(engine.progress(now: base.addingTimeInterval(191)), expected, accuracy: 0.001)
    }

    // MARK: 专注 ↔ 休息循环

    func testFocusCompletionEntersRestAndRestCompletionRestartsFocus() {
        // 提醒间隔长于专注时长：专注完成优先于提醒。
        var engine = makeEngine(reminderInterval: 10_000)
        engine.start(now: base, config: config())

        let event = engine.tick(now: base.addingTimeInterval(1500), config: config())
        XCTAssertEqual(event, .focusCompleted)
        XCTAssertEqual(engine.phase, .rest)
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(1500 + 300))
        XCTAssertNil(engine.nextReminderAt)
        // 休息中不调度提醒。
        XCTAssertNil(engine.tick(now: base.addingTimeInterval(1600), config: config()))

        let restart = engine.tick(now: base.addingTimeInterval(1800), config: config())
        XCTAssertEqual(restart, .focusStarted)
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(1800 + 1500))
        XCTAssertEqual(engine.nextReminderAt, base.addingTimeInterval(1800 + 10_000))
    }

    // MARK: 暂停

    func testPauseFreezesPhaseAndReminder() {
        var engine = makeEngine(reminderInterval: 180)
        engine.start(now: base, config: config())

        engine.togglePause(now: base.addingTimeInterval(60))
        XCTAssertEqual(engine.pausedRemaining ?? -1, 1440, accuracy: 0.001)
        XCTAssertEqual(engine.pausedReminderRemaining ?? -1, 120, accuracy: 0.001)
        XCTAssertNil(engine.phaseEndsAt)
        XCTAssertNil(engine.nextReminderAt)

        // 暂停期间时间流逝不推进任何阶段。
        XCTAssertNil(engine.tick(now: base.addingTimeInterval(10_000), config: config()))
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(engine.remaining(now: base.addingTimeInterval(10_000)), 1440, accuracy: 0.001)

        // 恢复：从恢复时刻重新锚定阶段结束与提醒。
        engine.togglePause(now: base.addingTimeInterval(10_000))
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(10_000 + 1500 - 60))
        XCTAssertEqual(engine.nextReminderAt, base.addingTimeInterval(10_000 + 120))
        XCTAssertNil(engine.pausedRemaining)
    }

    // MARK: 跳过

    func testSkipFocusGoesToRestAndSkipRestRestartsFocus() {
        var engine = makeEngine(reminderInterval: 180)
        engine.start(now: base, config: config())

        var event = engine.skip(now: base.addingTimeInterval(100), config: config())
        XCTAssertEqual(event, .focusSkipped)
        XCTAssertEqual(engine.phase, .rest)
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(100 + 300))

        event = engine.skip(now: base.addingTimeInterval(200), config: config())
        XCTAssertEqual(event, .focusStarted)
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(200 + 1500))
    }

    func testSkipMicroBreakResumesRemainingFocus() {
        var engine = makeEngine(reminderInterval: 180)
        engine.start(now: base, config: config())
        _ = engine.tick(now: base.addingTimeInterval(181), config: config())
        XCTAssertEqual(engine.phase, .microBreak)

        let event = engine.skip(now: base.addingTimeInterval(183), config: config())
        XCTAssertEqual(event, .focusStarted)
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(engine.phaseEndsAt, base.addingTimeInterval(183 + 1500 - 181))
        XCTAssertEqual(engine.nextReminderAt, base.addingTimeInterval(183 + 180))
    }

    // MARK: 停止

    func testStopReturnsToIdle() {
        var engine = makeEngine(reminderInterval: 180)
        engine.start(now: base, config: config())
        _ = engine.tick(now: base.addingTimeInterval(181), config: config())
        XCTAssertEqual(engine.phase, .microBreak)

        engine.stop()
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertNil(engine.phaseEndsAt)
        XCTAssertNil(engine.nextReminderAt)
        XCTAssertNil(engine.frozenFocusRemaining)
        XCTAssertNil(engine.pausedRemaining)
        XCTAssertEqual(engine.remaining(now: base), 0, accuracy: 0.001)
        XCTAssertEqual(engine.progress(now: base), 0, accuracy: 0.0001)
    }

    // MARK: 评分闸门（.awaitingRating）

    /// 休息结束且仍有未评价的专注 → 冻结在 `.awaitingRating`，不自动开下一个专注。
    func testRestCompletionFreezesWhenRatingPending() {
        var engine = makeEngine(reminderInterval: 10_000)
        engine.isRatingPending = { true }
        engine.start(now: base, config: config())
        XCTAssertEqual(engine.tick(now: base.addingTimeInterval(1500), config: config()), .focusCompleted)

        let event = engine.tick(now: base.addingTimeInterval(1800), config: config())
        XCTAssertEqual(event, .awaitingRatingEntered)
        XCTAssertEqual(engine.phase, .awaitingRating)
        XCTAssertNil(engine.phaseEndsAt)
        XCTAssertNil(engine.nextReminderAt)
        // 冻结态进度条恒满（无剩余可走）。
        XCTAssertEqual(engine.remaining(now: base.addingTimeInterval(10_000)), 0, accuracy: 0.001)
        XCTAssertEqual(engine.progress(now: base.addingTimeInterval(10_000)), 1, accuracy: 0.0001)
    }

    /// 冻结态：tick 不推进、skip 被禁（"不可跳过"的落地）、暂停无事可做。
    func testAwaitingRatingRejectsTickSkipAndPause() {
        var engine = makeEngine(reminderInterval: 10_000)
        engine.isRatingPending = { true }
        engine.start(now: base, config: config())
        _ = engine.tick(now: base.addingTimeInterval(1500), config: config())
        _ = engine.tick(now: base.addingTimeInterval(1800), config: config())
        XCTAssertEqual(engine.phase, .awaitingRating)

        XCTAssertNil(engine.tick(now: base.addingTimeInterval(99_999), config: config()))
        XCTAssertNil(engine.skip(now: base.addingTimeInterval(99_999), config: config()))
        XCTAssertEqual(engine.phase, .awaitingRating)

        engine.togglePause(now: base.addingTimeInterval(99_999))
        XCTAssertNil(engine.phaseEndsAt)
        XCTAssertNil(engine.pausedRemaining)
    }

    /// 评分处理完毕 → 从冻结态直接续上下一个专注。
    func testResolveRatingStartsNextFocus() {
        var engine = makeEngine(reminderInterval: 180)
        engine.isRatingPending = { true }
        engine.start(now: base, config: config())
        _ = engine.tick(now: base.addingTimeInterval(1500), config: config())
        _ = engine.tick(now: base.addingTimeInterval(1800), config: config())

        // 闸门已放开（用户评了 / 删了 / 超时作废）后放行。
        engine.isRatingPending = { false }
        let resumeAt = base.addingTimeInterval(2000)
        XCTAssertEqual(engine.resolveRating(now: resumeAt, config: config()), .focusStarted)
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(engine.phaseEndsAt, resumeAt.addingTimeInterval(1500))
        XCTAssertEqual(engine.nextReminderAt, resumeAt.addingTimeInterval(180))

        // 非冻结态调用是空操作。
        XCTAssertNil(engine.resolveRating(now: resumeAt, config: config()))
    }

    func testStopFromAwaitingRatingReturnsToIdle() {
        var engine = makeEngine(reminderInterval: 10_000)
        engine.isRatingPending = { true }
        engine.start(now: base, config: config())
        _ = engine.tick(now: base.addingTimeInterval(1500), config: config())
        _ = engine.tick(now: base.addingTimeInterval(1800), config: config())

        engine.stop()
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertNil(engine.phaseEndsAt)
        // 闸门仍在（待评分记录没被处理），但此时 start 由 store 层拒绝。
        XCTAssertTrue(engine.isRatingPending())
    }

    func testNoRatingPendingKeepsAutoRestartBehavior() {
        // 默认闸门恒 false：存量行为（休息结束自动开下一个专注）不受影响。
        var engine = makeEngine(reminderInterval: 10_000)
        engine.start(now: base, config: config())
        _ = engine.tick(now: base.addingTimeInterval(1500), config: config())
        XCTAssertEqual(
            engine.tick(now: base.addingTimeInterval(1800), config: config()),
            .focusStarted
        )
    }

    // MARK: 倒计时文本

    /// 主视图固定 `HH:MM:SS`：不随剩余时间跨 1 小时切位数（宽度稳定是
    /// 空闲态预告与运行中无缝续接的前提，见 Agent Note
    /// 2026-09-20-pomodoro-idle-countdown-format-split）。
    func testCountdownTextFormatting() {
        XCTAssertEqual(pomodoroCountdownText(0), "00:00:00")
        XCTAssertEqual(pomodoroCountdownText(65), "00:01:05")
        XCTAssertEqual(pomodoroCountdownText(1500), "00:25:00")
        XCTAssertEqual(pomodoroCountdownText(2400), "00:40:00")
        XCTAssertEqual(pomodoroCountdownText(-3), "00:00:00")
        XCTAssertEqual(pomodoroCountdownText(3600), "01:00:00")
        XCTAssertEqual(pomodoroCountdownText(3661), "01:01:01")
    }

    /// 摘要芯片固定 `MM:SS`：分钟允许超 60，不为省位数丢精度。
    func testCountdownCompactFormatting() {
        XCTAssertEqual(pomodoroCountdownCompact(0), "00:00")
        XCTAssertEqual(pomodoroCountdownCompact(65), "01:05")
        XCTAssertEqual(pomodoroCountdownCompact(2400), "40:00")
        XCTAssertEqual(pomodoroCountdownCompact(3600), "60:00")
        XCTAssertEqual(pomodoroCountdownCompact(3900), "65:00")
        XCTAssertEqual(pomodoroCountdownCompact(-3), "00:00")
    }
}
