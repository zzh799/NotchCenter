import SwiftUI
import XCTest
@testable import NotchCenter

/// 方案 E 固定高度抽屉窗口的命中测试回归：窗口比内容高的部分是透明区，
/// 必须完全穿透（点击落到下层应用/系统菜单栏），只有可见矩形（顶缘起、
/// 当前内容高度以内）可交互——否则满高窗口会挡住整个下半屏。
@MainActor
final class DrawerHitTestingTests: XCTestCase {
    private func makeHost(visibleHeight: CGFloat) -> DrawerHostingView<Color> {
        let host = DrawerHostingView(rootView: Color.red)
        host.frame = NSRect(x: 0, y: 0, width: 668, height: 900)
        host.visibleHeightProvider = { visibleHeight }
        return host
    }

    func testPointsBelowVisibleHeightPassThrough() {
        let host = makeHost(visibleHeight: 697)
        // hitTest point 为窗口坐标（y 自底向上）：可见面板贴顶，底部
        // 透明区（y < 900-697=203）一律穿透。
        for y in [0, 100, 202] {
            XCTAssertNil(host.hitTest(NSPoint(x: 300, y: CGFloat(y))), "y=\(y) 应穿透")
        }
    }

    func testPointsWithinVisibleHeightAreInteractive() {
        let host = makeHost(visibleHeight: 697)
        // 可见矩形内（含窗口最顶端）正常命中（返回自身或子视图）。
        for y in [204, 500, 899] {
            XCTAssertNotNil(host.hitTest(NSPoint(x: 300, y: CGFloat(y))), "y=\(y) 应命中")
        }
    }

    func testPointsOutsideBoundsPassThrough() {
        let host = makeHost(visibleHeight: 697)
        XCTAssertNil(host.hitTest(NSPoint(x: -5, y: 100)))
        XCTAssertNil(host.hitTest(NSPoint(x: 700, y: 100)))
    }
}
