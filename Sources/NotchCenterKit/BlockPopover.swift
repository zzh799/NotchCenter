import AppKit
import SwiftUI

// MARK: - 长按浮窗基础组件（决策 6 的框架级统一实现）
//
// 生命周期：进程内单例，所有插件共享、任一时刻至多一个浮窗在屏；
// 再次 present 先收旧窗，点击浮窗以外区域或宿主抽屉收起时自动关闭。
// 基本表现：近黑半透明卡片 + 白色发丝描边（DESIGN.md §2.1 / §2.3），
// 默认叠在原块正上方（同心），层级由原生窗口阴影压在被覆盖块上表达；
// 也可改为紧贴块下方弹出（`placement: .below`，紧凑区小图标用）。
// 打开时卡片从小到大 spring 弹出。
//
// 插件侧只需提供内容视图与卡片尺寸，见各官方插件 Popover.swift 的薄入口。

// MARK: - 浮窗面板

/// 浮窗窗口。
///
/// 无边框 `NSPanel` 的 `canBecomeKey` 默认为 `false`（`.nonactivatingPanel` 只
/// 决定"成为 key 时不激活 App"，不赋予 key 资格），窗口永远成不了 key window，
/// 内部 `TextField` / `TextEditor` 的字段编辑器也就无法成为 first responder -
/// 表现即"输入框点不进去"。
///
/// 重写为 `true` 只是打开**资格**：`present` 仍只 `orderFrontRegardless()`，
/// 由用户点进浮窗时 AppKit 才把它设为 key，纯按钮类浮窗"呈现不抢焦点"的既有
/// 语义不变。`canBecomeMain` 保持 `false`（浮窗不该成为主窗口）。
///
/// 取消指令（裸 Esc，以及 Cmd+. 这类同样映射到 `cancelOperation` 的组合）走
/// AppKit 标准取消链关闭浮窗，不在 `sendEvent` 里拦截：输入法处于 marked text
/// 时 Esc 由输入上下文消费、本方法不会被调用，天然 IME 正确，不必像
/// `NotchPanel.sendEvent` 那样手写 marked text 与修饰键判定。
/// 规则背景见 docs/agents/面板与抽屉.md。
internal final class BlockPopoverPanel: NSPanel {
    /// 浮窗收到取消指令（裸 Esc / Cmd+.）时调用。
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        guard let onEscape else { return super.cancelOperation(sender) }
        onEscape()
    }
}

/// 浮窗与锚定块的相对摆放。
public enum BlockPopoverPlacement {
    /// 同心叠在块正上方（默认）：服务卡类浮窗的既有表现，直接盖住原块。
    case overlay
    /// 紧贴块下缘弹出：窗口顶缘与块底缘相接（透明留白即视觉间距），
    /// 水平居中对齐块；紧凑区图标在屏幕最顶端，同心叠加会被钳回后
    /// 悬在半空且盖住整条刘海带，贴下方更符合「从按钮垂下来」的直觉。
    case below
}

// MARK: - 抽屉收起联动（浮窗锚定的块随抽屉消失，必须跟着收）

extension Notification.Name {
    /// 宿主在抽屉开始收起时投递（`NotchPanelController.collapse`）。
    /// `BlockPopover` 订阅它自动关闭：否则鼠标移开后抽屉缩回刘海，
    /// 浮窗仍以独立窗口残留在已消失的块上方。
    public static let notchCenterDrawerDidCollapse = Notification.Name("NotchCenter.drawerDidCollapse")
}

@MainActor
public final class BlockPopover {
    /// 进程内唯一实例：天然保证全局互斥（打开一个浮窗即收起另一个）。
    public static let shared = BlockPopover()

    /// 卡片四周的透明留白：给 spring 回弹放大与窗口阴影留渲染空间；
    /// 留白区命中测试穿透（`PopoverHostingView.hitTest`），行为等同点在浮窗外。
    private static let margin: CGFloat = 24

    /// 卡片四周留白的**合计**（`margin * 2`），即窗口比卡片大出的量。
    ///
    /// 插件用它把浮窗卡片尺寸夹在自己的块矩形内：
    /// `cardSize = min(理想尺寸, 块渲染尺寸 - BlockPopover.cardInset)`。
    /// 原因是宿主的鼠标「停留区」判定只看抽屉可见矩形（
    /// `NotchPanelInteraction.isPointInExpandedStayRegion`），**浮窗窗口不参与**；
    /// 卡片一旦伸出块矩形，伸出部分收不到鼠标：光标离开停留区即触发收起，
    /// 收起会投递 `.notchCenterDrawerDidCollapse` 让浮窗自动关闭。
    ///
    /// 公开此值是为了让插件不必镜像私有的 `margin`（同一事实两处写必然腐烂）。
    /// 决策背景见 Agent Note 2026-09-19-command-scheduler-plugin。
    public static let cardInset: CGFloat = margin * 2

    private var panel: BlockPopoverPanel?
    /// 点击外部关闭：本地鼠标监听。
    private var eventMonitor: Any?
    /// 抽屉收起 → 浮窗随之消失：宿主通知的观察令牌（需持有防注销）。
    private var drawerCollapseObserver: NSObjectProtocol?
    /// 弹出前谁是 key：浮窗被点成 key 后会抢走它，关闭时按此归还。
    ///
    /// 必须是"打开前的 key 窗口"而不是宿主块窗口 - 浮窗也可能开在设置窗口
    /// 之上，归还目标得是原来那个。为空（打开时 App 未激活）则不归还。
    private weak var previousKeyWindow: NSWindow?

    private init() {
        // queue 指定 .main：宿主在主线程投递，回调可安全假设主执行者。
        drawerCollapseObserver = NotificationCenter.default.addObserver(
            forName: .notchCenterDrawerDidCollapse, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    // MARK: 公共 API

    /// 在块正上方叠加浮窗。`frameInWindow` 为块在宿主窗口坐标系中的 frame
    /// （SwiftUI .global 空间），内部经宿主窗口 convertToScreen 转屏幕坐标。
    ///
    /// 默认浮现时不主动成为 key（不抢焦点）；面板具备 key 资格，内容里的输入控件
    /// 由用户点进浮窗时正常获得焦点（见 `BlockPopoverPanel`）。
    /// - Parameters:
    ///   - cardSize: 卡片尺寸；内容由 `content` 自行排布，外观（背景/描边/深色环境）
    ///     与弹出动画由本组件统一施加。
    ///   - placement: 与锚定块的相对摆放（同心覆盖 / 贴块下方），默认同心。
    ///   - focusContent: 浮现即让面板成为 key，好让内容马上拿到键盘焦点
    ///     （表单类浮窗配合 `@FocusState` 用，见 `TaskFormView`）。**只在"打开就是为了
    ///     输入"时传 true**：面板是 `nonactivatingPanel`，应用未激活时它会直接从
    ///     当前前台 App 抢走键盘输入（紧凑区浮窗正处于这种状态）。
    public func present(
        anchoredTo frameInWindow: CGRect,
        cardSize: CGSize,
        placement: BlockPopoverPlacement = .overlay,
        focusContent: Bool = false,
        @ViewBuilder content: () -> some View
    ) {
        dismiss()

        // 块视图挂在某个 NotchPanel 的 hosting 树里：长按/点击发生时光标就在
        // 块上。但同一鼠标点可能同时落在多个可见窗口内（展开态下抽屉岛顶的
        // 紧凑带在 drawerPanel 里，而 hotPanel 热区条带仍叠在同一屏幕区域）；
        // NSApp.windows 的顺序不是 z 序（热区窗口先创建），取错窗口会把
        // .global 帧按错误的高度做 y 翻转换算，浮窗整体错位。因此按
        // CGWindowList 的屏幕 z 序取包含鼠标的最前层可见窗口。
        let mouse = NSEvent.mouseLocation
        guard let hostWindow = BlockPopover.frontmostVisibleWindow(containing: mouse) else {
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
            width: cardSize.width + Self.cardInset,
            height: cardSize.height + Self.cardInset
        )
        let origin = BlockPopoverGeometry.windowOrigin(
            blockFrame: blockFrame,
            windowSize: windowSize,
            screenVisibleFrame: hostWindow.screen?.visibleFrame,
            placement: placement
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

        let panel = BlockPopoverPanel(
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
        panel.onEscape = { [weak self] in self?.dismiss() }

        previousKeyWindow = NSApp.keyWindow
        panel.orderFrontRegardless()
        // 成为 key 需在窗口上线之后；内容里的 @FocusState 随后才生效（实测：
        // onAppear 晚于本调用，下一帧字段编辑器即成为 first responder）。
        if focusContent {
            panel.makeKey()
        }
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
        // 只有"浮窗确实抢走了 key"才归还：无边框面板 orderOut 后 AppKit 不保证
        // 自动补 key，抽屉会退化成无 key 窗口（Esc 收起与 Cmd+C/V/X/A/Z 全失效）。
        // 用 makeKey（非 makeKeyAndOrderFront）且带 isVisible 守卫，绝不复活
        // 已收起的宿主窗口。
        if panel?.isKeyWindow == true, let target = previousKeyWindow, target.isVisible {
            target.makeKey()
        }
        previousKeyWindow = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: 宿主窗口解析

    /// 包含 `point` 的最前层可见窗口（本进程）。CGWindowList 按屏幕 z 序
    /// 返回 on-screen 窗口（下标 0 最前），候选里取 z 序最小者；拿不到
    /// CG 列表时退化为 NSApp.windows 的自然顺序。
    private static func frontmostVisibleWindow(containing point: NSPoint) -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.frame.contains(point) }
        guard candidates.count > 1 else { return candidates.first }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return candidates.first
        }
        // windowNumber → z 序下标（0 = 最前）。
        var zIndexByID: [Int: Int] = [:]
        for (index, info) in list.enumerated() {
            if let number = info[kCGWindowNumber as String] as? Int {
                zIndexByID[number] = index
            }
        }
        return candidates.min { (zIndexByID[$0.windowNumber] ?? .max) < (zIndexByID[$1.windowNumber] ?? .max) }
    }
}

// MARK: - 定位几何（纯函数，BlockPopoverTests 覆盖）

public enum BlockPopoverGeometry {
    /// 浮窗**窗口**原点：`.overlay` 时卡片与块同心叠加（直接盖住原组件）；
    /// `.below` 时窗口顶缘与块底缘相接、水平居中对齐块。窗口含四周留白，
    /// 越出屏幕可见区域时整体钳回可见范围（`edgeInset` 边距）。
    /// 坐标为屏幕坐标系（y 自底向上）。纯函数便于单元测试。
    public static func windowOrigin(
        blockFrame: CGRect,
        windowSize: CGSize,
        screenVisibleFrame: CGRect?,
        edgeInset: CGFloat = 8,
        placement: BlockPopoverPlacement = .overlay
    ) -> CGPoint {
        var origin: CGPoint
        switch placement {
        case .overlay:
            origin = CGPoint(
                x: blockFrame.midX - windowSize.width / 2,
                y: blockFrame.midY - windowSize.height / 2
            )
        case .below:
            // 窗口顶缘贴块底缘：透明留白（24pt）即卡片与按钮间的视觉间距。
            origin = CGPoint(
                x: blockFrame.midX - windowSize.width / 2,
                y: blockFrame.minY - windowSize.height
            )
        }
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

    /// 首击也投递给内容。应用未激活时（紧凑区浮窗）默认的首击只用于激活窗口，
    /// 会把"点击输入框"吞掉，表现为要点两下。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}
