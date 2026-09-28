import Foundation
import NotchCenterKit
import XCTest
@testable import ClipboardHistoryPlugin

/// 剪贴板自动清理回归：档位净化、日历到期判定（"每月"按日历月）、关闭档永不到期、
/// 首次启用只起算不清理、到期只清未置顶并落盘、被清图片的媒体文件连带回收、
/// 改档重新起算。
///
/// 定时器本身**不做真时间等待**：判定函数与 `runAutoCleanupIfDue(now:)` 的注入时间
/// 入口就是全部被测面（"60s 表每秒看一眼"这件事没有可断言的逻辑）。
@MainActor
final class ClipboardAutoCleanupTests: XCTestCase {
    // MARK: 夹具

    /// 最小假剪贴板：只有图像采集路径被用到。
    private final class StubClipboard: ClipboardReading, @unchecked Sendable {
        var changeCount = 0
        var payload = ClipboardPayload()

        func probe() -> ClipboardProbe {
            ClipboardProbe(changeCount: changeCount, typeNames: ["public.png"])
        }

        func readPayload() -> ClipboardPayload { payload }

        func writeText(_ text: String) -> Int { bump() }
        func writeFiles(_ paths: [String]) -> Int { bump() }
        func writeImage(data: Data, uti: String?) -> Int { bump() }

        func externalImageCopy(_ data: Data, uti: String = "public.png") {
            changeCount += 1
            payload = ClipboardPayload(imageData: data, imageUTI: uti)
        }

        private func bump() -> Int {
            changeCount += 1
            return changeCount
        }
    }

    private struct Harness {
        let store: ClipboardHistoryStore
        let clipboard: StubClipboard
        let root: URL
    }

    /// 固定时区日历：断言"7 天 = 604800 秒"这类算术时不受本机时区 / 夏令时影响。
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }()

    private func makeStore(
        preloaded: [ClipboardEntry] = [],
        period: ClipboardAutoCleanupPeriod? = nil,
        lastRunAt: Date? = nil
    ) -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardAutoCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let stateStore = StateStore(rootDirectory: root)
        if !preloaded.isEmpty {
            try? stateStore.setObject(preloaded, forKey: ClipboardHistoryStore.historyStoreKey)
        }
        if let period {
            try? stateStore.setObject(period.rawValue, forKey: ClipboardHistoryStore.autoCleanupPeriodStoreKey)
        }
        if let lastRunAt {
            try? stateStore.setObject(lastRunAt, forKey: ClipboardHistoryStore.autoCleanupLastRunStoreKey)
        }
        let clipboard = StubClipboard()
        let store = ClipboardHistoryStore(reader: clipboard)
        store.attach(stateStore: stateStore, startPolling: false)
        return Harness(store: store, clipboard: clipboard, root: root)
    }

    private func persistStamp(in root: URL) -> Date? {
        StateStore(rootDirectory: root)
            .object(Date.self, forKey: ClipboardHistoryStore.autoCleanupLastRunStoreKey)
    }

    private func cleanup(_ harness: Harness) {
        harness.store.suspend()
        try? FileManager.default.removeItem(at: harness.root)
    }

    private func entry(_ text: String, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(text: text, pinned: pinned)
    }

    /// 走完一拍采集（生产由 ClipboardPoller 的后台队列驱动，这里同步直注）。
    private func ingest(_ store: ClipboardHistoryStore, _: StubClipboard) {
        store.pollNow()
    }

    private func mediaDirectory(_ root: URL) -> URL {
        root.appendingPathComponent("Media", isDirectory: true)
    }

    // MARK: 档位定义

    func testPeriodSanitizeFallsBackToDefault() {
        XCTAssertEqual(ClipboardAutoCleanupPeriod.defaultPeriod, .weekly)
        XCTAssertEqual(ClipboardAutoCleanupPeriod.selectable, [.off, .daily, .weekly, .monthly])
        XCTAssertEqual(ClipboardAutoCleanupPeriod.sanitize(nil), .weekly)
        XCTAssertEqual(ClipboardAutoCleanupPeriod.sanitize(""), .weekly)
        XCTAssertEqual(ClipboardAutoCleanupPeriod.sanitize("每季度"), .weekly)
        XCTAssertEqual(ClipboardAutoCleanupPeriod.sanitize("off"), .off)
        XCTAssertEqual(ClipboardAutoCleanupPeriod.sanitize("monthly"), .monthly)
        XCTAssertEqual(ClipboardAutoCleanupPeriod.off.localizationKey, "settings.autoCleanup.off")
    }

    /// 到期用日历加法：「每月」是日历月，不是 30×86400。
    func testNextDueUsesCalendarUnits() throws {
        let base = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 10)))
        XCTAssertNil(ClipboardAutoCleanupPeriod.off.nextDue(from: base, calendar: calendar))
        XCTAssertEqual(
            try XCTUnwrap(ClipboardAutoCleanupPeriod.daily.nextDue(from: base, calendar: calendar)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: base))
        )
        XCTAssertEqual(
            try XCTUnwrap(ClipboardAutoCleanupPeriod.weekly.nextDue(from: base, calendar: calendar)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: base))
        )
        let monthly = try XCTUnwrap(ClipboardAutoCleanupPeriod.monthly.nextDue(from: base, calendar: calendar))
        XCTAssertEqual(monthly, try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: base)))
        // 1/31 + 1 月 = 2/28（2026 非闰年），而不是固定 30 天后的 3/2。
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: monthly), DateComponents(month: 2, day: 28))
    }

    func testCleanupDueJudgement() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 12)))
        let week: TimeInterval = 604_800
        func due(
            _ period: ClipboardAutoCleanupPeriod,
            _ offset: TimeInterval?
        ) -> Bool {
            ClipboardHistoryLogic.isCleanupDue(
                period: period,
                lastRunAt: offset.map { now.addingTimeInterval($0) },
                now: now,
                calendar: calendar
            )
        }
        // 关闭档：多久以前清过都不到期。
        XCTAssertFalse(due(.off, -week * 400))
        XCTAssertFalse(due(.off, nil))
        // 首次启用（无时间戳）：只起算，判为未到点。
        XCTAssertFalse(due(.weekly, nil))
        // 差一秒 / 恰好到点 / 早已超出。
        XCTAssertFalse(due(.weekly, -week + 1))
        XCTAssertTrue(due(.weekly, -week))
        XCTAssertTrue(due(.weekly, -week * 2))
        XCTAssertTrue(due(.daily, -86_400))
        XCTAssertFalse(due(.monthly, -86_400))
    }

    // MARK: store 接入

    /// 新装 / 升级：档位落默认每周、时间戳落"此刻起算"，**存量历史一条不动**。
    func testFreshInstallStartsClockWithoutClearing() throws {
        let harness = makeStore(preloaded: [entry("plain"), entry("pinned", pinned: true)])
        defer { cleanup(harness) }
        XCTAssertEqual(harness.store.autoCleanupPeriod, .weekly)
        // 存量历史一条不动（attach 的净化把置顶排到前面）。
        XCTAssertEqual(harness.store.entries.map(\.text), ["pinned", "plain"])
        let stamp = try XCTUnwrap(persistStamp(in: harness.root))
        XCTAssertEqual(stamp.timeIntervalSinceNow, 0, accuracy: 10)
    }

    /// 到期（启动补算这条路）：只清未置顶，且进落盘——重建 store 仍只剩置顶。
    func testDueCleanupKeepsPinnedAndPersists() throws {
        let harness = makeStore(
            preloaded: [entry("pinned", pinned: true), entry("old")],
            period: .weekly,
            lastRunAt: Date().addingTimeInterval(-604_800 * 1.2)
        )
        defer { cleanup(harness) }
        XCTAssertEqual(harness.store.entries.map(\.text), ["pinned"])

        let restored = ClipboardHistoryStore(reader: StubClipboard())
        restored.attach(stateStore: StateStore(rootDirectory: harness.root), startPolling: false)
        XCTAssertEqual(restored.entries.map(\.text), ["pinned"])
        restored.suspend()

        // 时间戳刷新到今天：紧接着再判一次不会重复清理。
        let stamp = try XCTUnwrap(persistStamp(in: harness.root))
        XCTAssertEqual(stamp.timeIntervalSinceNow, 0, accuracy: 10)
    }

    func testOffPeriodNeverClearsEvenWhenFarOverdue() {
        let harness = makeStore(
            preloaded: [entry("a")],
            period: .off,
            lastRunAt: Date().addingTimeInterval(-86_400 * 400)
        )
        defer { cleanup(harness) }
        harness.store.runAutoCleanupIfDue(now: Date().addingTimeInterval(86_400 * 400))
        XCTAssertEqual(harness.store.entries.map(\.text), ["a"])
    }

    /// 改档只重新起算、不立刻清；下一个周期到点才清。
    func testChangingPeriodRestartsClock() throws {
        let harness = makeStore(
            preloaded: [entry("a")],
            period: .off,
            lastRunAt: Date().addingTimeInterval(-604_800 * 3)
        )
        defer { cleanup(harness) }
        harness.store.setAutoCleanupPeriod(.weekly)
        let stamp = try XCTUnwrap(persistStamp(in: harness.root))
        XCTAssertEqual(stamp.timeIntervalSinceNow, 0, accuracy: 10, "改档必须重新起算")
        harness.store.runAutoCleanupIfDue()
        XCTAssertEqual(harness.store.entries.map(\.text), ["a"], "刚改档不该立刻清")
        harness.store.runAutoCleanupIfDue(now: Date().addingTimeInterval(604_800 + 1))
        XCTAssertTrue(harness.store.entries.isEmpty)
    }

    func testPeriodPersistsAcrossAttach() throws {
        let harness = makeStore(period: .monthly)
        defer { cleanup(harness) }
        XCTAssertEqual(harness.store.autoCleanupPeriod, .monthly)
        let restored = ClipboardHistoryStore(reader: StubClipboard())
        restored.attach(stateStore: StateStore(rootDirectory: harness.root), startPolling: false)
        XCTAssertEqual(restored.autoCleanupPeriod, .monthly)
        restored.suspend()
    }

    // MARK: 媒体文件连带回收

    /// 未置顶图片被清理时，它的原图与缩略图必须一起消失（另写删除路径就会留孤儿）。
    func testCleanupRemovesMediaFilesOfUnpinnedImages() throws {
        let harness = makeStore(period: .off)
        defer { cleanup(harness) }
        harness.clipboard.externalImageCopy(Data([0x89, 0x50, 0x4E, 0x47, 0x0D]))
        ingest(harness.store, harness.clipboard)
        let name = try XCTUnwrap(harness.store.entries.first?.storedMediaName)
        let original = mediaDirectory(harness.root).appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))

        harness.store.performAutoCleanup()
        XCTAssertTrue(harness.store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "媒体文件必须随条目一起回收")
    }

    /// 置顶图片不受自动清理影响：条目在、文件也在。
    func testCleanupKeepsPinnedImageMediaFiles() throws {
        let harness = makeStore(period: .off)
        defer { cleanup(harness) }
        harness.clipboard.externalImageCopy(Data([0x89, 0x50, 0x4E, 0x47, 0x01]))
        ingest(harness.store, harness.clipboard)
        let pinnedID = try XCTUnwrap(harness.store.entries.first?.id)
        harness.store.togglePin(id: pinnedID)
        harness.clipboard.externalImageCopy(Data([0x89, 0x50, 0x4E, 0x47, 0x02]))
        ingest(harness.store, harness.clipboard)
        // 置顶区在前、最近区在后：置顶那张是 first，新记的这张是 last。
        let pinnedName = try XCTUnwrap(harness.store.entries.first?.storedMediaName)
        let unpinnedName = try XCTUnwrap(harness.store.entries.last?.storedMediaName)

        harness.store.performAutoCleanup()
        XCTAssertEqual(harness.store.entries.map(\.id), [pinnedID])
        let media = mediaDirectory(harness.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(pinnedName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent(unpinnedName).path))
    }
}
