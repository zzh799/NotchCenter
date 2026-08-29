import SwiftUI
import XCTest
@testable import NotchCenter

/// 活动岛窗口命中测试回归：固定尺寸窗口中可见内容「顶缘起、水平居中」，
/// 透明区（窗口比内容高的下半部 + 比内容宽的左右两侧）必须完全穿透，
/// 否则窗口会挡住刘海下方的应用内容。
@MainActor
final class IslandHitTestingTests: XCTestCase {
    /// 窗口 460×320（ActivityIslandLayout 上限），可见内容 178×46 居中。
    private func makeHost(visible: CGSize) -> IslandHostingView<Color> {
        let host = IslandHostingView(rootView: Color.red)
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 320)
        host.visibleSizeProvider = { visible }
        return host
    }

    func testAreasOutsideVisibleRectPassThrough() {
        let host = makeHost(visible: CGSize(width: 178, height: 46))
        // 下半透明区（y < 320-46=274）穿透。
        XCTAssertNil(host.hitTest(NSPoint(x: 230, y: 100)))
        XCTAssertNil(host.hitTest(NSPoint(x: 230, y: 273)))
        // 顶带内、内容左右两侧（内容 178 宽居中 → x < 141 或 x > 319）穿透。
        XCTAssertNil(host.hitTest(NSPoint(x: 100, y: 300)))
        XCTAssertNil(host.hitTest(NSPoint(x: 360, y: 300)))
    }

    func testVisibleRectIsInteractive() {
        let host = makeHost(visible: CGSize(width: 178, height: 46))
        let interactivePoints: [NSPoint] = [
            // 上界为开区间（NSRect.contains），窗口最顶端取 319。
            NSPoint(x: 230, y: 319),
            NSPoint(x: 230, y: 275),
            NSPoint(x: 142, y: 310),
            NSPoint(x: 318, y: 275),
        ]
        for point in interactivePoints {
            XCTAssertNotNil(host.hitTest(point), "point=\(point) 应命中")
        }
    }

    func testZeroVisibleSizePassesThroughEverything() {
        // 抽屉展开让位 / 无活动岛 / 内容未布局：可见尺寸为零，整窗穿透。
        let host = makeHost(visible: .zero)
        XCTAssertNil(host.hitTest(NSPoint(x: 230, y: 300)))
        XCTAssertNil(host.hitTest(NSPoint(x: 230, y: 100)))
    }

    func testPointsOutsideBoundsPassThrough() {
        let host = makeHost(visible: CGSize(width: 178, height: 46))
        XCTAssertNil(host.hitTest(NSPoint(x: -5, y: 300)))
        XCTAssertNil(host.hitTest(NSPoint(x: 470, y: 300)))
    }
}
