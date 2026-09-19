import Foundation
import NotchCenterKit
import XCTest
@testable import ClipboardHistoryPlugin

/// 剪贴板库回归（Agent Note 2026-09-11-p0-system-pages §3）：
/// 类型推断（链接 / 颜色 / 文本的边界）、颜色字面量解析、
/// 库页双条件过滤（类型 + 搜索）、置顶/最近分段、
/// 以及**旧 `history.entries.v1` 数据的向后兼容解码**（最关键的一条）。
@MainActor
final class ClipboardLibraryTests: XCTestCase {
    // MARK: 类型推断

    func testClassifyLink() {
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "https://example.com/a?b=1"), .link)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "http://example.com"), .link)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "mailto:a@b.com"), .link)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "  https://example.com  "), .link)
    }

    func testClassifyNonLinkSchemesAndBareText() {
        // 非白名单 scheme 不算链接（避免把伪协议当地址）。
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "notion://page/123"), .text)
        // 只有 scheme 没有 host 的不算。
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "http://"), .text)
        // 含空白的整段文字不算链接。
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "see https://example.com here"), .text)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "just some words"), .text)
    }

    func testClassifyColor() {
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "#fff"), .color)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "#1A2B3C"), .color)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "#1A2B3CFF"), .color)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "rgb(10, 20, 30)"), .color)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "rgba(10,20,30,0.5)"), .color)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "hsl(200, 50%, 40%)"), .color)
        // 位数不对 / 含非法字符的不是颜色。
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "#12345"), .text)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "#gggggg"), .text)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "#"), .text)
    }

    func testClassifyEmptyIsText() {
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: ""), .text)
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "   "), .text)
    }

    func testColorWinsOverLink() {
        // `#fff` 也能被 URL(string:) 接受，必须先判颜色。
        XCTAssertEqual(ClipboardHistoryLogic.classify(text: "#abcdef"), .color)
    }

    // MARK: 颜色分量解析

    func testHexColorComponents() {
        let components = ClipboardColorParsing.components(from: "#FF8000")
        XCTAssertEqual(components?.red ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(components?.green ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(components?.blue ?? 0, 0.0, accuracy: 0.001)
        XCTAssertEqual(components?.alpha ?? 0, 1.0, accuracy: 0.001)
    }

    func testShortHexExpands() {
        let components = ClipboardColorParsing.components(from: "#f00")
        XCTAssertEqual(components?.red ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(components?.green ?? 0, 0.0, accuracy: 0.001)
    }

    func testHexWithAlpha() {
        let components = ClipboardColorParsing.components(from: "#00000080")
        XCTAssertEqual(components?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
    }

    func testRGBFunctionComponents() {
        let components = ClipboardColorParsing.components(from: "rgb(255, 0, 128)")
        XCTAssertEqual(components?.red ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(components?.blue ?? 0, 128.0 / 255, accuracy: 0.001)
        let withAlpha = ClipboardColorParsing.components(from: "rgba(0, 0, 0, 0.25)")
        XCTAssertEqual(withAlpha?.alpha ?? 0, 0.25, accuracy: 0.001)
    }

    func testInvalidColorTextReturnsNil() {
        XCTAssertNil(ClipboardColorParsing.components(from: "not a color"))
        XCTAssertNil(ClipboardColorParsing.components(from: "#12345"))
        XCTAssertNil(ClipboardColorParsing.components(from: "rgb(1,2)"))
        XCTAssertNil(ClipboardColorParsing.components(from: ""))
    }

    // MARK: 库页过滤

    private func entry(_ text: String, pinned: Bool = false, kind: ClipboardEntryKind? = nil) -> ClipboardEntry {
        ClipboardEntry(text: text, pinned: pinned, kind: kind)
    }

    func testLibraryFilteredByKindOnly() {
        let entries = [
            entry("https://example.com"),
            entry("#ff0000"),
            entry("plain text"),
        ]
        let links = ClipboardHistoryLogic.libraryFiltered(entries, query: "", kinds: [.link])
        XCTAssertEqual(links.map(\.text), ["https://example.com"])
        // 空集 = 不过滤。
        XCTAssertEqual(ClipboardHistoryLogic.libraryFiltered(entries, query: "", kinds: []).count, 3)
    }

    func testLibraryFilteredByQueryAndKindIsConjunction() {
        let entries = [
            entry("https://example.com/docs"),
            entry("https://other.com"),
            entry("plain text"),
        ]
        let result = ClipboardHistoryLogic.libraryFiltered(entries, query: "docs", kinds: [.link])
        XCTAssertEqual(result.map(\.text), ["https://example.com/docs"])
    }

    func testLibraryFilteredMultipleKinds() {
        let entries = [entry("https://a.com"), entry("#fff"), entry("word")]
        let result = ClipboardHistoryLogic.libraryFiltered(entries, query: "", kinds: [.link, .color])
        XCTAssertEqual(result.count, 2)
    }

    func testLibrarySectionsSplitPinnedFirst() {
        let entries = [
            entry("p1", pinned: true),
            entry("n1"),
            entry("p2", pinned: true),
            entry("n2"),
        ]
        let sections = ClipboardHistoryLogic.librarySections(entries)
        XCTAssertEqual(sections.pinned.map(\.text), ["p1", "p2"])
        XCTAssertEqual(sections.recent.map(\.text), ["n1", "n2"])
    }

    // MARK: 向后兼容解码（本功能最关键的一条）

    func testDecodesLegacyEntryWithoutNewFields() throws {
        // 旧 history.entries.v1 的实际形状：只有四个键。
        let legacy = """
        [{"id":"\(UUID().uuidString)","text":"https://legacy.example.com","capturedAt":760000000,"pinned":true}]
        """
        let decoder = JSONDecoder()
        let entries = try decoder.decode([ClipboardEntry].self, from: Data(legacy.utf8))
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.text, "https://legacy.example.com")
        XCTAssertTrue(entry.pinned)
        XCTAssertNil(entry.previewData)
        XCTAssertNil(entry.sourceApp)
        // 富媒体四项同理：旧数据没有它们，必须落成"无载荷"而不是解码失败。
        XCTAssertEqual(entry.fileURLs, [])
        XCTAssertNil(entry.contentHash)
        XCTAssertNil(entry.storedMediaName)
        XCTAssertNil(entry.mediaByteSize)
        XCTAssertNil(entry.mediaUTI)
        // 旧数据没有 kind：按正文重新推断，而不是一律记成 text。
        XCTAssertEqual(entry.kind, .link)
    }

    func testDecodesLegacyPlainTextEntryAsText() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","text":"just words","capturedAt":760000000,"pinned":false}]
        """
        let entries = try JSONDecoder().decode([ClipboardEntry].self, from: Data(legacy.utf8))
        XCTAssertEqual(entries.first?.kind, .text)
    }

    func testRoundTripsNewFieldsThroughCoding() throws {
        let original = ClipboardEntry(
            text: "#00ff00",
            pinned: true,
            kind: .color,
            previewData: Data([1, 2, 3]),
            sourceApp: "com.example.app"
        )
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([ClipboardEntry].self, from: data)
        XCTAssertEqual(decoded, [original])
    }

    func testEmptyLegacyArrayDecodes() throws {
        let entries = try JSONDecoder().decode([ClipboardEntry].self, from: Data("[]".utf8))
        XCTAssertTrue(entries.isEmpty)
    }

    /// 富媒体载荷也必须原样往返——键名沿用 v1，编码器不得漏写任何一个。
    func testRoundTripsMediaFieldsThroughCoding() throws {
        let original = ClipboardEntry(
            text: "/tmp/a.pdf",
            kind: .file,
            fileURLs: ["/tmp/a.pdf", "/tmp/b.pdf"],
            contentHash: "deadbeef",
            storedMediaName: "ABC.png",
            mediaByteSize: 4096,
            mediaUTI: "public.png"
        )
        let decoded = try JSONDecoder().decode(
            [ClipboardEntry].self,
            from: try JSONEncoder().encode([original])
        )
        XCTAssertEqual(decoded, [original])
    }

    func testSanitizedKeepsLegacyBehaviourWithKinds() {
        // 置顶封顶与淘汰策略在引入 kind 后行为不变。
        let entries = (1...60).map { index in
            ClipboardEntry(text: "entry \(index)", pinned: index <= 3)
        }
        let sanitized = ClipboardHistoryLogic.sanitized(entries)
        XCTAssertEqual(sanitized.count, ClipboardHistoryLogic.maxEntries)
        XCTAssertEqual(sanitized.filter(\.pinned).count, 3)
    }

    func testRecordingStillDedupes() {
        let first = ClipboardHistoryLogic.recording("hello", into: [])
        let again = ClipboardHistoryLogic.recording("hello", into: first)
        XCTAssertEqual(again.count, 1)
    }

    // MARK: 扁平列表项（列表惰性化的契约）

    /// 行身份 = 条目 id，**不含分区**：置顶/解顶时身份不变，视图才始终落在同一个
    /// `ForEach` 里复用并随值重刷（旧结构让同 id 在两个 `ForEach` 容器间搬家）。
    func testListItemIdentityIgnoresSection() {
        let moved = entry("moves")
        let asRecent = ClipboardHistoryLogic.listItems(pinned: [], recent: [moved])
        let asPinned = ClipboardHistoryLogic.listItems(pinned: [moved], recent: [])
        XCTAssertEqual(asRecent.map(\.id), ["entry.\(moved.id.uuidString)"])
        XCTAssertEqual(asPinned.map(\.id), ["entry.\(moved.id.uuidString)"])
        XCTAssertEqual(asRecent.first?.id, asPinned.first?.id, "跨分区移动不得改变行身份")
        XCTAssertEqual(asRecent.first?.entry, asPinned.first?.entry)
        // 身份不变、但分组载荷随值变化——`Equatable` 把 section 计入正是为了让内容重刷。
        XCTAssertNotEqual(asRecent.first, asPinned.first)
    }

    /// 保序：置顶段在前、最近段在后，组界**只在两段之间**出现（首节上方仍无线）。
    func testListItemsKeepsOrderWithSingleBreakBetweenGroups() {
        let items = ClipboardHistoryLogic.listItems(
            pinned: [entry("p1", pinned: true), entry("p2", pinned: true)],
            recent: [entry("n1"), entry("n2")]
        )
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].entry?.text, "p1")
        XCTAssertEqual(items[1].entry?.text, "p2")
        XCTAssertEqual(items[2], .sectionBreak(.recent))
        XCTAssertEqual(items[3].entry?.text, "n1")
        XCTAssertEqual(items[4].entry?.text, "n2")
        XCTAssertEqual(items[0].entry?.pinned, true)
    }

    /// 某一段为空时不产生组界——否则列表顶部/尾部会多一条孤立发丝线。
    func testListItemsOmitsBreakWhenEitherGroupEmpty() {
        let recentOnly = ClipboardHistoryLogic.listItems(pinned: [], recent: [entry("n")])
        XCTAssertEqual(recentOnly.count, 1)
        XCTAssertEqual(recentOnly.first?.entry?.text, "n")
        let pinnedOnly = ClipboardHistoryLogic.listItems(pinned: [entry("p", pinned: true)], recent: [])
        XCTAssertEqual(pinnedOnly.count, 1)
        XCTAssertEqual(pinnedOnly.first?.entry?.text, "p")
        XCTAssertTrue(ClipboardHistoryLogic.listItems(pinned: [], recent: []).isEmpty)
    }

    /// 两个 id 空间不混用：组界走 `break.` 前缀、条目走 `entry.` 前缀，扁平后仍全局唯一。
    func testListItemsIdSpacesAreDisjointAndUnique() {
        let items = ClipboardHistoryLogic.listItems(
            pinned: [entry("p", pinned: true)],
            recent: [entry("n")]
        )
        let ids = items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "扁平列表 id 必须全局唯一")
        XCTAssertEqual(items.first { $0.entry == nil }?.id, "break.recent")
        let entryIDs = items.filter { $0.entry != nil }.map(\.id)
        XCTAssertEqual(entryIDs.count, 2)
        XCTAssertTrue(entryIDs.allSatisfy { $0.hasPrefix("entry.") }, "行 id 不得落进组界 id 空间")
    }

    /// 分区文案键：抽屉块借它拼行无障碍标签、库页借它做小节标题，两个键不得写反。
    func testSectionKindTitleKeys() {
        XCTAssertEqual(ClipboardSectionKind.pinned.titleKey, "drawer.section.pinned")
        XCTAssertEqual(ClipboardSectionKind.recent.titleKey, "drawer.section.recent")
    }

    // MARK: 块声明

    func testClipboardLibraryBlockDeclaration() {
        let block = ClipboardHistoryPlugin.blocks.first { $0.id == "clipboard.library" }
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.kind, .drawer)
        XCTAssertEqual(block?.placement, .newPageWhenOccupied)
        XCTAssertNil(block?.validationError)
    }

    func testClipboardLibraryProbesFitMinSize() {
        let block = ClipboardHistoryPlugin.blocks.first { $0.id == "clipboard.library" }
        guard let block, let minSize = block.minSize, let probes = block.probes else {
            return XCTFail("clipboard.library must declare minSize and probes")
        }
        let layout = BlockLayoutInfo(
            region: .drawer,
            placementID: "test",
            frame: CGRect(origin: .zero, size: minSize.size)
        )
        let violations = BlockSizeVerifier.violations(
            probes: probes(layout),
            contentSize: minSize.size
        )
        XCTAssertTrue(violations.isEmpty, "minSize 下探针不得越界或自叠：\(violations)")
    }
}
