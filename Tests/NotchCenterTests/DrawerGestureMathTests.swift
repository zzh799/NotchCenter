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

    // MARK: - ResizeSpanResolver（盒语义：逐轴死区量化 + 钳进 [min...max]）

    /// 常见盒：宽 1×2…4×2（等价旧 wideSpans 的包络盒）。
    private let box = (
        min: GridSpan(columns: 1, rows: 2),
        max: GridSpan(columns: 4, rows: 2)
    )

    func testPressWithZeroTranslationKeepsCurrentSpan() {
        // 按下瞬间位移为零：目标即当前尺寸，不会瞬间缩小。
        let base = GridSpan(columns: 2, rows: 2)
        let resolved = ResizeSpanResolver.resolve(
            base: base,
            translation: .zero,
            current: base,
            minSize: box.min,
            maxSize: box.max,
            metrics: metrics
        )
        XCTAssertEqual(resolved, base)
    }

    func testDeadBandJitterDoesNotToggleSpan() {
        // 半格边界（81pt = 0.5 格）附近抖动：死区吸收，跨度不动。
        // 没有死区时这里会在 2×2 与 3×2 之间逐事件翻转（预览闪烁）。
        var current = GridSpan(columns: 2, rows: 2)
        for offset in [81, 95, 78, 88, 82, 79] {
            current = ResizeSpanResolver.resolve(
                base: GridSpan(columns: 2, rows: 2),
                translation: CGSize(width: CGFloat(offset), height: 0),
                current: current,
                minSize: box.min,
                maxSize: box.max,
                metrics: metrics
            )
        }
        XCTAssertEqual(current, GridSpan(columns: 2, rows: 2))
    }

    func testSwitchesBeyondDeadBand() {
        // 150pt ≈ 0.93 格，越过 0.5 + band 的死区边界 → 量化值升到 3 格；
        // 盒内 3 列可直接停靠（全矩形可达，无需落在离散档上）。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 2, rows: 2),
            translation: CGSize(width: 150, height: 0),
            current: GridSpan(columns: 2, rows: 2),
            minSize: box.min,
            maxSize: box.max,
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 3, rows: 2))
    }

    func testLargeDragClampsToDeclaredMaxSize() {
        // 300pt ≈ 1.85 格 → 量化远超 4 → 钳到盒上界 4×2（不再吸附后取最近档）。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 2, rows: 2),
            translation: CGSize(width: 300, height: 0),
            current: GridSpan(columns: 2, rows: 2),
            minSize: box.min,
            maxSize: box.max,
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 4, rows: 2))
    }

    func testShrinkClampsToDeclaredMinSize() {
        // 向左猛拖：量化低于 1 → 钳到盒下界 1 列（不得小于组件最小尺寸）。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 3, rows: 2),
            translation: CGSize(width: -162 * 20, height: 0),
            current: GridSpan(columns: 3, rows: 2),
            minSize: box.min,
            maxSize: box.max,
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 1, rows: 2))
    }

    func testMinSizeAboveOneBlocksShrinkingBelowIt() {
        // 组件最小宽 2 列：拖得再狠也停不下 1 列。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 2, rows: 2),
            translation: CGSize(width: -162 * 20, height: 0),
            current: GridSpan(columns: 2, rows: 2),
            minSize: GridSpan(columns: 2, rows: 2),
            maxSize: GridSpan(columns: 4, rows: 2),
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 2, rows: 2))
    }

    func testRowClampUpperBound() {
        // 行上界 = min(声明 max 行, DrawerResizeLimits.maxRows)。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 1, rows: 1),
            translation: CGSize(width: 0, height: 132 * 20),
            current: GridSpan(columns: 1, rows: 1),
            minSize: GridSpan(columns: 1, rows: 1),
            maxSize: GridSpan(columns: 1, rows: 8),
            metrics: metrics
        )
        XCTAssertEqual(resolved.rows, DrawerResizeLimits.maxRows)
    }

    /// 存量超盒（插件更新后显示跨度在盒外）的手势语义：首个像素级位移即被
    /// 钳进盒内（这里 4 行 > 声明 max 2 行，向下拖一格直接夹回 2）。
    func testLegacyOutOfBoxSpanClampsIntoBoxOnFirstDrag() {
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 2, rows: 4),
            translation: CGSize(width: 162, height: 132),
            current: GridSpan(columns: 2, rows: 4),
            minSize: GridSpan(columns: 1, rows: 1),
            maxSize: GridSpan(columns: 4, rows: 2),
            metrics: metrics
        )
        XCTAssertEqual(resolved, GridSpan(columns: 3, rows: 2))
    }

    func testZeroTranslationKeepsOutOfBoxLegacySpanClamped() {
        // 存量 4×2 但声明 max 2×2：位移为零也应先钳回盒内（预览从盒内起步，
        // 不会把"已超界"的显示尺寸当作可维持状态）。
        let resolved = ResizeSpanResolver.resolve(
            base: GridSpan(columns: 4, rows: 2),
            translation: .zero,
            current: GridSpan(columns: 4, rows: 2),
            minSize: GridSpan(columns: 1, rows: 1),
            maxSize: GridSpan(columns: 2, rows: 2),
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
