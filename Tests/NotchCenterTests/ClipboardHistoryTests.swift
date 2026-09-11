import Foundation
import NotchCenterKit
import XCTest
@testable import ClipboardHistoryPlugin

/// ClipboardHistoryPlugin 纯逻辑回归：去重 / 置顶 / 淘汰 / 搜索 / transient 判定
/// 与经假剪贴板驱动的 store 状态机（记录、暂停、自循环跳过、写回、持久化）。
/// 绝不触碰真实 NSPasteboard。
@MainActor
final class ClipboardHistoryTests: XCTestCase {
    // MARK: 假剪贴板

    private final class FakeClipboard: ClipboardReading, @unchecked Sendable {
        var snapshotValue = ClipboardSnapshot(changeCount: 0, text: nil, typeNames: [])
        private(set) var written: [String] = []
        private var writeCount = 100

        func snapshot() -> ClipboardSnapshot { snapshotValue }

        func writeBack(_ text: String) -> Int {
            written.append(text)
            writeCount += 1
            snapshotValue = ClipboardSnapshot(changeCount: writeCount, text: text, typeNames: [])
            return writeCount
        }

        /// 模拟一次外部复制。
        func externalCopy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
            snapshotValue = ClipboardSnapshot(
                changeCount: snapshotValue.changeCount + 1,
                text: text,
                typeNames: types
            )
        }
    }

    private func makeStore(
        clipboard: FakeClipboard = FakeClipboard(),
        preloaded: [ClipboardEntry] = [],
        paused: Bool = false
    ) -> (ClipboardHistoryStore, FakeClipboard, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let stateStore = StateStore(rootDirectory: root)
        if !preloaded.isEmpty {
            try? stateStore.setObject(preloaded, forKey: ClipboardHistoryStore.historyStoreKey)
        }
        if paused {
            try? stateStore.setObject(true, forKey: ClipboardHistoryStore.pausedStoreKey)
        }
        let store = ClipboardHistoryStore(reader: clipboard)
        // 测试不登记 placement（isObserved 为假故无 timer），只验证 ingest 状态机。
        store.attach(stateStore: stateStore)
        return (store, clipboard, root)
    }

    // MARK: 记录规则（Q4）

    func testBlankAndOversizedAreNotRecordable() {
        XCTAssertFalse(ClipboardHistoryLogic.isRecordable(""))
        XCTAssertFalse(ClipboardHistoryLogic.isRecordable("   \n  "))
        XCTAssertFalse(ClipboardHistoryLogic.isRecordable(String(repeating: "x", count: 101 * 1024)))
        XCTAssertTrue(ClipboardHistoryLogic.isRecordable("hello"))
    }

    func testConsecutiveDuplicateIsSkipped() {
        var entries = ClipboardHistoryLogic.recording("a", into: [])
        entries = ClipboardHistoryLogic.recording("a", into: entries)
        XCTAssertEqual(entries.count, 1)
    }

    func testReCopyMovesExistingEntryToFrontKeepingPin() {
        var entries = ClipboardHistoryLogic.recording("a", into: [])
        entries = ClipboardHistoryLogic.recording("b", into: entries)
        guard let pinned = ClipboardHistoryLogic.pinning(id: entries[1].id, pinned: true, in: entries) else {
            XCTFail("pin 应成功")
            return
        }
        entries = pinned
        // 重新复制置顶条 a：顶到最前但保持 pinned。
        entries = ClipboardHistoryLogic.recording("a", into: entries)
        XCTAssertEqual(entries.map(\.text), ["a", "b"])
        XCTAssertTrue(entries[0].pinned)
    }

    func testCapacityAndPinCaps() {
        var entries: [ClipboardEntry] = []
        for index in 0..<(ClipboardHistoryLogic.maxEntries + 10) {
            entries = ClipboardHistoryLogic.recording("item-\(index)", into: entries)
        }
        XCTAssertEqual(entries.count, ClipboardHistoryLogic.maxEntries)
        XCTAssertEqual(entries.first?.text, "item-\(ClipboardHistoryLogic.maxEntries + 9)")

        // 置顶溢出：第 6 个置顶时最早的一条自动解顶但保留。
        for index in 0..<6 {
            guard let next = ClipboardHistoryLogic.pinning(id: entries[index].id, pinned: true, in: entries) else {
                XCTFail("pin 应成功")
                return
            }
            entries = next
        }
        XCTAssertEqual(entries.filter(\.pinned).count, ClipboardHistoryLogic.maxPinned)
        XCTAssertEqual(entries.count, ClipboardHistoryLogic.maxEntries)
    }

    // MARK: 搜索与清空（Q9/Q7）

    func testSearchIsCaseInsensitiveSubstringIncludingPinned() {
        let entries = [
            ClipboardEntry(text: "Hello World"),
            ClipboardEntry(text: "foo BAR", pinned: true),
            ClipboardEntry(text: "unrelated"),
        ]
        XCTAssertEqual(ClipboardHistoryLogic.filtered(entries, query: "").count, 3)
        XCTAssertEqual(ClipboardHistoryLogic.filtered(entries, query: "bar").map(\.text), ["foo BAR"])
        XCTAssertEqual(ClipboardHistoryLogic.filtered(entries, query: "HELLO").map(\.text), ["Hello World"])
        XCTAssertTrue(ClipboardHistoryLogic.filtered(entries, query: "zzz").isEmpty)
    }

    func testClearKeepsPinnedAndDeleteRemovesSingle() {
        let pinned = ClipboardEntry(text: "keep", pinned: true)
        let plain = ClipboardEntry(text: "drop")
        let entries = [pinned, plain]
        XCTAssertEqual(ClipboardHistoryLogic.clearingUnpinned(entries), [pinned])
        XCTAssertEqual(ClipboardHistoryLogic.removing(id: plain.id, from: entries), [pinned])
        XCTAssertNil(ClipboardHistoryLogic.removing(id: UUID(), from: entries))
        XCTAssertNil(ClipboardHistoryLogic.pinning(id: UUID(), pinned: true, in: entries))
    }

    func testSanitizedEnforcesBothCaps() {
        let overflow = (0..<(ClipboardHistoryLogic.maxPinned + 3)).map {
            ClipboardEntry(text: "p\($0)", pinned: true)
        } + (0..<(ClipboardHistoryLogic.maxEntries)).map {
            ClipboardEntry(text: "x\($0)")
        }
        let clean = ClipboardHistoryLogic.sanitized(overflow)
        XCTAssertEqual(clean.count, ClipboardHistoryLogic.maxEntries)
        XCTAssertEqual(clean.filter(\.pinned).count, ClipboardHistoryLogic.maxPinned)
    }

    func testDisplayCountSanitizesToNearestTier() {
        XCTAssertEqual(ClipboardHistoryLogic.sanitizeDisplayCount(20), 20)
        XCTAssertEqual(ClipboardHistoryLogic.sanitizeDisplayCount(50), 50)
        XCTAssertEqual(ClipboardHistoryLogic.sanitizeDisplayCount(7), 20)
        XCTAssertEqual(ClipboardHistoryLogic.sanitizeDisplayCount(999), 50)
    }

    /// 旧版本持久化配置含 showTimestamps 键（2026-09-06 起字段移除）：
    /// JSONDecoder 忽略未知键，升级解码必须不失败、保留有效字段。
    func testLegacyConfigJSONWithTimestampsKeyStillDecodes() throws {
        let legacy = Data(#"{"displayCount":20,"showTimestamps":false}"#.utf8)
        let config = try JSONDecoder().decode(ClipboardInstanceConfig.self, from: legacy)
        XCTAssertEqual(config.displayCount, 20)
    }

    // MARK: transient 判定（Q2）

    func testTransientTypeNamesAreSkipped() {
        XCTAssertTrue(ClipboardHistoryStore.isTransient(typeNames: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(ClipboardHistoryStore.isTransient(typeNames: ["com.1password.concealed"]))
        XCTAssertTrue(ClipboardHistoryStore.isTransient(typeNames: ["public.password"]))
        XCTAssertFalse(ClipboardHistoryStore.isTransient(typeNames: ["public.utf8-plain-text"]))
        XCTAssertFalse(ClipboardHistoryStore.isTransient(typeNames: []))
    }

    // MARK: store 状态机（假剪贴板驱动）

    func testIngestRecordsExternalCopySkipsDuplicateChangeCount() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalCopy("first")
        store.ingest(clipboard.snapshot())
        XCTAssertEqual(store.entries.map(\.text), ["first"])
        // 相同 changeCount 再次 ingest：不重复记。
        store.ingest(clipboard.snapshot())
        XCTAssertEqual(store.entries.count, 1)
    }

    func testIngestSkipsTransientAndEmpty() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalCopy("secret", types: ["com.example.transient"])
        store.ingest(clipboard.snapshot())
        XCTAssertTrue(store.entries.isEmpty)
        clipboard.externalCopy(nil)
        store.ingest(clipboard.snapshot())
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPausedSkipsRecordingAndResumesFromFreshCount() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setPaused(true)
        XCTAssertTrue(store.isPaused)
        clipboard.externalCopy("while-paused")
        store.ingest(clipboard.snapshot())
        XCTAssertTrue(store.entries.isEmpty)
        store.setPaused(false)
        // 暂停期的变化不补记：同一快照恢复后也不记。
        store.ingest(clipboard.snapshot())
        XCTAssertTrue(store.entries.isEmpty)
        clipboard.externalCopy("after-resume")
        store.ingest(clipboard.snapshot())
        XCTAssertEqual(store.entries.map(\.text), ["after-resume"])
    }

    func testCopyBackWritesThroughAndSkipsSelfLoop() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalCopy("hello")
        store.ingest(clipboard.snapshot())
        let entry = try! XCTUnwrap(store.entries.first)
        store.copyBack(entry)
        XCTAssertEqual(clipboard.written, ["hello"])
        XCTAssertEqual(store.justCopiedID, entry.id)
        // 写回产生的 changeCount 跳变：下一轮 ingest 只认领、不记录。
        store.ingest(clipboard.snapshot())
        XCTAssertEqual(store.entries.count, 1)
    }

    func testPinDeleteClearPersist() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalCopy("a")
        store.ingest(clipboard.snapshot())
        clipboard.externalCopy("b")
        store.ingest(clipboard.snapshot())
        let first = try! XCTUnwrap(store.entries.first(where: { $0.text == "a" }))
        store.togglePin(id: first.id)
        XCTAssertTrue(store.entries.first(where: { $0.id == first.id })?.pinned == true)
        store.togglePin(id: first.id)
        XCTAssertFalse(store.entries.first(where: { $0.id == first.id })?.pinned == true)
        // 持久化：同目录重建 store 应恢复条目。
        let restored = ClipboardHistoryStore(reader: clipboard)
        restored.attach(stateStore: StateStore(rootDirectory: root))
        XCTAssertEqual(restored.entries.map(\.text), store.entries.map(\.text))
        store.delete(id: first.id)
        XCTAssertFalse(store.entries.contains(where: { $0.id == first.id }))
        clipboard.externalCopy("c")
        store.ingest(clipboard.snapshot())
        store.clearUnpinned()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: 诊断压帽（剪贴板行数归因）

    /// 压帽只"压"不"涨"：实例配置 20 遇上 cap 50 仍按 20 走。
    func testEffectiveDisplayCountTakesSmallerOfConfigAndCap() {
        XCTAssertEqual(ClipboardHistoryLogic.effectiveDisplayCount(50, cap: nil), 50)
        XCTAssertEqual(ClipboardHistoryLogic.effectiveDisplayCount(50, cap: 12), 12)
        XCTAssertEqual(ClipboardHistoryLogic.effectiveDisplayCount(20, cap: 50), 20)
    }

    /// 压帽取前缀、保序；cap 大于总量或为 nil 时原样返回。
    func testApplyingRowCapKeepsPrefixAndOrder() {
        let entries = (1...5).map { ClipboardEntry(text: "e\($0)") }
        XCTAssertEqual(
            ClipboardHistoryLogic.applyingRowCap(entries, cap: nil).map(\.text),
            ["e1", "e2", "e3", "e4", "e5"]
        )
        XCTAssertEqual(ClipboardHistoryLogic.applyingRowCap(entries, cap: 2).map(\.text), ["e1", "e2"])
        XCTAssertEqual(ClipboardHistoryLogic.applyingRowCap(entries, cap: 99).count, 5)
    }

    /// 环境变量是唯一入口：未设（或无合法值）时必须完全不干预生产展示。
    func testDiagnosticRowCapReadsEnvOverrideAndRejectsJunk() {
        XCTAssertNil(ClipboardHistoryLogic.diagnosticRowCap, "套件内默认不得有压帽")
        setenv("NOTCHCENTER_CLIPBOARD_ROW_CAP", "7", 1)
        defer { unsetenv("NOTCHCENTER_CLIPBOARD_ROW_CAP") }
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticRowCap, 7)
        XCTAssertEqual(ClipboardHistoryLogic.effectiveDisplayCount(50), 7)
        setenv("NOTCHCENTER_CLIPBOARD_ROW_CAP", "0", 1)
        XCTAssertNil(ClipboardHistoryLogic.diagnosticRowCap)
        setenv("NOTCHCENTER_CLIPBOARD_ROW_CAP", "abc", 1)
        XCTAssertNil(ClipboardHistoryLogic.diagnosticRowCap)
    }

    // MARK: 诊断分量开关（剪贴板每块固定开销归因）

    /// 取值域只有两个合法值；未设 / 拼错 / 大小写不符都必须回落到"生产行为"，
    /// 否则一个手误的诊断变量会静默改掉用户看到的块内容。
    func testDiagnosticModeReadsEnvOverrideAndRejectsJunk() {
        XCTAssertNil(ClipboardHistoryLogic.diagnosticMode, "套件内默认不得开诊断")
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "probe-off", 1)
        defer { unsetenv("NOTCHCENTER_CLIPBOARD_DIAG") }
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticMode, .probeOff)
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "content-off", 1)
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticMode, .contentOff)
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "text-off", 1)
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticMode, .textOff)
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticText("很长很长的正文"), "文本")
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "PROBE-OFF", 1)
        XCTAssertNil(ClipboardHistoryLogic.diagnosticMode)
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "no-probe", 1)
        XCTAssertNil(ClipboardHistoryLogic.diagnosticMode)
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "", 1)
        XCTAssertNil(ClipboardHistoryLogic.diagnosticMode)
    }

    /// 非 `text-off` 一律原样透传正文——诊断不得改到生产展示内容。
    func testDiagnosticTextPassesThroughWhenModeUnset() {
        unsetenv("NOTCHCENTER_CLIPBOARD_DIAG")
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticText("正文"), "正文")
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "content-off", 1)
        defer { unsetenv("NOTCHCENTER_CLIPBOARD_DIAG") }
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticText("正文"), "正文")
    }

    /// 两把开关彼此正交：压帽不该被分量开关影响，反之亦然。
    func testDiagnosticSwitchesAreIndependent() {
        setenv("NOTCHCENTER_CLIPBOARD_ROW_CAP", "5", 1)
        setenv("NOTCHCENTER_CLIPBOARD_DIAG", "probe-off", 1)
        defer {
            unsetenv("NOTCHCENTER_CLIPBOARD_ROW_CAP")
            unsetenv("NOTCHCENTER_CLIPBOARD_DIAG")
        }
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticRowCap, 5)
        XCTAssertEqual(ClipboardHistoryLogic.diagnosticMode, .probeOff)
        XCTAssertEqual(ClipboardHistoryLogic.effectiveDisplayCount(50), 5)
    }
}
