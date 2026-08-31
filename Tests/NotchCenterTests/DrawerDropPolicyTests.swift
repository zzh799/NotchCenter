import CoreGraphics
import XCTest
@testable import NotchCenter

/// 落点区域判定回归：从 `BlockDropTargeting.dropZone` 剥出来的纯几何。
///
/// 这里只测"点属于哪个区域"，不涉及 payload 种类与块落位——那部分仍由
/// `dropZone` 负责，需要真实的 `NotchPanelController`（无法在单测里构造）。
final class DrawerDropPolicyTests: XCTestCase {
    /// 可见面板（Cocoa）：x 100...900，y 300...900，顶缘 y = 900。
    /// 紧凑带 40、顶栏 36 → 网格内容顶缘 y = 824。
    private let visible = CGRect(x: 100, y: 300, width: 800, height: 600)

    private let policy = DrawerDropPolicy(
        visibleFrame: CGRect(x: 100, y: 300, width: 800, height: 600),
        compactHeight: 40,
        gridTopEdgeY: 824
    )

    func testOutsidePanel() {
        XCTAssertEqual(policy.region(of: CGPoint(x: 50, y: 600)), .outside)
        XCTAssertEqual(policy.region(of: CGPoint(x: 500, y: 100)), .outside)
    }

    func testCompactBandSpansFullPanelWidth() {
        // 回归：紧凑带命中区必须是**整条可见面板宽度**，不是绕刘海的窄带
        // （`pair.hotFrame`）。用窄矩形判定会让拖到岛顶两侧的落点被判成
        // 网格区，快捷按钮因此"放不进快速区"。
        let bandY = 880.0
        XCTAssertEqual(policy.region(of: CGPoint(x: visible.minX, y: bandY)), .compact)
        XCTAssertEqual(policy.region(of: CGPoint(x: visible.midX, y: bandY)), .compact)
        XCTAssertEqual(policy.region(of: CGPoint(x: visible.maxX - 1, y: bandY)), .compact)
    }

    func testTopBarRejectsDrops() {
        // 顶栏是齿轮 / 钉住等按钮所在横条，不接受落点。
        XCTAssertEqual(policy.region(of: CGPoint(x: 500, y: 842)), .topBar)
        XCTAssertEqual(policy.region(of: CGPoint(x: 500, y: 825)), .topBar)
    }

    func testGridStartsAtTopEdge() {
        // 网格顶缘自身可落点（含边界）。
        XCTAssertEqual(policy.region(of: CGPoint(x: 500, y: 824)), .grid)
        XCTAssertEqual(policy.region(of: CGPoint(x: 500, y: 400)), .grid)
    }

    func testCompactAndGridAreAdjacent() {
        // 紧凑带与网格上下相邻、互不重叠：紧凑带下缘即顶栏上缘。
        XCTAssertEqual(policy.region(of: CGPoint(x: 500, y: 860)), .compact)
        XCTAssertEqual(policy.region(of: CGPoint(x: 500, y: 859)), .topBar)
    }

    func testDerivedFromMapperMatchesExplicitInit() {
        let mapper = DrawerScreenMapper(
            visibleFrame: visible,
            topInset: 40 + 36,
            geometry: DrawerGridGeometry(
                metrics: GridMetrics(
                    cellWidth: 150, cellHeight: 120, spacing: 12,
                    contentPadding: 16, topBarHeight: 36
                ),
                leftColumn: 0,
                capacity: 4,
                minimumRows: 1,
                minimumColumns: 1
            )
        )
        XCTAssertEqual(DrawerDropPolicy(mapper: mapper, compactHeight: 40), policy)
    }
}
