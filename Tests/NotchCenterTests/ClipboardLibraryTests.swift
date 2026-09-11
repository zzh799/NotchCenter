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
