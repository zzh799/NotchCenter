import AppKit
import XCTest
@testable import NotchCenterKit

@MainActor
final class BlockPopoverTests: XCTestCase {
    // MARK: BlockPopoverPanel（浮窗面板的 key 资格与取消指令）

    /// 回归锁：无边框 NSPanel 的 canBecomeKey 默认为 false，窗口成不了 key
    /// window，浮窗内的 TextField/TextEditor 就永远聚焦不了（用户报告的
    /// "新建任务输入框点不进去"）。
    func testPopoverPanelCanBecomeKey() {
        let panel = BlockPopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testCancelOperationInvokesEscapeHandler() {
        let panel = BlockPopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var escaped = false
        panel.onEscape = { escaped = true }
        panel.cancelOperation(nil)
        XCTAssertTrue(escaped)
    }

    // MARK: BlockPopoverGeometry.windowOrigin（同心叠加 + 屏幕可见区钳制）

    func testCentersWindowOnBlockWhenNoScreenFrame() {
        let block = CGRect(x: 1000, y: 500, width: 120, height: 60)
        let window = CGSize(width: 268, height: 238)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: nil
        )
        XCTAssertEqual(origin.x, block.midX - window.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, block.midY - window.height / 2, accuracy: 0.001)
    }

    func testKeepsConcentricPositionWhileInsideVisibleFrame() {
        let block = CGRect(x: 700, y: 400, width: 120, height: 60)
        let window = CGSize(width: 268, height: 238)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 982)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: visible
        )
        XCTAssertEqual(origin.x, block.midX - window.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, block.midY - window.height / 2, accuracy: 0.001)
    }

    func testClampsTopEdgeForBlocksNearScreenTop() {
        // 抽屉块贴近屏幕顶部（屏幕坐标系 y 大）：窗口上缘越出可见区
        // → 整体钳回 maxY - 窗高 - edgeInset。
        let block = CGRect(x: 950, y: 900, width: 100, height: 40)
        let window = CGSize(width: 300, height: 300)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 982)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: visible
        )
        XCTAssertEqual(origin.x, block.midX - window.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, visible.maxY - window.height - 8, accuracy: 0.001)
    }

    func testClampsRightAndTopEdgesIndependently() {
        let block = CGRect(x: 1480, y: 950, width: 100, height: 40)
        let window = CGSize(width: 300, height: 300)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 982)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: visible
        )
        XCTAssertEqual(origin.x, visible.maxX - window.width - 8, accuracy: 0.001)
        XCTAssertEqual(origin.y, visible.maxY - window.height - 8, accuracy: 0.001)
    }

    func testClampsLeftAndBottomEdgesIndependently() {
        // 屏幕坐标系 y 小的一侧 = 屏幕底部；块越出左缘时钳回 minX 侧。
        let block = CGRect(x: -50, y: 30, width: 80, height: 20)
        let window = CGSize(width: 300, height: 300)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 982)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: visible
        )
        XCTAssertEqual(origin.x, visible.minX + 8, accuracy: 0.001)
        XCTAssertEqual(origin.y, visible.minY + 8, accuracy: 0.001)
    }

    // MARK: .below（贴块下方：紧凑区清空确认浮窗的摆放）

    func testBelowPlacesWindowTopAtBlockBottom() {
        // 窗口顶缘与块底缘相接（透明留白即视觉间距），水平仍对齐块中心。
        let block = CGRect(x: 700, y: 940, width: 28, height: 28)
        let window = CGSize(width: 268, height: 232)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: nil,
            placement: .below
        )
        XCTAssertEqual(origin.x, block.midX - window.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, block.minY - window.height, accuracy: 0.001)
    }

    func testBelowKeepsPositionWhenFullyInsideVisibleFrame() {
        let block = CGRect(x: 700, y: 500, width: 28, height: 28)
        let window = CGSize(width: 268, height: 232)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 982)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: visible,
            placement: .below
        )
        XCTAssertEqual(origin.x, block.midX - window.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, block.minY - window.height, accuracy: 0.001)
    }

    func testBelowClampsToVisibleFrameTopForNotchStripBlocks() {
        // 紧凑图标在屏幕最顶端（块底缘高于可见区 maxY——刘海带占据菜单栏
        // 行，可见区从其下方开始）：贴下方会越出可见区顶缘 → 整体钳回
        // maxY - 窗高 - edgeInset。
        let block = CGRect(x: 700, y: 1020, width: 28, height: 28)
        let window = CGSize(width: 268, height: 232)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 982)
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: block,
            windowSize: window,
            screenVisibleFrame: visible,
            placement: .below
        )
        XCTAssertEqual(origin.x, block.midX - window.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, visible.maxY - window.height - 8, accuracy: 0.001)
    }
}
