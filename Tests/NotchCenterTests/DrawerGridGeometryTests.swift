import CoreGraphics
import NotchCenterKit
import XCTest
@testable import NotchCenter

/// 坐标换算回归：`drawerDropZone`（屏幕 → 格）与 `drawerScreenRect`
/// （格 → 屏幕）此前是两份各自手写的算术，靠注释约定"改一个必须改另一个"。
/// 现在两者共用 `DrawerScreenMapper`，互逆性由**结构**保证——这里用往返
/// 测试把它钉死，差一格就能在单测里发现，而不是等到肉眼看到落位跳动。
final class DrawerGridGeometryTests: XCTestCase {
    /// 可见面板（Cocoa，左下原点）：x 100...900，y 300...900，顶缘 y = 900。
    private let visible = CGRect(x: 100, y: 300, width: 800, height: 600)

    private func metrics(
        cellWidth: CGFloat = 150,
        cellHeight: CGFloat = 120,
        spacing: CGFloat = 12,
        contentPadding: CGFloat = 16
    ) -> GridMetrics {
        GridMetrics(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            spacing: spacing,
            contentPadding: contentPadding,
            topBarHeight: 36
        )
    }

    private func mapper(
        metrics: GridMetrics = GridMetrics(
            cellWidth: 150, cellHeight: 120, spacing: 12, contentPadding: 16, topBarHeight: 36
        ),
        leftColumn: Int = 0,
        capacity: Int = 4,
        compactHeight: CGFloat = 40
    ) -> DrawerScreenMapper {
        DrawerScreenMapper(
            visibleFrame: visible,
            topInset: compactHeight + metrics.topBarHeight,
            geometry: DrawerGridGeometry(
                metrics: metrics,
                leftColumn: leftColumn,
                capacity: capacity
            )
        )
    }

    // MARK: - 互逆性

    func testContentAndScreenPointsRoundTrip() {
        let mapper = self.mapper()
        for x in stride(from: -50, through: 900, by: 37.5) {
            for y in stride(from: -50, through: 700, by: 53.25) {
                let point = CGPoint(x: x, y: y)
                let back = mapper.contentPoint(fromScreen: mapper.screenPoint(fromContent: point))
                XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
                XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
            }
        }
    }

    func testCellToScreenRectAndBack() {
        // 覆盖左扩（负列基准）、默认与右偏三种渲染基准。
        for leftColumn in [-2, 0, 3] {
            let mapper = self.mapper(leftColumn: leftColumn)
            for column in (leftColumn - 2)...(leftColumn + 6) {
                for row in 0...8 {
                    let cell = GridCell(column: column, row: row, columnSpan: 2, rowSpan: 2)
                    let rect = mapper.screenRect(for: cell)
                    // 用**左上角**做往返（Cocoa 下 maxY 即顶缘）。中心点在
                    // rowSpan ≥ 3 时会落到下一格——那是"点→格"的定义所致，
                    // 不是互逆性缺陷。
                    let back = mapper.cell(
                        atScreen: CGPoint(x: rect.minX, y: rect.maxY),
                        span: cell.span
                    )
                    XCTAssertEqual(
                        back,
                        mapper.geometry.clamped(cell),
                        "leftColumn=\(leftColumn) column=\(column) row=\(row)"
                    )
                }
            }
        }
    }

    func testFrameAndCellAreInverses() {
        let geometry = DrawerGridGeometry(metrics: metrics(), leftColumn: -2, capacity: 4)
        for column in -2...4 {
            for row in 0...6 {
                let cell = GridCell(column: column, row: row, columnSpan: 1, rowSpan: 1)
                XCTAssertEqual(geometry.cell(at: geometry.frame(cell).origin), cell)
            }
        }
    }

    func testScreenRectOriginUsesTopLeftInContentSpace() {
        // 内容坐标 y 向下，Cocoa y 向上：矩形底边 = 顶缘 − 高度。
        let mapper = self.mapper()
        let rect = mapper.screenRect(
            for: GridCell(column: 0, row: 0, columnSpan: 2, rowSpan: 3)
        )
        XCTAssertEqual(rect.maxY, mapper.gridTopEdgeY, accuracy: 1e-9)
        XCTAssertEqual(rect.minX, visible.minX + 16, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 312, accuracy: 1e-9)   // 2 列：150×2 + 12
        XCTAssertEqual(rect.height, 384, accuracy: 1e-9)  // 3 行：120×3 + 12×2
    }

    // MARK: - 落点边界

    func testGridTopEdgeIsInclusive() {
        let mapper = self.mapper()
        XCTAssertNotNil(
            mapper.cell(
                atScreen: CGPoint(x: visible.midX, y: mapper.gridTopEdgeY),
                span: GridSpan(columns: 1, rows: 1)
            )
        )
        // 顶栏（按钮横条）不接受落点。
        XCTAssertNil(
            mapper.cell(
                atScreen: CGPoint(x: visible.midX, y: mapper.gridTopEdgeY + 1),
                span: GridSpan(columns: 1, rows: 1)
            )
        )
    }

    func testCapacityClampsColumnUpperBound() {
        // 容量 2、跨度 2 → 列上界 = 0 + 2 − 2 = 0，任何落点都被夹到第 0 列。
        let mapper = self.mapper(leftColumn: 0, capacity: 2)
        let cell = mapper.cell(
            atScreen: CGPoint(x: visible.maxX - 1, y: visible.minY + 1),
            span: GridSpan(columns: 2, rows: 1)
        )
        XCTAssertEqual(cell?.column, 0)
        XCTAssertEqual(cell?.columnSpan, 2)
    }

    func testColumnLowerBoundIsLeftColumn() {
        // 拖到面板左缘之外：夹到渲染基准列，不产生比基准更靠左的落点。
        let mapper = self.mapper(leftColumn: -2)
        let cell = mapper.cell(
            atScreen: CGPoint(x: visible.minX, y: visible.minY + 1),
            span: GridSpan(columns: 1, rows: 1)
        )
        XCTAssertEqual(cell?.column, -2)
    }

    func testRowNeverGoesNegative() {
        let mapper = self.mapper()
        let cell = mapper.cell(
            atScreen: CGPoint(x: visible.midX, y: mapper.gridTopEdgeY),
            span: GridSpan(columns: 1, rows: 1)
        )
        XCTAssertEqual(cell?.row, 0)
    }

    func testZeroStepYieldsNil() {
        // 指标退化（单元格 + 间距为 0）时不做除法。
        let degenerate = metrics(cellWidth: 0, cellHeight: 0, spacing: 0)
        let mapper = self.mapper(metrics: degenerate)
        XCTAssertNil(
            mapper.cell(
                atScreen: CGPoint(x: visible.midX, y: visible.minY + 1),
                span: GridSpan(columns: 1, rows: 1)
            )
        )
    }

    // MARK: - 指标边界

    func testZeroSpacing() {
        let geometry = DrawerGridGeometry(metrics: metrics(spacing: 0), leftColumn: 0, capacity: 4)
        let frame = geometry.frame(GridCell(column: 2, row: 1, columnSpan: 1, rowSpan: 1))
        XCTAssertEqual(frame.origin.x, 300, accuracy: 1e-9)
        XCTAssertEqual(frame.origin.y, 120, accuracy: 1e-9)
        XCTAssertEqual(geometry.cell(at: frame.origin).column, 2)
    }

    func testFractionalStepDoesNotDriftACell() {
        // 步长非整数时 n × step / step 可能因浮点误差落到 n−1；
        // `cell(at:)` 的 1e-6 容差必须吸收它。
        let geometry = DrawerGridGeometry(
            metrics: metrics(cellWidth: 150.33, cellHeight: 120.67, spacing: 11.77),
            leftColumn: 0,
            capacity: 8
        )
        for column in 0...7 {
            for row in 0...7 {
                let cell = GridCell(column: column, row: row, columnSpan: 1, rowSpan: 1)
                XCTAssertEqual(
                    geometry.cell(at: geometry.frame(cell).origin),
                    cell,
                    "column=\(column) row=\(row)"
                )
            }
        }
    }

    func testNotchGridMetricsForwardsDerivedFormulas() {
        // facade 必须转发 `GridMetrics` 的公式，否则又会出现第二份定义。
        let current = GridMetrics.current
        for columns in 0...5 {
            XCTAssertEqual(
                NotchGridMetrics.contentWidth(columns: columns),
                current.width(columns: columns),
                accuracy: 1e-9
            )
        }
        for rows in 0...5 {
            XCTAssertEqual(
                NotchGridMetrics.contentHeight(rows: rows),
                current.height(rows: rows),
                accuracy: 1e-9
            )
        }
    }

    func testMetricsChangesPropagate() {
        // `GridMetrics.current` 每次读 store：改指标后新算的值必须跟着变。
        // 这是进程级单例，必须 defer 还原。
        let store = GridMetricsStore.shared
        let saved = store.value(for: .cellWidth)
        defer { store.set(.cellWidth, to: saved) }

        store.set(.cellWidth, to: 200)
        XCTAssertEqual(GridMetrics.current.cellWidth, 200, accuracy: 1e-9)
        XCTAssertEqual(GridMetrics.current.stepWidth, 200 + GridMetrics.current.spacing, accuracy: 1e-9)
    }
}
