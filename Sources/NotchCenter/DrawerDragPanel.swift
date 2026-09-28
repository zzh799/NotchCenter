import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉内拖拽的「脱离容器」浮窗
//
// 拖动时被拖块渲染到独立 NSPanel，原位置留位（opacity 0）。
//
// 为什么必须脱离：面板宽度 = `ui.drawerWindowSize.width`，它在固定满宽窗口内
// **水平居中**；拖动时 `applyPreviewWindowSize` 用 spring 改这个宽度 → 面板绕
// 中线重新居中 → 左缘移动。而块坐标以面板左缘为基准
//（`DrawerGridGeometry.x(column:)`），左缘一动整页块屏幕位置全部平移：被拖块
// 一边被 `dragOffset` 拉向光标、一边被左缘推走 → 跳动 + 不跟手 + 其它块闪烁。
// 窗口缩放动画按用户要求保留，故只能让被拖块**离开那棵视图树**。
//
// 与 `BlockDragCoordinator` 跟手浮窗的区别：那是跨窗口拖拽（内容为新建 1:1
// 预览）；本类型服务抽屉内重排，内容是同一插件视图的**新实例**（数据同源）。
@MainActor
final class DrawerDragPanel {
    private let panel: NSPanel

    init(view: AnyView, size: CGSize) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 窗口特征对齐 `DragPreviewPanel`：透明、无窗口阴影（阴影画在内容上，
        // 避免收场时留下大黑影）、不接收鼠标、层级高于抽屉。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = HostWindowLevel.dragPreview
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
    }

    func show() {
        panel.orderFrontRegardless()
    }

    /// 摆到指定位置。参数是浮窗**左上角**（Cocoa 屏幕坐标，y 向上）。
    ///
    /// 必须自己做这个换算：`setFrameOrigin(_:)` 接受的是窗口 frame 的**左下角**，
    /// 直接喂左上角会让浮窗整体抬高一个窗口高度（表现为抓握点全错）。
    func move(toScreenTopLeft topLeft: CGPoint) {
        panel.setFrameOrigin(CGPoint(
            x: topLeft.x,
            y: topLeft.y - panel.frame.height
        ))
    }

    func close() {
        panel.orderOut(nil)
    }
}
