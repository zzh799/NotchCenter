import AppKit
import XCTest
@testable import NotchCenter

@MainActor
final class DrawerScrollProbeTests: XCTestCase {
    // MARK: 装置

    /// 离屏无边框窗口：contentView 即探针的枚举根，窗口基础坐标与
    /// contentView 坐标重合（原点左下）。
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        return window
    }

    /// 横向 ScrollView：视口 `viewportWidth`、文档宽 `documentWidth`（高 50）。
    /// `tile()` 让 NSScrollView 摆好 contentView（无窗口时 documentVisibleRect
    /// 才有正确宽度；真机 SwiftUI 内部滚动机构本来就 tile 过）。
    private func makeScrollView(
        frame: NSRect,
        documentWidth: CGFloat,
        documentHeight: CGFloat = 50
    ) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight))
        scrollView.documentView = document
        scrollView.tile()
        return scrollView
    }

    /// 把视图挂进窗口（探针经 `in window:` 走窗口基础坐标）。
    private func install(_ view: NSView, in window: NSWindow) {
        window.contentView?.addSubview(view)
    }

    private func windowPoint(on view: NSView, _ local: NSPoint) -> NSPoint {
        view.convert(local, to: nil)
    }

    // MARK: 命中与溢出

    func testHorizontalOverflowUnderCursorYields() {
        let window = makeWindow()
        let scrollView = makeScrollView(
            frame: NSRect(x: 20, y: 20, width: 100, height: 50),
            documentWidth: 400
        )
        install(scrollView, in: window)

        XCTAssertTrue(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: scrollView, NSPoint(x: 50, y: 25))))
    }

    func testScrollViewWithoutOverflowDoesNotYield() {
        let window = makeWindow()
        let scrollView = makeScrollView(
            frame: NSRect(x: 20, y: 20, width: 100, height: 50),
            documentWidth: 80
        )
        install(scrollView, in: window)

        XCTAssertFalse(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: scrollView, NSPoint(x: 50, y: 25))))
    }

    func testCursorOutsideScrollViewDoesNotYield() {
        let window = makeWindow()
        let scrollView = makeScrollView(
            frame: NSRect(x: 20, y: 20, width: 100, height: 50),
            documentWidth: 400
        )
        install(scrollView, in: window)

        XCTAssertFalse(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: window.contentView!, NSPoint(x: 280, y: 180))))
    }

    func testVerticalOnlyOverflowDoesNotYield() {
        let window = makeWindow()
        // 文档又高又窄：纵向可滚、横向不溢出（对应抽屉外层纵向 ScrollView）。
        let scrollView = makeScrollView(
            frame: NSRect(x: 20, y: 20, width: 100, height: 50),
            documentWidth: 80,
            documentHeight: 400
        )
        install(scrollView, in: window)

        XCTAssertFalse(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: scrollView, NSPoint(x: 50, y: 25))))
    }

    // MARK: ε 边界（防 1px 取整误报）

    func testOverflowEpsilonBoundary() {
        let window = makeWindow()
        // 溢出 0.5pt（< ε=1）：不算可滚，未满货架不被误判。
        let subEpsilon = makeScrollView(
            frame: NSRect(x: 20, y: 20, width: 100, height: 50),
            documentWidth: 100.5
        )
        install(subEpsilon, in: window)
        XCTAssertFalse(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: subEpsilon, NSPoint(x: 50, y: 25))))

        // 溢出 2pt（> ε=1）：可滚。
        let overEpsilon = makeScrollView(
            frame: NSRect(x: 160, y: 20, width: 100, height: 50),
            documentWidth: 102
        )
        install(overEpsilon, in: window)
        XCTAssertTrue(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: overEpsilon, NSPoint(x: 50, y: 25))))
    }

    // MARK: NSClipView 兜底路径（无外层 ScrollView 的内部结构）

    func testBareClipViewWithWideDocumentYields() {
        let window = makeWindow()
        let clipView = NSClipView(frame: NSRect(x: 20, y: 20, width: 100, height: 50))
        clipView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
        install(clipView, in: window)

        XCTAssertTrue(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: clipView, NSPoint(x: 50, y: 25))))
    }

    func testNilDocumentViewDoesNotYield() {
        let window = makeWindow()
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 100, height: 50))
        install(scrollView, in: window)

        XCTAssertFalse(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: scrollView, NSPoint(x: 50, y: 25))))
    }

    // MARK: 深层枚举

    func testNestedScrollViewInsideNonOverflowOuterYields() {
        let window = makeWindow()
        // 外层纵向不溢出，文档里嵌一颗横向溢出的内层 ScrollView——
        // 验证 DFS 走到任意深度、嵌套滚动容器独立判定。
        let outer = makeScrollView(
            frame: NSRect(x: 20, y: 20, width: 100, height: 150),
            documentWidth: 80,
            documentHeight: 300
        )
        let inner = makeScrollView(
            frame: NSRect(x: 0, y: 200, width: 80, height: 40),
            documentWidth: 300,
            documentHeight: 40
        )
        outer.documentView?.addSubview(inner)
        install(outer, in: window)

        XCTAssertTrue(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: inner, NSPoint(x: 40, y: 20))))
    }

    // MARK: 隐藏视图跳过

    func testHiddenScrollViewIsIgnored() {
        let window = makeWindow()
        let scrollView = makeScrollView(
            frame: NSRect(x: 20, y: 20, width: 100, height: 50),
            documentWidth: 400
        )
        scrollView.isHidden = true
        install(scrollView, in: window)

        XCTAssertFalse(DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window,
            cursorWindowPoint: windowPoint(on: scrollView, NSPoint(x: 50, y: 25))))
    }
}
