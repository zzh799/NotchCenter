import AppKit
import SwiftUI

// MARK: - 窗口类型

@MainActor
final class NotchPanel: NSPanel {
    var onMouseEvent: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // 只拦截“裸”Escape：输入法用户需要 Esc 取消编辑器中的 marked text，
        // 带修饰键的 Esc 组合键也应交给系统处理。
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
                super.sendEvent(event)
            } else {
                onEscape?()
            }
            return
        }

        if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
            onMouseEvent?(event)
        }

        super.sendEvent(event)
    }
}

@MainActor
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// 固定高度（屏高上限）抽屉窗口的宿主视图：窗口比当前内容高的部分
/// 永远是透明区，命中测试只放行可见矩形（紧凑带 + 当前面板高度），
/// 其余穿透到下层应用与系统菜单栏。
/// 注意：hitTest 的 point 是父视图（窗口）坐标、y 自底向上（与视图是否
/// flipped 无关）——可见面板贴窗口顶缘，穿透判定为 y < 高度差，
/// 与 codex-island 的 `b.maxY - size.height` 同一算式。
@MainActor
class DrawerHostingView<Content: View>: FirstMouseHostingView<Content> {
    /// 可见面板高度，由控制器按当前内容状态提供。
    var visibleHeightProvider: (() -> CGFloat)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let visibleHeight = visibleHeightProvider?(),
           point.y < bounds.height - visibleHeight {
            return nil
        }
        return super.hitTest(point) ?? self
    }
}

@MainActor
class TransparentHitHostingView<Content: View>: FirstMouseHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        // SwiftUI may return nil when every rendered pixel is transparent.
        // Keep the panel's full compact frame interactive without drawing a background.
        return super.hitTest(point) ?? self
    }
}

// MARK: - 屏幕面板对

/// 每个物理屏幕一套（紧凑热区 + 抽屉）窗口对；内容状态由共享的
/// PanelUIState 驱动，几何按各自屏幕独立计算（文档 §6.3 多显示器：
/// 每个屏幕单独显示一个 NotchCenter）。
@MainActor
final class ScreenPanelPair {
    let screen: NSScreen
    let hotPanel: NotchPanel
    let drawerPanel: NotchPanel
    var hotHostingView: TransparentHitHostingView<CompactPanelView>?
    var drawerHostingView: NSHostingView<DrawerPanelView>?

    init(screen: NSScreen, configure: (NotchPanel) -> Void) {
        self.screen = screen
        hotPanel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        drawerPanel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configure(hotPanel)
        configure(drawerPanel)
    }

    /// 该屏幕的刘海/回退布局。
    var layout: NotchLayout { NotchGeometry.layout(for: screen) }
    var screenFrame: NSRect { screen.frame }
    /// 紧凑热区在该屏幕上的 frame。
    var hotFrame: NSRect { NotchGeometry.activationFrame(for: layout, in: screenFrame) }
}

extension NotchPanelController {
    static func configurePanel(_ panel: NotchPanel) {
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
    }
}
