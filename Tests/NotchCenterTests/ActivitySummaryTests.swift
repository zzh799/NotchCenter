import AppKit
import XCTest
import NotchCenterKit
@testable import NotchCenter

/// 紧凑带活动摘要回归（Agent Note 2026-09-03-compact-area-activity-summary）：
/// 宿主"左右各一、最新优先、收回回退"的展示排布（`ActivitySummaryDisplay`）
/// 与芯片宽度估算（`SummaryChipMetrics`）。
@MainActor
final class ActivitySummaryTests: XCTestCase {
    private func makeSummary(_ id: String, title: String = "专注中") -> ActivitySummary {
        ActivitySummary(id: id, title: title)
    }

    // MARK: ActivitySummaryDisplay — 展示排布

    func testEmptySequenceShowsNothing() {
        let pair = ActivitySummaryDisplay.visiblePair(from: [], drawerExpanded: false)
        XCTAssertNil(pair.left)
        XCTAssertNil(pair.right)
    }

    func testDrawerExpandedYieldsToDrawer() {
        // 抽屉展开期间摘要整体让位（与旧活动岛同一纪律），收起即恢复。
        let summaries = [makeSummary("a"), makeSummary("b")]
        let pair = ActivitySummaryDisplay.visiblePair(from: summaries, drawerExpanded: true)
        XCTAssertNil(pair.left)
        XCTAssertNil(pair.right)
    }

    func testSingleSummaryShowsNewestOnLeft() {
        let pair = ActivitySummaryDisplay.visiblePair(from: [makeSummary("a")], drawerExpanded: false)
        XCTAssertEqual(pair.left?.id, "a")
        XCTAssertNil(pair.right)
    }

    func testTwoSummariesShowNewestLeftSecondRight() {
        let summaries = [makeSummary("a"), makeSummary("b")]
        let pair = ActivitySummaryDisplay.visiblePair(from: summaries, drawerExpanded: false)
        XCTAssertEqual(pair.left?.id, "b", "最新在左")
        XCTAssertEqual(pair.right?.id, "a", "次新在右")
    }

    func testAtMostTwoVisibleIgnoringOlder() {
        // 至多展示最近两条；更早的提交只在较新的被收回后才有机会上位。
        let summaries = [makeSummary("a"), makeSummary("b"), makeSummary("c")]
        let pair = ActivitySummaryDisplay.visiblePair(from: summaries, drawerExpanded: false)
        XCTAssertEqual(pair.left?.id, "c")
        XCTAssertEqual(pair.right?.id, "b")
        XCTAssertNotEqual(pair.left?.id, "a")
    }

    func testRemovalFallsBackToNextNewest() {
        // 「收回回退」：收回最新后次新顶上空位（控制器 remove 后重算即达成）。
        let afterRemovingNewest = [makeSummary("a"), makeSummary("b")]
        let pair = ActivitySummaryDisplay.visiblePair(from: afterRemovingNewest, drawerExpanded: false)
        XCTAssertEqual(pair.left?.id, "b")
        XCTAssertEqual(pair.right?.id, "a")

        // 收回较旧的、只剩一条：单条独占左位。
        let single = [makeSummary("a")]
        let singlePair = ActivitySummaryDisplay.visiblePair(from: single, drawerExpanded: false)
        XCTAssertEqual(singlePair.left?.id, "a")
        XCTAssertNil(singlePair.right)
    }

    func testSameIDOverwriteKeepsSequencePosition() {
        // 同 id 覆盖更新 = 原位替换，不改变新旧次序：覆盖"a"后它仍是序列中
        // 较旧者，展示对不变（控制器层 append/替换语义的展示侧印证）。
        var summaries = [makeSummary("a"), makeSummary("b")]
        summaries[0] = ActivitySummary(id: "a", title: "更新后的主文案")
        let pair = ActivitySummaryDisplay.visiblePair(from: summaries, drawerExpanded: false)
        XCTAssertEqual(pair.left?.id, "b")
        XCTAssertEqual(pair.right?.id, "a")
        XCTAssertEqual(pair.right?.title, "更新后的主文案")
    }

    // MARK: SummaryChipMetrics — 宽度估算

    func testEstimatedWidthWithoutSymbolIsPaddingPlusTextPlusHeadroom() {
        // 无符号时 = 内边距 + 文案宽 + 估算余量（宁宽勿裁的基础公式）。
        let summary = ActivitySummary(id: "a", title: "正在播放", subtitle: nil, symbolName: nil)
        let width = SummaryChipMetrics.estimatedWidth(for: summary)
        XCTAssertEqual(
            width,
            ceil(SummaryChipMetrics.horizontalPadding + SummaryChipMetrics.textWidth(summary.title) + SummaryChipMetrics.measurementHeadroom)
        )
    }

    func testEstimatedWidthAddsSymbolRoom() {
        let withoutSymbol = ActivitySummary(id: "a", title: "专注中", symbolName: nil)
        let withSymbol = ActivitySummary(id: "a", title: "专注中", symbolName: "timer")
        XCTAssertGreaterThan(
            SummaryChipMetrics.estimatedWidth(for: withSymbol),
            SummaryChipMetrics.estimatedWidth(for: withoutSymbol)
        )
    }

    func testEstimatedWidthClampsAtMaximum() {
        // 超长文案不撑破带宽：封顶在 maxWidth（视图侧在芯片内截断兜底）。
        let long = ActivitySummary(id: "a", title: String(repeating: "专注", count: 60), symbolName: "timer")
        XCTAssertEqual(SummaryChipMetrics.estimatedWidth(for: long), SummaryChipMetrics.maxWidth)
    }

    func testEstimatedWidthIsMonotonicInTitleLength() {
        let short = ActivitySummary(id: "a", title: "专注", symbolName: "timer")
        let medium = ActivitySummary(id: "a", title: "专注进行中，剩余时间充足", symbolName: "timer")
        let shortWidth = SummaryChipMetrics.estimatedWidth(for: short)
        let mediumWidth = SummaryChipMetrics.estimatedWidth(for: medium)
        XCTAssertLessThanOrEqual(shortWidth, mediumWidth, "文案越长估算越宽（或相等）")
        XCTAssertLessThanOrEqual(mediumWidth, SummaryChipMetrics.maxWidth)
    }

    func testEstimatedWidthIncludesSubtitleOnSameLine() {
        // 副文案渲染在同一条文本行内，必须计入估算（否则芯片会裁到副文案）。
        // 进度不占文本宽。
        let titleOnly = ActivitySummary(id: "a", title: "正在播放", symbolName: "play.fill")
        let withSubtitle = ActivitySummary(
            id: "a",
            title: "正在播放",
            subtitle: "Artist — Track",
            symbolName: "play.fill",
            progress: 0.5
        )
        XCTAssertGreaterThan(
            SummaryChipMetrics.estimatedWidth(for: withSubtitle),
            SummaryChipMetrics.estimatedWidth(for: titleOnly),
            "副文案随行展示时估算应更宽"
        )
        XCTAssertLessThanOrEqual(
            SummaryChipMetrics.estimatedWidth(for: withSubtitle),
            SummaryChipMetrics.maxWidth
        )
    }
}
