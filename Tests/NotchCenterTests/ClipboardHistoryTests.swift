import AppKit
import Foundation
import NotchCenterKit
import XCTest
@testable import ClipboardHistoryPlugin

/// ClipboardHistoryPlugin 纯逻辑回归：去重 / 置顶 / 淘汰 / 搜索 / transient 判定、
/// 富媒体（图片与文件）采集与写回、以及经假剪贴板驱动的 store 状态机
/// （记录、暂停、自循环跳过、写回、持久化、媒体文件回收）。
/// 绝不触碰真实 NSPasteboard。
@MainActor
final class ClipboardHistoryTests: XCTestCase {
    // MARK: 假剪贴板

    private final class FakeClipboard: ClipboardReading, @unchecked Sendable {
        var changeCount = 0
        var typeNames: [String] = ["public.utf8-plain-text"]
        var payload = ClipboardPayload()
        private(set) var writtenTexts: [String] = []
        private(set) var writtenFileGroups: [[String]] = []
        private(set) var writtenImages: [Data] = []
        private var writeCount = 100

        func probe() -> ClipboardProbe {
            ClipboardProbe(changeCount: changeCount, typeNames: typeNames)
        }

        func readPayload() -> ClipboardPayload { payload }

        func writeText(_ text: String) -> Int {
            writtenTexts.append(text)
            return finishWrite(payload: ClipboardPayload(text: text), types: ["public.utf8-plain-text"])
        }

        func writeFiles(_ paths: [String]) -> Int {
            writtenFileGroups.append(paths)
            return finishWrite(payload: ClipboardPayload(filePaths: paths), types: ["public.file-url"])
        }

        func writeImage(data: Data, uti: String?) -> Int {
            writtenImages.append(data)
            return finishWrite(payload: ClipboardPayload(imageData: data, imageUTI: uti), types: [uti ?? "public.png"])
        }

        /// 模拟一次外部复制（纯文本）。
        func externalCopy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
            changeCount += 1
            typeNames = types
            payload = ClipboardPayload(text: text)
        }

        /// 模拟一次图片复制。
        func externalImageCopy(_ data: Data, uti: String = "public.png") {
            changeCount += 1
            typeNames = [uti]
            payload = ClipboardPayload(imageData: data, imageUTI: uti)
        }

        /// 模拟一次文件复制（多选 → 一份载荷里多个路径）。
        func externalFileCopy(_ paths: [String]) {
            changeCount += 1
            typeNames = ["public.file-url"]
            payload = ClipboardPayload(filePaths: paths)
        }

        /// 写回后剪贴板内容随之改变，与真实 NSPasteboard 语义一致。
        private func finishWrite(payload: ClipboardPayload, types: [String]) -> Int {
            writeCount += 1
            changeCount = writeCount
            typeNames = types
            self.payload = payload
            return writeCount
        }
    }

    /// 走完两段式采集：轻探测的门 + 载荷消化。
    ///
    /// 生产路径的第二段挂在后台任务上，这里同步补上——测试要的是确定性，
    /// 不是跨线程等待。重复触发是幂等的：同 changeCount 的载荷第二次进来会被
    /// 内容去重吃掉，不会记第二条，也不会重复落盘。
    private func ingest(_ store: ClipboardHistoryStore, _ clipboard: FakeClipboard) {
        let probe = clipboard.probe()
        store.ingest(probe)
        store.ingest(clipboard.readPayload(), changeCount: probe.changeCount)
    }

    /// 造一张真的可解码 PNG——缩略图生成要有真图才走得通。
    ///
    /// 走 `CGContext` 而不是 `NSImage.lockFocus()`：后者依赖图形会话，无头环境会挂。
    private static func makePNG(width: Int, height: Int, blue: CGFloat = 0.9) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!)
            .representation(using: .png, properties: [:])!
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

    private func mediaDirectory(_ root: URL) -> URL {
        root.appendingPathComponent("Media", isDirectory: true)
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
        ingest(store, clipboard)
        XCTAssertEqual(store.entries.map(\.text), ["first"])
        // 相同 changeCount 再次 ingest：不重复记。
        ingest(store, clipboard)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testIngestSkipsTransientAndEmpty() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalCopy("secret", types: ["com.example.transient"])
        ingest(store, clipboard)
        XCTAssertTrue(store.entries.isEmpty)
        clipboard.externalCopy(nil)
        ingest(store, clipboard)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPausedSkipsRecordingAndResumesFromFreshCount() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setPaused(true)
        XCTAssertTrue(store.isPaused)
        clipboard.externalCopy("while-paused")
        ingest(store, clipboard)
        XCTAssertTrue(store.entries.isEmpty)
        store.setPaused(false)
        // 暂停期的变化不补记：同一快照恢复后也不记。
        ingest(store, clipboard)
        XCTAssertTrue(store.entries.isEmpty)
        clipboard.externalCopy("after-resume")
        ingest(store, clipboard)
        XCTAssertEqual(store.entries.map(\.text), ["after-resume"])
    }

    func testCopyBackWritesThroughAndSkipsSelfLoop() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalCopy("hello")
        ingest(store, clipboard)
        let entry = try! XCTUnwrap(store.entries.first)
        store.copyBack(entry)
        XCTAssertEqual(clipboard.writtenTexts, ["hello"])
        XCTAssertEqual(store.justCopiedID, entry.id)
        // 写回产生的 changeCount 跳变：下一轮 ingest 只认领、不记录。
        ingest(store, clipboard)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testPinDeleteClearPersist() {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalCopy("a")
        ingest(store, clipboard)
        clipboard.externalCopy("b")
        ingest(store, clipboard)
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
        ingest(store, clipboard)
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

    // MARK: 富媒体采集（2026-09-20 决策记录 D1–D5）

    /// 图片条目：正文恒为空串、带内容哈希与落盘名，且原图与缩略图真的落了盘。
    func testImageCopyRecordsEntryAndWritesMediaFiles() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Self.makePNG(width: 8, height: 8)
        clipboard.externalImageCopy(png)
        ingest(store, clipboard)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.text, "", "图片条目正文恒为空串，不硬造描述串")
        XCTAssertEqual(entry.contentHash, ClipboardMediaStore.contentHash(of: png))
        XCTAssertEqual(entry.mediaByteSize, png.count)
        let name = try XCTUnwrap(entry.storedMediaName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mediaDirectory(root).appendingPathComponent(name).path),
            "原图必须落盘"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: mediaDirectory(root)
                    .appendingPathComponent(name + ClipboardMediaStore.thumbnailSuffix).path
            ),
            "缩略图必须落盘"
        )
        // 文件存在还不够：要断言它**解得出来**。"CGImageSource 解不了这种输入"正是
        // "列表里图片没预览"的成因，只查存在性会漏掉。
        let thumbnail = try XCTUnwrap(NSImage(contentsOf: try XCTUnwrap(store.thumbnailURL(for: entry))))
        XCTAssertGreaterThan(thumbnail.size.width, 0)
        XCTAssertGreaterThan(thumbnail.size.height, 0)
        // 同一份输入也要能当原图读出来（长按预览走这条路）。
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(store.originalURL(for: entry)).path)
        )
        XCTAssertNil(store.thumbnailURL(for: ClipboardEntry(text: "not an image")))
        XCTAssertNil(store.originalURL(for: ClipboardEntry(text: "not an image")))
    }

    /// 缩略图按长边降采样到上限，原图保持原始像素——两者不能互相污染。
    func testThumbnailIsDownsampledWhileOriginalKeepsPixelSize() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalImageCopy(Self.makePNG(width: 1024, height: 640))
        ingest(store, clipboard)
        let entry = try XCTUnwrap(store.entries.first)

        let thumbnailData = try Data(contentsOf: try XCTUnwrap(store.thumbnailURL(for: entry)))
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(data: thumbnailData))
        XCTAssertEqual(
            max(thumbnail.pixelsWide, thumbnail.pixelsHigh),
            ClipboardMediaStore.thumbnailMaxPixelSize,
            "长边必须降到上限：不降就退化成逐行解原图"
        )

        let originalData = try Data(contentsOf: try XCTUnwrap(store.originalURL(for: entry)))
        let original = try XCTUnwrap(NSBitmapImageRep(data: originalData))
        XCTAssertEqual(original.pixelsWide, 1024, "原图不得被缩略图逻辑改写")
        XCTAssertEqual(original.pixelsHigh, 640)
    }

    /// 图片去重按内容哈希而非正文：正文都是空串，靠正文会把所有图片合成一条。
    func testImageDedupesByContentHash() {
        let first = Self.makePNG(width: 8, height: 8)
        let second = Self.makePNG(width: 9, height: 8)
        var entries = ClipboardHistoryLogic.recording(
            ClipboardCapture(imageData: first, imageUTI: "public.png", imageHash: "hash-a"),
            into: []
        )
        entries = ClipboardHistoryLogic.recording(
            ClipboardCapture(imageData: second, imageUTI: "public.png", imageHash: "hash-b"),
            into: entries
        )
        XCTAssertEqual(entries.count, 2)
        // 再复制第一张：顶到最前，不新增。
        entries = ClipboardHistoryLogic.recording(
            ClipboardCapture(imageData: first, imageUTI: "public.png", imageHash: "hash-a"),
            into: entries
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.contentHash), ["hash-a", "hash-b"])
    }

    /// 缺内容哈希的图片载荷一律拒收——退化成"按正文去重"比不记录更糟。
    func testImageCaptureWithoutHashIsRejected() {
        let capture = ClipboardCapture(
            imageData: Self.makePNG(width: 4, height: 4),
            imageUTI: "public.png"
        )
        XCTAssertNil(ClipboardHistoryLogic.makeEntry(from: capture))
    }

    /// 超单条上限的媒体整份丢弃，不截断（截断的图片写回就是坏数据）。
    func testOversizedMediaIsRejected() {
        let capture = ClipboardCapture(
            imageData: Data(repeating: 0x89, count: ClipboardHistoryLogic.maxMediaSingleBytes + 1),
            imageUTI: "public.png",
            imageHash: "hash-big"
        )
        XCTAssertNil(ClipboardHistoryLogic.makeEntry(from: capture))
    }

    /// 一次复制多个文件 = 一条条目：正文是换行连接的路径串，载荷是整组。
    func testMultiFileCopyBecomesSingleEntry() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makeTempFiles(3, under: root)
        clipboard.externalFileCopy(paths)
        ingest(store, clipboard)
        XCTAssertEqual(store.entries.count, 1, "多选复制必须聚合成一条")
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.fileURLs, paths)
        XCTAssertEqual(entry.text, paths.joined(separator: "\n"))
    }

    /// 文件不分片：整组要么都写回、要么都不写（部分写回正是要消灭的静默丢失）。
    func testFileCopyBackWritesWholeGroup() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makeTempFiles(2, under: root)
        clipboard.externalFileCopy(paths)
        ingest(store, clipboard)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertTrue(store.copyBack(entry))
        XCTAssertEqual(clipboard.writtenFileGroups, [paths])
        XCTAssertEqual(store.justCopiedID, entry.id)
    }

    /// 任一原路径失效即拒写并显示失效态——不复制副本保活（项目红线），也不静默丢。
    func testFileCopyBackRefusedWhenAnyPathMissing() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makeTempFiles(2, under: root)
        clipboard.externalFileCopy(paths)
        ingest(store, clipboard)
        let entry = try XCTUnwrap(store.entries.first)
        try FileManager.default.removeItem(atPath: paths[1])
        XCTAssertFalse(store.copyBack(entry))
        XCTAssertTrue(clipboard.writtenFileGroups.isEmpty, "失效时一个文件都不该写")
        XCTAssertEqual(store.copyFailedID, entry.id)
        XCTAssertNil(store.justCopiedID)
    }

    /// 图片写回放的是**原始字节**，不是重编码产物。
    func testImageCopyBackWritesOriginalBytes() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Self.makePNG(width: 12, height: 7)
        clipboard.externalImageCopy(png)
        ingest(store, clipboard)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertTrue(store.copyBack(entry))
        XCTAssertEqual(clipboard.writtenImages, [png])
    }

    // MARK: 媒体文件回收（D6 的"淘汰必须同步删文件"）

    func testDeletingImageEntryRemovesMediaFiles() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalImageCopy(Self.makePNG(width: 8, height: 8))
        ingest(store, clipboard)
        let name = try XCTUnwrap(store.entries.first?.storedMediaName)
        let url = mediaDirectory(root).appendingPathComponent(name)
        store.delete(id: try XCTUnwrap(store.entries.first?.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "条目没了文件必须跟着删")
    }

    func testClearUnpinnedRemovesMediaFiles() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalImageCopy(Self.makePNG(width: 8, height: 8))
        ingest(store, clipboard)
        let name = try XCTUnwrap(store.entries.first?.storedMediaName)
        store.clearUnpinned()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: mediaDirectory(root).appendingPathComponent(name).path
            )
        )
    }

    /// 启动对账删孤儿、留引用：崩溃留下的无主文件不该永远躺在数据目录里。
    func testStartupReconcileRemovesOrphansAndKeepsReferenced() throws {
        let (store, clipboard, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        clipboard.externalImageCopy(Self.makePNG(width: 8, height: 8))
        ingest(store, clipboard)
        let kept = try XCTUnwrap(store.entries.first?.storedMediaName)
        let orphan = mediaDirectory(root).appendingPathComponent("orphan.png")
        try Data([0x00]).write(to: orphan)

        let restored = ClipboardHistoryStore(reader: clipboard)
        restored.attach(stateStore: StateStore(rootDirectory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "孤儿必须被回收")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mediaDirectory(root).appendingPathComponent(kept).path),
            "仍被引用的文件不得误删"
        )
    }

    // MARK: 媒体字节预算（D6）

    private func imageEntry(
        hash: String,
        bytes: Int,
        pinned: Bool = false,
        mediaName: String? = nil
    ) -> ClipboardEntry {
        ClipboardEntry(
            text: "",
            pinned: pinned,
            kind: .image,
            contentHash: hash,
            storedMediaName: mediaName ?? "\(hash).png",
            mediaByteSize: bytes,
            mediaUTI: "public.png"
        )
    }

    /// 超预算从**最老**（末尾）的未置顶条目开始淘汰，条数恰好回到预算内即停。
    func testMediaBudgetEvictsOldestUnpinnedUntilWithinBudget() {
        let half = ClipboardHistoryLogic.maxMediaBytes / 2
        let entries = [
            imageEntry(hash: "newest", bytes: half),
            imageEntry(hash: "middle", bytes: half),
            imageEntry(hash: "oldest", bytes: half),
        ]
        let clean = ClipboardHistoryLogic.sanitized(entries)
        XCTAssertEqual(clean.map(\.contentHash), ["newest", "middle"])
        XCTAssertLessThanOrEqual(
            clean.reduce(0) { $0 + ClipboardHistoryLogic.mediaByteSize(of: $1) },
            ClipboardHistoryLogic.maxMediaBytes
        )
    }

    /// 置顶永不因预算被淘汰——那等于让预算拥有"静默解顶"的权力。
    func testMediaBudgetNeverEvictsPinned() {
        let half = ClipboardHistoryLogic.maxMediaBytes / 2
        let entries = [
            imageEntry(hash: "p1", bytes: half, pinned: true),
            imageEntry(hash: "p2", bytes: half, pinned: true),
            imageEntry(hash: "plain", bytes: half),
        ]
        let clean = ClipboardHistoryLogic.sanitized(entries)
        XCTAssertEqual(clean.map(\.contentHash), ["p1", "p2"])
        XCTAssertTrue(clean.allSatisfy(\.pinned))
    }

    /// 仅置顶就已超预算 → 停收新富媒体，不动已有条目（不自动解顶）。
    func testMediaAdmissionRefusedOnlyWhenPinnedAloneOverBudget() {
        let over = ClipboardHistoryLogic.maxMediaBytes + 1
        let pinnedOver = [imageEntry(hash: "p", bytes: over, pinned: true)]
        let candidate = imageEntry(hash: "new", bytes: 1024)
        XCTAssertFalse(ClipboardHistoryLogic.admitsMedia(candidate, into: pinnedOver))
        XCTAssertEqual(ClipboardHistoryLogic.recording(candidate, into: pinnedOver).count, 1)

        // 恰好等于预算时仍准入，由淘汰兜底（新条插在未置顶区首位，先被淘汰的轮不到它）。
        let half = ClipboardHistoryLogic.maxMediaBytes / 2
        let pinnedExact = [
            imageEntry(hash: "p1", bytes: half, pinned: true),
            imageEntry(hash: "p2", bytes: half, pinned: true),
        ]
        XCTAssertTrue(ClipboardHistoryLogic.admitsMedia(candidate, into: pinnedExact))
        // 但淘汰之后没有它的位置：结果与输入逐字段相同，调用方据此回收刚落盘的文件。
        XCTAssertEqual(
            ClipboardHistoryLogic.recording(candidate, into: pinnedExact),
            pinnedExact
        )
    }

    /// 文本条目不计入媒体预算：99KB 正文再长也挤不掉图片额度。
    func testTextEntriesDoNotConsumeMediaBudget() {
        let text = String(repeating: "x", count: ClipboardHistoryLogic.maxSingleBytes - 1)
        XCTAssertEqual(ClipboardHistoryLogic.mediaByteSize(of: ClipboardEntry(text: text)), 0)
        XCTAssertEqual(
            ClipboardHistoryLogic.mediaByteSize(
                of: ClipboardEntry(text: "/tmp/whatever.pdf", kind: .file, fileURLs: ["/tmp/whatever.pdf"])
            ),
            0,
            "文件条目只在正文里存路径，不占磁盘"
        )
    }

    /// 去重身份按类型分支：正文不可比的类型各走各的键。
    func testMatchKeyIsKindAware() {
        XCTAssertEqual(ClipboardHistoryLogic.matchKey(ClipboardEntry(text: "same")), "text:same")
        XCTAssertEqual(
            ClipboardHistoryLogic.matchKey(imageEntry(hash: "abc", bytes: 1)),
            "image:abc"
        )
        XCTAssertEqual(
            ClipboardHistoryLogic.matchKey(
                ClipboardEntry(text: "/a\n/b", kind: .file, fileURLs: ["/a", "/b"])
            ),
            "file:/a\n/b"
        )
    }

    // MARK: 文件载荷取舍（2026-09-20-clipboard-image-file-and-cache-echo）

    /// 图片扩展名 → 按图像读；其余 → 按文件引用收。
    func testImageUTIRecognizesImageExtensionsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func make(_ name: String) throws -> String {
            let url = root.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url.path
        }

        for name in ["a.png", "b.jpg", "c.jpeg", "d.heic", "e.tiff"] {
            XCTAssertNotNil(
                ClipboardFilePayloadPolicy.imageUTIForSingleFile(at: try make(name)),
                "\(name) 应当按图片读"
            )
        }
        for name in ["a.pdf", "b.zip", "c.txt", "d.swift", "noextension"] {
            XCTAssertNil(
                ClipboardFilePayloadPolicy.imageUTIForSingleFile(at: try make(name)),
                "\(name) 不该按图片读"
            )
        }
    }

    /// 缓存根目录下的路径一律不收；前缀相似但不在根内的不得误伤。
    func testDisposableCachePathMatchesOnlyInsideCacheRoot() {
        let root = "/tmp/fake-caches"
        XCTAssertTrue(ClipboardFilePayloadPolicy.isDisposableCachePath("/tmp/fake-caches/WeType/dsclp/1.png", cachesRoot: root))
        XCTAssertTrue(ClipboardFilePayloadPolicy.isDisposableCachePath("/tmp/fake-caches", cachesRoot: root))
        XCTAssertFalse(
            ClipboardFilePayloadPolicy.isDisposableCachePath("/tmp/fake-caches-other/1.png", cachesRoot: root),
            "同前缀不同目录不算命中——字符串比较必须带分隔符"
        )
        XCTAssertFalse(ClipboardFilePayloadPolicy.isDisposableCachePath("/tmp/elsewhere/1.png", cachesRoot: root))
        XCTAssertFalse(
            ClipboardFilePayloadPolicy.isDisposableCachePath("/tmp/fake-caches/1.png", cachesRoot: nil),
            "拿不到缓存根时不得把一切都当缓存"
        )
        // 真实根：输入法缓存命中，应用自己的媒体目录（同在 ~/Library 下）不命中。
        if let real = ClipboardFilePayloadPolicy.systemCachesRoot {
            XCTAssertTrue(ClipboardFilePayloadPolicy.isDisposableCachePath(real + "/WeType/dsclp/1.png"))
            XCTAssertFalse(
                ClipboardFilePayloadPolicy.isDisposableCachePath(
                    real.replacingOccurrences(of: "/Caches", with: "/Application Support/CleanShot/media/x.png")
                )
            )
        }
    }

    /// 载荷里同时有图像与文件路径时，图像胜——这条锁住 2026-09-20 的归类反转。
    func testImagePayloadWinsOverFilePathInClassification() {
        let capture = ClipboardCapture(
            filePaths: ["/tmp/whatever.png"],
            imageData: Self.makePNG(width: 4, height: 4),
            imageUTI: "public.png",
            imageHash: "hash-a"
        )
        XCTAssertEqual(ClipboardHistoryLogic.classify(capture), .image)
        XCTAssertEqual(ClipboardHistoryLogic.makeEntry(from: capture)?.kind, .image)
    }


    // MARK: 临时文件

    /// 造若干真实存在的临时文件——文件条目只持有路径引用，路径得真的存在。
    private func makeTempFiles(_ count: Int, under root: URL) throws -> [String] {
        let directory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let url = directory.appendingPathComponent("file-\(index).txt")
            try Data("body-\(index)".utf8).write(to: url)
            return url.path
        }
    }
}
