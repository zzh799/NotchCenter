import CoreGraphics
import NotchCenterKit
import XCTest
@testable import NotchCenter

/// 抽屉手势数学回归：`DrawerPanelView` / `DrawerBlockContainer` 里的拖拽与
/// 缩放计算剥成纯函数后的行为锁定。
///
/// 这些断言钉的是**当前手感**，不是理论最优值——重构阶段刻意不改行为，
/// 所以每条用例都按"改动前是什么样"来写。
final class DrawerGestureMathTests: XCTestCase {
    // 显式构造指标，不依赖进程级单例 `GridMetricsStore.shared`
    // （`SettingsLayoutTests` 会改它且未还原，会让用例互相污染）。
    // stepWidth = 162，stepHeight = 132。
    private let metrics = GridMetrics(
        cellWidth: 150,
        cellHeight: 120,
        spacing: 12,
        contentPadding: 16,
        topBarHeight: 36
    )

    private func placement(
        column: Int = 0,
        row: Int = 0,
        columns: Int = 1,
        rows: Int = 1
    ) -> PlacedBlock {
        PlacedBlock(
            pluginID: "plugin",
            blockID: "block",
            placementID: "placement",
            originColumn: column,
            originRow: row,
            widthColumns: columns,
            heightRows: rows
        )
    }

    // MARK: - DragTargetResolver

    func testZeroTranslationKeepsOrigin() {
        let target = DragTargetResolver.target(
            placement: placement(column: 2, row: 3),
            translation: .zero,
            metrics: metrics
        )
        XCTAssertEqual(target.column, 2)
        XCTAssertEqual(target.row, 3)
    }

    func testSubHalfStepDoesNotMove() {
        // 80pt < 0.5 × 162：round 回 0 格。
        let target = DragTargetResolver.target(
            placement: placement(),
            translation: CGSize(width: 80, height: 65),
            metrics: metrics
        )
        XCTAssertEqual(target.column, 0)
        XCTAssertEqual(target.row, 0)
    }

    func testFullStepMovesExactlyOneCell() {
        let target = DragTargetResolver.target(
            placement: placement(column: 1, row: 1),
            translation: CGSize(width: 162, height: 132),
            metrics: metrics
        )
        XCTAssertEqual(target.column, 2)
        XCTAssertEqual(target.row, 2)
    }

    func testNegativeTranslationMovesBackwards() {
        let target = DragTargetResolver.target(
            placement: placement(column: 3, row: 2),
            translation: CGSize(width: -162, height: -132),
            metrics: metrics
        )
        XCTAssertEqual(target.column, 2)
        XCTAssertEqual(target.row, 1)
    }

    func testDragTargetCanGoNegative() {
        // 向左拖出网格：列可为负（左扩，面板随之重居中）。
        let target = DragTargetResolver.target(
            placement: placement(),
            translation: CGSize(width: -324, height: 0),
            metrics: metrics
        )
        XCTAssertEqual(target.column, -2)
    }

    // MARK: - ResizeSpanResolver

    private let wideSpans = [
        GridSpan(columns: 1, rows: 2),
        GridSpan(columns: 2, rows: 2),
        GridSpan(columns: 4, rows: 2)
    ]

    func testPressWithZeroTranslationKeepsCurrentSpan() {
        // 按下瞬间位移为零：目标即当前尺寸，不会瞬间缩小。
        let base = GridSpan(columns: 2, rows: 2)
        let resolved = ResizeSpanResolver.resolve(
            base: base,
            translation: .zero,
            current: base,
            supportedSpans: wideSpans,
            metrics: metrics
        )
        XCTAssertEqual(resolved, base)
    }

    func testDeadBandJitterDoesNotToggleSpan() {
        // 半格边界（81pt = 0.5 格）附近抖动：死区吸收，档位不动。
        // 没有死区时这里会在 2×2 与 3×2 之间逐事件翻转（预览闪烁）。
        var current = GridSpan(columns: 2, rows: 2)
        for offset in [81, 95, 78, 88, 82, 79] {
            guard let next = ResizeSpanResolver.resolve(
                base: GridSpan(columns: 2, rows: 2),
                translation: CGSize(width: CGFloat(offset), height: 0),
                current: current,
                supportedSpans: wideSpans,
                metrics: metrics
            ) else { continue }
            current = next
        }
        XCTAssertEqual(current, GridSpan(columns: 2, rows: 2))
    }

    func testSwitchesBeyondDeadBand() {
        // 150pt ≈ 0.93 格，越过 0.5 + band 的死区边界 → 量化值升到 3 格。
        let quantized = ResizeSpanResolver.quantized(
            base: GridSpan(columns: 2, rows: 2),
            translation: CGSize(width: 150, height: 0),
            current: GridSpan(columns: 2, rows: 2),
            metrics: metrics
        )
        XCTAssertEqual(quantized.columns, 3)
    }

    func testLargeDragSnapsToLargestSupportedSpan() {
        // 300pt ≈ 1.85 格 → 量化 4 格 → 吸附到 4×2。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 2, rows: 2),
            translation: CGSize(width: 300, height: 0),
            current: GridSpan(columns: 2, rows: 2),
            supportedSpans: wideSpans,
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 4, rows: 2))
    }

    func testEquidistantSpanKeepsFirstCandidate() {
        // 量化到 3 格时，(2,2) 与 (4,2) 的 L1 距离都是 1；严格 `<` 才替换，
        // 于是保留先出现的 (2,2)。只锁定现状，不要在业务上依赖这个顺序。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 2, rows: 2),
            translation: CGSize(width: 150, height: 0),
            current: GridSpan(columns: 2, rows: 2),
            supportedSpans: wideSpans,
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 2, rows: 2))
    }

    func testRowClampUpperBound() {
        let quantized = ResizeSpanResolver.quantized(
            base: GridSpan(columns: 1, rows: 1),
            translation: CGSize(width: 0, height: 132 * 20),
            current: GridSpan(columns: 1, rows: 1),
            metrics: metrics
        )
        XCTAssertEqual(quantized.rows, DrawerResizeLimits.maxRows)
    }

    func testColumnClampLowerBound() {
        let quantized = ResizeSpanResolver.quantized(
            base: GridSpan(columns: 2, rows: 2),
            translation: CGSize(width: -162 * 20, height: 0),
            current: GridSpan(columns: 2, rows: 2),
            metrics: metrics
        )
        XCTAssertEqual(quantized.columns, 1)
    }

    // KNOWN BUG：横向夹紧上界是常量 4，与 `effectiveMaxColumns()` 脱钩。
    // 容量 < 4（用户把 maxColumns 调到 2/3，或屏幕窄）时，块仍能被撑到
    // 4 列——`previewArrangement(resizing:)` 只 clamp originColumn、不截断
    // width，于是能写出「跨度 4 > 容量 2」的布局。
    // 修复 `DrawerResizeLimits.legacyColumnUpperBound` 时，把这条断言改成
    // 「上界 = 容量」的期望值。
    func testColumnUpperBoundIgnoresCapacity() {
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 1, rows: 2),
            translation: CGSize(width: 162 * 10, height: 0),
            current: GridSpan(columns: 1, rows: 2),
            supportedSpans: wideSpans,
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 4, rows: 2))
    }

    /// 修复路径已留好：把容量作为上界传入即可，无需改调用点以外的代码。
    func testColumnUpperBoundIsConfigurable() {
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 1, rows: 2),
            translation: CGSize(width: 162 * 10, height: 0),
            current: GridSpan(columns: 1, rows: 2),
            supportedSpans: wideSpans,
            metrics: metrics,
            columnUpperBound: 2
        )
        XCTAssertEqual(resolved, GridSpan(columns: 2, rows: 2))
    }

    func testEmptySupportedSpansYieldsNil() {
        XCTAssertNil(
            ResizeSpanResolver.resolve(
                base: GridSpan(columns: 1, rows: 1),
                translation: .zero,
                current: GridSpan(columns: 1, rows: 1),
                supportedSpans: [],
                metrics: metrics
            )
        )
    }

    func testNearestSpanByManhattanDistance() {
        // 距离相同时取数组第一个：不要依赖具体顺序，这里只是锁定现状。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 2, rows: 2),
            translation: .zero,
            current: GridSpan(columns: 2, rows: 2),
            supportedSpans: [
                GridSpan(columns: 3, rows: 3),
                GridSpan(columns: 2, rows: 2)
            ],
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 2, rows: 2))
    }

    // MARK: - ResizeCompensation

    func testCompensationAnchorsTopLeftWhenGrowing() {
        // 1×1 = 150×120 → 2×2 = 312×252：增长量的一半 (81, 66)。
        let offset = ResizeCompensation.offset(
            from: GridSpan(columns: 1, rows: 1),
            to: GridSpan(columns: 2, rows: 2),
            metrics: metrics
        )
        XCTAssertEqual(offset.width, 81, accuracy: 1e-9)
        XCTAssertEqual(offset.height, 66, accuracy: 1e-9)
    }

    func testCompensationIsNegativeWhenShrinking() {
        let offset = ResizeCompensation.offset(
            from: GridSpan(columns: 2, rows: 2),
            to: GridSpan(columns: 1, rows: 1),
            metrics: metrics
        )
        XCTAssertEqual(offset.width, -81, accuracy: 1e-9)
        XCTAssertEqual(offset.height, -66, accuracy: 1e-9)
    }

    func testCompensationIsZeroWhenUnchanged() {
        let offset = ResizeCompensation.offset(
            from: GridSpan(columns: 2, rows: 3),
            to: GridSpan(columns: 2, rows: 3),
            metrics: metrics
        )
        XCTAssertEqual(offset, .zero)
    }

    func testCompensationWithZeroSpacing() {
        // 间距为 0 时内容尺寸退化为 格数 × 单元格：100 → 300、80 → 240。
        let tight = GridMetrics(
            cellWidth: 100,
            cellHeight: 80,
            spacing: 0,
            contentPadding: 8,
            topBarHeight: 36
        )
        let offset = ResizeCompensation.offset(
            from: GridSpan(columns: 1, rows: 1),
            to: GridSpan(columns: 3, rows: 3),
            metrics: tight
        )
        XCTAssertEqual(offset.width, 100, accuracy: 1e-9)
        XCTAssertEqual(offset.height, 80, accuracy: 1e-9)
    }
}
