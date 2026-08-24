import AppKit
import SwiftUI

// MARK: - 长按浮窗基础组件（决策 6 的框架级统一实现）
//
// 生命周期：进程内单例，所有插件共享、任一时刻至多一个浮窗在屏；
// 再次 present 先收旧窗，点击浮窗以外区域自动关闭。
// 基本表现：近黑半透明卡片 + 白色发丝描边（DESIGN.md §2.1 / §2.3），
// 叠在原块正上方（同心），层级由原生窗口阴影压在被覆盖块上表达；
// 打开时卡片从小到大 spring 弹出。
//
// 插件侧只需提供内容视图与卡片尺寸，见各官方插件 Popover.swift 的薄入口。

@MainActor
public final class BlockPopover {
    /// 进程内唯一实例：天然保证全局互斥（打开一个浮窗即收起另一个）。
    public static let shared = BlockPopover()

    /// 卡片四周的透明留白：给 spring 回弹放大与窗口阴影留渲染空间；
    /// 留白区命中测试穿透（`PopoverHostingView.hitTest`），行为等同点在浮窗外。
    private static let margin: CGFloat = 24

    private var panel: NSPanel?
    /// 点击外部关闭：本地鼠标监听。
    private var eventMonitor: Any?

    private init() {}

    // MARK: 公共 API

    /// 在块正上方叠加浮窗。`frameInWindow` 为块在宿主窗口坐标系中的 frame
    /// （SwiftUI .global 空间），内部经宿主窗口 convertToScreen 转屏幕坐标。
    /// - Parameters:
    ///   - cardSize: 卡片尺寸；内容由 `content` 自行排布，外观（背景/描边/深色环境）
    ///     与弹出动画由本组件统一施加。
    public func present(
        anchoredTo frameInWindow: CGRect,
        cardSize: CGSize,
        @ViewBuilder content: () -> some View
    ) {
        dismiss()

        // 块视图挂在某个 NotchPanel 的 hosting 树里：取包含当前鼠标位置的
        // 可见窗口作为宿主（长按发生时光标就在块上）。
        let mouse = NSEvent.mouseLocation
        guard let hostWindow = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(mouse) }) else {
            return
        }
        // SwiftUI .global 是左上原点、y 向下；convertToScreen 要 AppKit
        // 窗口坐标（左下原点、y 向上）。先做 y 翻转再转换，否则浮窗会被
        // 镜像到屏幕底部。
        let flipped = CGRect(
            x: frameInWindow.minX,
            y: hostWindow.frame.height - frameInWindow.maxY,
            width: frameInWindow.width,
            height: frameInWindow.height
        )
        let blockFrame = hostWindow.convertToScreen(flipped)

        let windowSize = CGSize(
            width: cardSize.width + Self.margin * 2,
            height: cardSize.height + Self.margin * 2
        )
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: blockFrame,
            windowSize: windowSize,
            screenVisibleFrame: hostWindow.screen?.visibleFrame
        )

        let hosting = PopoverHostingView(
            // AnyView 装箱一次（每次弹出仅此一处），换取卡片容器免泛型。
            rootView: BlockPopoverCard(cardSize: cardSize, margin: Self.margin, content: AnyView(content()))
        )
        // 窗口比卡片大一圈 margin，命中测试只放行卡片矩形（左下原点坐标）。
        hosting.interactiveRect = CGRect(
            x: Self.margin, y: Self.margin,
            width: cardSize.width, height: cardSize.height
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar + 2
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.orderFrontRegardless()
        self.panel = panel

        // 点击浮窗以外区域关闭（透明留白区的点击会落到下层窗口，同样触发关闭）。
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel {
                self.dismiss()
            }
            return event
        }
    }

    public func dismiss() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - 定位几何（纯函数，BlockPopoverTests 覆盖）

public enum BlockPopoverGeometry {
    /// 浮窗**窗口**原点：卡片与块同心叠加（直接盖住原组件）；
    /// 窗口含四周留白，越出屏幕可见区域时整体钳回可见范围（`edgeInset` 边距）。
    /// 坐标为屏幕坐标系（y 自底向上）。纯函数便于单元测试。
    public static func windowOrigin(
        blockFrame: CGRect,
        windowSize: CGSize,
        screenVisibleFrame: CGRect?,
        edgeInset: CGFloat = 8
    ) -> CGPoint {
        var origin = CGPoint(
            x: blockFrame.midX - windowSize.width / 2,
            y: blockFrame.midY - windowSize.height / 2
        )
        guard let visible = screenVisibleFrame else { return origin }
        origin.x = min(max(origin.x, visible.minX + edgeInset), visible.maxX - windowSize.width - edgeInset)
        origin.y = min(max(origin.y, visible.minY + edgeInset), visible.maxY - windowSize.height - edgeInset)
        return origin
    }
}

// MARK: - 卡片外观与弹出动画

/// 统一外观容器：插件内容 + 近黑半透明背景 + 发丝描边 + 深色环境，
/// 打开时从小到大 spring 弹出（响应/阻尼对齐 DESIGN.md §3 物理感动效）。
private struct BlockPopoverCard: View {
    let cardSize: CGSize
    let margin: CGFloat
    let content: AnyView

    /// false → 缩小且全透明（首帧上屏态）；置 true 触发放大弹出。
    @State private var popped = false

    var body: some View {
        content
            .frame(width: cardSize.width, height: cardSize.height)
            .background(
                Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .scaleEffect(popped ? 1 : 0.72)
            .opacity(popped ? 1 : 0)
            // 外层撑满窗口（卡片 + margin），卡片居中于留白正中。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                // 下一帧起跳：确保缩小态先真正上屏，弹出动画可见。
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        popped = true
                    }
                }
            }
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - 命中穿透宿主

/// 浮窗宿主视图：卡片外的透明留白区命中返回 nil（点击穿透到下层并触发
/// “点击外部关闭”），只有卡片矩形可交互。
@MainActor
private final class PopoverHostingView<Content: View>: NSHostingView<Content> {
    /// 可交互卡片矩形（bounds 坐标，左下原点）。
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}
