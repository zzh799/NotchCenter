import Foundation
import XCTest
@testable import PomodoroPlugin

/// 番茄钟明细档（`PomodoroHistory`）的回归：解码回落、裁剪整组丢弃、日键口径、
/// 微休息对照与总览派生量。
///
/// 数据模型的动机见 Agent Note 2026-09-10-plugin-page-blocks §8（"只记录天"
/// 不足以复盘，故拆成每次专注 + 每条微休息的明细）。
final class PomodoroHistoryTests: XCTestCase {

    // MARK: 夹具

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private func session(
        _ id: String,
        at start: Date,
        minutes: Int = 25,
        outcome: PomodoroFocusSession.Outcome = .completed,
        rating: Int? = nil
    ) -> PomodoroFocusSession {
        PomodoroFocusSession(
            id: id,
            plannedSeconds: minutes * 60,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
            outcome: outcome,
            rating: rating
        )
    }

    private func microBreak(
        _ id: String,
        sessionID: String,
        at start: Date,
        seconds: Int = 10,
        outcome: PomodoroMicroBreak.Outcome = .natural
    ) -> PomodoroMicroBreak {
        PomodoroMicroBreak(
            id: id,
            sessionID: sessionID,
            plannedSeconds: seconds,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(seconds)),
            outcome: outcome
        )
    }

    // MARK: 解码回落

    func testDecodingFallsBackToDefaultsForMissingKeys() throws {
        // 空对象：将来加字段 / 早期文件都必须还能读（逐字段 decodeIfPresent）。
        let empty = try JSONDecoder().decode(PomodoroHistory.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.sessions.isEmpty)
        XCTAssertTrue(empty.microBreaks.isEmpty)
        XCTAssertTrue(empty.dailyFallbacks.isEmpty)
        XCTAssertNil(empty.pending)
        XCTAssertTrue(empty.pendingMicroBreaks.isEmpty)

        // 只有 sessions 的旧快照：其余字段回落默认值。
        let partial = try JSONDecoder().decode(
            PomodoroHistory.self,
            from: Data(#"{"sessions":[],"dailyFallbacks":{"2026-09-01":2}}"#.utf8)
        )
        XCTAssertEqual(partial.dailyFallbacks, ["2026-09-01": 2])
        XCTAssertEqual(partial.totalRecords, 0)
    }

    func testRoundTripKeepsPendingAndMicroBreaks() throws {
        var history = PomodoroHistory()
        history.pending = session("p1", at: date(2026, 9, 10), rating: nil)
        history.pendingMicroBreaks = [
            microBreak("m1", sessionID: "p1", at: date(2026, 9, 10, hour: 10, minute: 5)),
        ]
        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(PomodoroHistory.self, from: data)
        XCTAssertEqual(decoded, history)
    }

    // MARK: 裁剪（整组丢弃：会话连同它的微休息）

    func testTrimToLimitDropsOldestSessionTogetherWithItsMicroBreaks() {
        var history = PomodoroHistory()
        let oldest = session("old", at: date(2026, 1, 1))
        history.sessions.append(oldest)
        history.microBreaks.append(contentsOf: (0..<5).map {
            microBreak("old-m\($0)", sessionID: "old", at: date(2026, 1, 1, hour: 10, minute: $0))
        })
        let base = date(2026, 6, 1)
        for index in 0..<PomodoroHistory.maxRecords {
            history.sessions.append(session("new-\(index)", at: base.addingTimeInterval(TimeInterval(index * 60))))
        }
        XCTAssertGreaterThan(history.totalRecords, PomodoroHistory.maxRecords)

        XCTAssertTrue(history.trimToLimit())

        // 只丢掉最旧那一组（1 会话 + 5 微休息），不留下孤儿微休息。
        XCTAssertEqual(history.totalRecords, PomodoroHistory.maxRecords)
        XCTAssertFalse(history.sessions.contains { $0.id == "old" })
        XCTAssertTrue(history.microBreaks.isEmpty)
    }

    func testTrimToLimitIsNoOpUnderLimit() {
        var history = PomodoroHistory()
        history.sessions.append(session("a", at: date(2026, 9, 10)))
        XCTAssertFalse(history.trimToLimit())
        XCTAssertEqual(history.sessions.count, 1)
    }

    // MARK: 日键口径

    func testCompletedCountMergesDetailAndLegacyFallback() {
        var history = PomodoroHistory()
        let day = PomodoroHistoryAnalysis.dayString(date(2026, 9, 10))
        history.sessions = [
            session("a", at: date(2026, 9, 10, hour: 9)),
            session("b", at: date(2026, 9, 10, hour: 14), outcome: .skipped),
            session("c", at: date(2026, 9, 11, hour: 9)),
        ]
        history.dailyFallbacks = [day: 2]

        // 跳过的会话不计完成数；迁移来的日汇总兜底照加。
        XCTAssertEqual(PomodoroHistoryAnalysis.completedCount(onDay: day, history: history), 3)
        XCTAssertEqual(
            PomodoroHistoryAnalysis.completedCount(
                onDay: PomodoroHistoryAnalysis.dayString(date(2026, 9, 11)),
                history: history
            ),
            1
        )
    }

    func testDailyCompletedWindowIsAscendingAndEndsToday() {
        var history = PomodoroHistory()
        let now = date(2026, 9, 10, hour: 20)
        history.sessions = [
            session("y", at: date(2026, 9, 9, hour: 9)),
            session("t1", at: date(2026, 9, 10, hour: 9)),
            session("t2", at: date(2026, 9, 10, hour: 11)),
        ]

        let window = PomodoroHistoryAnalysis.dailyCompleted(history: history, days: 3, now: now)

        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.map(\.completed), [0, 1, 2])
        XCTAssertEqual(window.last?.day, "2026-09-10")
        XCTAssertEqual(window.map(\.day), window.map(\.day).sorted())
    }

    func testHourlyCompletedBucketsByEndHour() {
        var history = PomodoroHistory()
        let day = "2026-09-10"
        history.sessions = [
            session("a", at: date(2026, 9, 10, hour: 9, minute: 40), minutes: 20),
            session("b", at: date(2026, 9, 10, hour: 10, minute: 5), minutes: 5),
            session("c", at: date(2026, 9, 10, hour: 23, minute: 50), minutes: 5),
            session("skipped", at: date(2026, 9, 10, hour: 12), outcome: .skipped),
        ]

        let buckets = PomodoroHistoryAnalysis.hourlyCompleted(onDay: day, history: history)

        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[10], 2, "9:40+20min 收在 10:00 / 10:05+5min 收在 10:10")
        XCTAssertEqual(buckets[9], 0, "按结束时刻归桶，不按开始时刻")
        XCTAssertEqual(buckets[23], 1)
        XCTAssertEqual(buckets.reduce(0, +), 3, "跳过的会话不进入节奏柱")
    }

    func testWeekdayShortLabelParsesAndFallsBack() {
        let label = PomodoroHistoryAnalysis.weekdayShortLabel(day: "2026-09-10")
        XCTAssertFalse(label.isEmpty)
        XCTAssertNotEqual(label, "2026-09-10")
        // 解析失败原样返回，绝不返回空串（柱状图横轴宁可显示原始键）。
        XCTAssertEqual(PomodoroHistoryAnalysis.weekdayShortLabel(day: "not-a-day"), "not-a-day")
    }

    // MARK: 微休息对照

    func testMicroBreakContrastGroupsSessionsByPresenceOfBreak() {
        var history = PomodoroHistory()
        history.sessions = [
            session("with-1", at: date(2026, 9, 10, hour: 9), rating: 4),
            session("with-2", at: date(2026, 9, 10, hour: 10), rating: 5),
            session("without-1", at: date(2026, 9, 10, hour: 11), rating: 2),
            session("without-2", at: date(2026, 9, 10, hour: 12), outcome: .skipped, rating: nil),
        ]
        history.microBreaks = [
            microBreak("m1", sessionID: "with-1", at: date(2026, 9, 10, hour: 9, minute: 5)),
            microBreak("m2", sessionID: "with-2", at: date(2026, 9, 10, hour: 10, minute: 5)),
        ]

        let contrast = PomodoroHistoryAnalysis.microBreakContrast(history: history)

        XCTAssertEqual(contrast.withMicroBreaks.sessionCount, 2)
        XCTAssertEqual(contrast.withMicroBreaks.ratedCount, 2)
        XCTAssertEqual(contrast.withMicroBreaks.averageRating ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(contrast.withMicroBreaks.completionRate ?? 0, 1, accuracy: 0.001)

        XCTAssertEqual(contrast.withoutMicroBreaks.sessionCount, 2)
        XCTAssertEqual(contrast.withoutMicroBreaks.completedCount, 1)
        XCTAssertEqual(contrast.withoutMicroBreaks.averageRating ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(contrast.withoutMicroBreaks.completionRate ?? 0, 0.5, accuracy: 0.001)
    }

    func testMicroBreakContrastIsEmptyWithoutSessions() {
        let contrast = PomodoroHistoryAnalysis.microBreakContrast(history: PomodoroHistory())
        XCTAssertEqual(contrast.withMicroBreaks.sessionCount, 0)
        XCTAssertEqual(contrast.withoutMicroBreaks.sessionCount, 0)
        XCTAssertNil(contrast.withMicroBreaks.averageRating)
        XCTAssertNil(contrast.withMicroBreaks.completionRate)
    }

    func testMicroBreakOutcomeCounts() {
        var history = PomodoroHistory()
        history.microBreaks = [
            microBreak("a", sessionID: "s", at: date(2026, 9, 10, hour: 9), outcome: .natural),
            microBreak("b", sessionID: "s", at: date(2026, 9, 10, hour: 10), outcome: .natural),
            microBreak("c", sessionID: "s", at: date(2026, 9, 10, hour: 11), outcome: .skippedByUser),
            microBreak("d", sessionID: "s", at: date(2026, 9, 10, hour: 12), outcome: .aborted),
        ]
        let counts = PomodoroHistoryAnalysis.microBreakOutcomeCounts(history: history)
        XCTAssertEqual(counts[.natural], 2)
        XCTAssertEqual(counts[.skippedByUser], 1)
        XCTAssertEqual(counts[.aborted], 1)
    }

    func testMicroBreakActualSecondsClampsAtZero() {
        let start = date(2026, 9, 10, hour: 9)
        let normal = microBreak("a", sessionID: "s", at: start, seconds: 12)
        XCTAssertEqual(normal.actualSeconds, 12)

        // 结束早于开始（时钟回拨等）不该报负数。
        let inverted = PomodoroMicroBreak(
            id: "b", sessionID: "s", plannedSeconds: 10,
            startedAt: start, endedAt: start.addingTimeInterval(-5), outcome: .aborted
        )
        XCTAssertEqual(inverted.actualSeconds, 0)
    }

    // MARK: 总览与迁移

    func testOverviewCountsSessionsRatingsAndDays() {
        var history = PomodoroHistory()
        history.sessions = [
            session("a", at: date(2026, 9, 10, hour: 9), rating: 5),
            session("b", at: date(2026, 9, 10, hour: 11), outcome: .skipped, rating: nil),
            session("c", at: date(2026, 9, 12, hour: 9), rating: 3),
        ]
        history.microBreaks = [microBreak("m", sessionID: "a", at: date(2026, 9, 10, hour: 9))]
        history.dailyFallbacks = ["2026-08-01": 2, "2026-08-02": 1, "2026-08-03": 0]

        let overview = PomodoroHistoryAnalysis.overview(history: history)

        XCTAssertEqual(overview.sessionCount, 3)
        XCTAssertEqual(overview.completedCount, 2)
        XCTAssertEqual(overview.ratedCount, 2)
        XCTAssertEqual(overview.averageRating ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(overview.microBreakCount, 1)
        XCTAssertEqual(overview.dayCount, 2, "9-10 与 9-12 两天有明细")
        XCTAssertEqual(overview.legacyDayCount, 2, "计数为 0 的迁移日不算")
    }

    func testMigratingLegacyStatsProducesSingleDayFallback() {
        XCTAssertEqual(
            PomodoroHistoryAnalysis.migratingLegacyStats(day: "2026-09-09", completed: 4),
            ["2026-09-09": 4]
        )
        // 旧档没有当天记录 / 计数为 0：不落空条目。
        XCTAssertTrue(
            PomodoroHistoryAnalysis.migratingLegacyStats(day: "", completed: 3).isEmpty
        )
        XCTAssertTrue(
            PomodoroHistoryAnalysis.migratingLegacyStats(day: "2026-09-09", completed: 0).isEmpty
        )
    }
}
