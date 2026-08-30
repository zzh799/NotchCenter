import CoreGraphics
import XCTest
@testable import NotchCenter

/// 面板尺寸指标回归：`applyPreviewWindowSize` 与 `applyDropPreviewWindowSize`
/// 此前各自算一遍内容/窗口尺寸，两者的差异（"谁不许写 `drawerGridLeftColumn`"）
/// 只存在于注释里。抽成纯计算后，这里把差异钉成断言。
final class DrawerLayoutMetricsTests: XCTestCase {
    private let metrics = GridMetrics(
        cellWidth: 150, cellHeight: 120, spacing: 12,
        contentPadding: 16, topBarHeight: 36
    )

    private func geometry(capacity: Int = 4, leftColumn: Int = 0) -> DrawerGridGeometry {
        DrawerGridGeometry(metrics: metrics, leftColumn: leftColumn, capacity: capacity)
    }

    // MARK: - pushed（块已被推挤）

    func testPushedUsesColumnRangeAndBottomRow() {
        let result = DrawerLayoutMetricsResolver.pushed(
            columnRange: (min: 1, max: 3),
            bottomRow: 4,
            geometry: geometry(),
            maxHeight: nil
        )
        // 跨度 = 3 − 1 = 2 列；行 4。
        XCTAssertEqual(result.contentSize.width, 312, accuracy: 1e-9)
        XCTAssertEqual(result.contentSize.height, 516, accuracy: 1e-9)
        // 窗口 = 内容 + 左右内边距 / 顶栏 + 内容 + 底部内边距。
        XCTAssertEqual(result.windowSize.width, 344, accuracy: 1e-9)
        XCTAssertEqual(result.windowSize.height, 568, accuracy: 1e-9)
        XCTAssertEqual(result.leftColumn, 1)
    }

    func testPushedClampsSpanToCapacity() {
        let result = DrawerLayoutMetricsResolver.pushed(
            columnRange: (min: 0, max: 8),
            bottomRow: 2,
            geometry: geometry(capacity: 4),
            maxHeight: nil
        )
        XCTAssertEqual(result.contentSize.width, metrics.width(columns: 4), accuracy: 1e-9)
    }

    func testPushedFloorsSpanAndRowsAtOne() {
        let result = DrawerLayoutMetricsResolver.pushed(
            columnRange: (min: 2, max: 2),
            bottomRow: 0,
            geometry: geometry(),
            maxHeight: nil
        )
        XCTAssertEqual(result.contentSize.width, metrics.width(columns: 1), accuracy: 1e-9)
        XCTAssertEqual(result.contentSize.height, metrics.height(rows: 1), accuracy: 1e-9)
    }

    // MARK: - dropZone（只有占位框）

    func testDropZoneNeverWritesLeftColumn() {
        // 关键约束：落点预览写左列 = 全体块横移，与「拖动期间其余块零位移」
        // 直接冲突。`leftColumn == nil` 就是这个约束的类型化表达。
        let result = DrawerLayoutMetricsResolver.dropZone(
            leftColumn: 2,
            rightEdge: 5,
            rows: 3,
            geometry: geometry(),
            maxHeight: nil
        )
        XCTAssertNil(result.leftColumn)
    }

    func testDropZoneSpanIsMeasuredFromLeftColumn() {
        // 跨度 = rightEdge − leftColumn，不是从 0 起算。
        let result = DrawerLayoutMetricsResolver.dropZone(
            leftColumn: 2,
            rightEdge: 5,
            rows: 3,
            geometry: geometry(),
            maxHeight: nil
        )
        XCTAssertEqual(result.contentSize.width, metrics.width(columns: 3), accuracy: 1e-9)
        XCTAssertEqual(result.contentSize.height, metrics.height(rows: 3), accuracy: 1e-9)
    }

    // MARK: - 屏幕封顶

    func testScreenHeightCapsWindowButNotContent() {
        let uncapped = DrawerLayoutMetricsResolver.pushed(
            columnRange: (min: 0, max: 1),
            bottomRow: 20,
            geometry: geometry(),
            maxHeight: nil
        )
        let capped = DrawerLayoutMetricsResolver.pushed(
            columnRange: (min: 0, max: 1),
            bottomRow: 20,
            geometry: geometry(),
            maxHeight: 400
        )
        XCTAssertEqual(capped.windowSize.height, 400, accuracy: 1e-9)
        XCTAssertGreaterThan(uncapped.windowSize.height, 400)
        // 内容尺寸不受封顶影响：它决定 ScrollView 真正可滚的范围。
        XCTAssertEqual(capped.contentSize.height, uncapped.contentSize.height, accuracy: 1e-9)
    }

    // MARK: - 幂等

    func testSameInputsYieldEqualMetrics() {
        // 两个 apply 方法都靠"值与当前不同才写"来避免每帧重启 spring。
        // 纯计算必须稳定，否则去重守卫形同虚设（表现为面板尺寸抖动）。
        let first = DrawerLayoutMetricsResolver.pushed(
            columnRange: (min: 0, max: 2),
            bottomRow: 3,
            geometry: geometry(),
            maxHeight: 900
        )
        let second = DrawerLayoutMetricsResolver.pushed(
            columnRange: (min: 0, max: 2),
            bottomRow: 3,
            geometry: geometry(),
            maxHeight: 900
        )
        XCTAssertEqual(first, second)
    }
}
