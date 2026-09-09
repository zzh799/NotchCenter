import AppKit
import NotchCenterKit
import QuartzCore
import SwiftUI

// MARK: - 设置面板（文档 §6.1 / §4.8）

/// 设置面板窗口：带侧边栏的多页结构（通用 / 组件 / 布局 / 插件 / 调试）。
///
/// 与抽屉的关系：
/// - 面板**优先贴抽屉下方**——抽屉下方放得下（含间距、且底缘仍在
///   visibleFrame 内）就落在抽屉可见底缘之下，放不下才退回屏幕底部停靠
///   （`updateSettingsPlacement()` 裁定、`positionSettingsWindow()` 落位，
///   屏幕水平居中）。布局提交（增删块/改列数）会重裁一次，不逐帧跟随
///   抽屉 spring；
/// - 面板**置顶**（level 高于抽屉），跨 Space、不随其他应用隐藏；
/// - 面板可见期间抽屉**常驻展开**且**限高**（`isSettingsPresented` 时
///   `drawerWindowSize(for:)` 按摆位顶缘保证抽屉可见底缘不与面板重叠），
///   改设置即可在抽屉上看到实时效果，也可直接从「组件」页拖块到抽屉/快速区。
/// 当前选中的设置页（`@State` 无法从窗口外部驱动，探针/外部切换走这里）。
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var page: SettingsPage = .general
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// 弱引用：控制器强持有本窗口控制器，避免环。视图侧各自持有强引用。
    private weak var panelController: NotchPanelController?
    private let selection = SettingsSelection()

    init(panelController: NotchPanelController) {
        self.panelController = panelController
        // 窗口尺寸来自 SettingsStore（调试页可调、跨启动持久）。
        let store = panelController.settingsStore

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: store.settingsWindowWidth,
                height: store.settingsWindowHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("settings.window.title")
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // 不能开“背景可拖动”：从组件卡片的空白处按下拖动时，命中测试会落
        // 到窗口背景，NSWindow 随即进入窗口拖动循环并吞掉 mouseDragged——
        // 表现为“拖组件时整个设置面板跟着走”，拖拽会话同时被中断（松手时
        // 拿不到落点）。窗口拖动仍可经透明 titlebar 完成。
        panel.isMovableByWindowBackground = false
        // 置顶：高于抽屉（statusBar 级），不被其他应用窗口遮挡。
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        // 面板内的开关/输入框需要正常接收键盘，不能只在需要时才成为 key。
        panel.becomesKeyOnlyIfNeeded = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(NotchTokens.Surface.window)
        panel.animationBehavior = .none

        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: SettingsRootView(controller: panelController, selection: selection)
        )
        // 显式约束内容区：root view 的 `.frame(...)` 不足以阻止 hosting view
        // 因 HStack/Spacer 把 fitting size 撑大，contentSize 锁到与 root
        // frame 同源（SettingsStore）的值，窗口 frame = 内容 + titlebar 28。
        panel.setContentSize(
            NSSize(
                width: store.settingsWindowWidth,
                height: store.settingsWindowHeight
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 打开设置窗口。`page` 非 nil 时先把侧边栏切到指定页
    /// （编辑态直入组件页用）；nil 则沿用上次停留页。
    func showSettings(page: SettingsPage? = nil) {
        if let page { selection.page = page }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 开发期探针用：直接切页（抓图验证各页布局）。
    func select(_ page: SettingsPage) {
        selection.page = page
    }

    // MARK: NSWindowDelegate

    /// 关闭即结束「抽屉常驻」：控制器恢复常规收起逻辑。
    func windowWillClose(_ notification: Notification) {
        panelController?.settingsWindowDidClose()
    }
}

enum SettingsWindowMetrics {
    /// 默认窗口尺寸（真实尺寸持久化在 SettingsStore，调试页可调）。
    static let width: CGFloat = 780
    static let height: CGFloat = 425
    /// 调试页可调区间（滑杆/输入框/持久值读取共用同一钳制）。
    static let widthRange: ClosedRange<CGFloat> = 520...1200
    static let heightRange: ClosedRange<CGFloat> = 360...1000
    /// titlebar 高度（透明隐藏但占位）：窗口 frame 高 = 高度 + titleBarHeight。
    static let titleBarHeight: CGFloat = 28
    /// 默认尺寸下的窗口真实 frame 高度——抽屉限高按当前持久高度 + titleBar
    /// 现算（见 `NotchGeometry.dockedSettingsTopY`），此常量只作测试基准。
    static let windowFrameHeight: CGFloat = height + titleBarHeight
    /// 停靠屏幕底部时与 visibleFrame 底缘的间距（visibleFrame 已避开 Dock）。
    static let bottomInset: CGFloat = 12
    /// 设置页顶缘与抽屉可见底缘的间距：两种摆位共用——贴抽屉下方时是面板
    /// 与抽屉的间隙，屏幕底部停靠时是抽屉限高让出的余量。
    static let gapFromSettings: CGFloat = 8
}

// MARK: - 页面

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case components
    case layout
    case plugins
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("settings.tab.general")
        case .components: return L("settings.tab.components")
        case .layout: return L("settings.tab.layout")
        case .plugins: return L("settings.tab.plugins")
        case .debug: return L("settings.tab.debug")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .components: return "square.grid.2x2"
        case .layout: return "rectangle.3.group"
        case .plugins: return "puzzlepiece.extension"
        case .debug: return "ladybug"
        }
    }
}

// MARK: - 根视图

struct SettingsRootView: View {
    let controller: NotchPanelController
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var selection: SettingsSelection

    init(controller: NotchPanelController, selection: SettingsSelection) {
        self.controller = controller
        self.settingsStore = controller.settingsStore
        self.selection = selection
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 176)

            Divider()
                .overlay(NotchTokens.Hairline.divider)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NotchTokens.Surface.window)
        .environment(\.colorScheme, .dark)
        // 尺寸绑定 SettingsStore（调试页可调）：窗口 setContentSize 与此
        // 保持一致，两处不同源会出现内容与窗口边界错位。
        .frame(
            width: settingsStore.settingsWindowWidth,
            height: settingsStore.settingsWindowHeight
        )
        // 「组件」页需要抽屉处于编辑模式：拖进来的组件可立即继续拖动/缩放/
        // 删除，快捷按钮也能直接拖动换位；离开该页即退出。
        .onChange(of: selection.page) { _, page in
            controller.setComponentsPageActive(page == .components)
        }
    }

    // MARK: 一级侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NotchCenter")
                .font(NotchTokens.Text.system(12, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(SettingsPage.allCases) { page in
                sidebarItem(page)
            }

            Spacer(minLength: 0)

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "power")
                        .font(NotchTokens.Text.system(11, weight: .semibold))
                    Text(L("settings.quit"))
                        .font(NotchTokens.Text.system(12))
                }
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .help(L("settings.quit"))
        }
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.015))
    }

    private func sidebarItem(_ page: SettingsPage) -> some View {
        let isSelected = selection.page == page
        return Button {
            selection.page = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.systemImage)
                    .font(NotchTokens.Text.system(12, weight: .medium))
                    .frame(width: 16)
                Text(page.title)
                    .font(NotchTokens.Text.system(12.5, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? NotchTokens.Foreground.body : NotchTokens.Foreground.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                    .fill(isSelected ? NotchTokens.Surface.track : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch selection.page {
        case .general:
            GeneralSettingsPage(controller: controller, settingsStore: settingsStore)
        case .components:
            ComponentsSettingsPage(controller: controller)
        case .layout:
            LayoutSettingsPage(controller: controller, settingsStore: settingsStore)
        case .plugins:
            PluginManagerView(pluginManager: controller.pluginManager)
        case .debug:
            DebugSettingsPage(controller: controller, settingsStore: settingsStore)
        }
    }
}

// MARK: - 控制器入口

extension NotchPanelController {
    /// 打开设置面板：抽屉常驻展开（不自动收起）且限高让位于面板；面板
    /// 优先贴抽屉下方、放不下则停靠屏幕底部，并置顶。面板已可见时再触发
    /// 一次即关闭（抽屉顶栏齿轮 = 开关）。
    ///
    /// 编辑态打开 → 直入「组件」页且抽屉保持编辑态（组件页拖块落位依赖
    /// 编辑态）；非编辑态保持现状（沿用上次停留页）。显式传 `page` 可指定
    /// 目标页（调用点不传时默认 nil = 不改页）。
    func showSettings(page: SettingsPage? = nil) {
        let controller = settingsWindowController ?? {
            let controller = SettingsWindowController(panelController: self)
            settingsWindowController = controller
            return controller
        }()

        if isSettingsPresented {
            closeSettings()
            return
        }

        // 编辑态默认进组件页；非编辑态沿用上次页（nil = 不动 selection）。
        let targetPage: SettingsPage? = page ?? (isEditing ? .components : nil)

        isSettingsPresented = true
        cancelCollapse()
        // 编辑模式仅允许与「组件」页共存（组件页拖块落位依赖编辑态）；
        // 其余页维持旧互斥——两处都能改布局，同时开着会互相打架。
        if isEditing, targetPage != .components {
            stopEditMode()
        }
        // 摆位必须**先于**展开裁定：抽屉限高读摆位，展开尺寸里就要带上
        // 让位（弹簧直接收到让位后的高度，不先弹满再回缩）。
        updateSettingsPlacement()
        if !isExpanded {
            expand(animated: true, activate: false)
        } else {
            // 已展开：限高只在 isSettingsPresented 置位后经尺寸重算生效，
            // 抽屉弹簧收到让位后的高度。
            refreshAfterLayoutChange(animated: true)
        }
        // 展开把抽屉搬到了另一块屏（跨屏点击）：摆位按最终屏重裁并重摆。
        if updateSettingsPlacement() {
            refreshAfterLayoutChange(animated: true)
        }
        // 落位先于 showWindow：窗口不可见时走无动画分支，且首次打开不会把
        // 窗口初始 frame（原点在屏幕左下）误当"用户拖动后的位置"保留 X。
        positionSettingsWindow()
        controller.showSettings(page: targetPage)
        // 显式驱动组件页联动：onChange(of: selection.page) 只在视图挂载并
        // 求值后才触发，首次打开（rootView 未求值）或页值未变时不可靠；
        // setComponentsPageActive 自带幂等 guard，与 onChange 双触发也只
        // 生效一次。
        setComponentsPageActive(targetPage == .components)
    }

    /// 关闭设置面板（齿轮按钮 / 抽屉关闭按钮 / 窗口关闭）。
    func closeSettings() {
        isSettingsPresented = false
        // 面板关闭即离开组件页：先退出其联动的编辑模式，再按常规逻辑收起。
        setComponentsPageActive(false)
        settingsPlacement = nil
        settingsWindowController?.close()
        releaseSettingsDrawerHeightCap()
        // 常驻结束：未钉住时按当前鼠标位置决定是否收起抽屉。
        if !isPinned {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    /// 窗口关闭回调（delegate 与主动关闭都会走到；幂等）。
    func settingsWindowDidClose() {
        guard isSettingsPresented else { return }
        isSettingsPresented = false
        setComponentsPageActive(false)
        settingsPlacement = nil
        releaseSettingsDrawerHeightCap()
        if !isPinned {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    /// 设置关闭后解除抽屉限高：重算可见尺寸让抽屉弹回完整高度。幂等——
    /// closeSettings 主动关闭与 windowWillClose 委托回调会双路径到达。
    private func releaseSettingsDrawerHeightCap() {
        refreshAfterLayoutChange(animated: true)
    }

    /// 按当前摆位摆放设置面板：优先贴抽屉可见底缘之下（下方放得下），
    /// 否则停靠 visibleFrame 底缘（已避开 Dock）+ 间距。
    ///
    /// **只改 Y 轴位置**：窗口已可见且仍在锚定屏上时保留当前横向位置
    /// （用户可能手动拖动过面板，切页/布局提交的重摆不得横向归位）；
    /// 首次定位（窗口不可见）或跨屏（窗口不在锚定屏上，避免"新屏的 Y +
    /// 旧屏的 X"错位）时水平回屏幕中线，与抽屉同轴对齐。
    ///
    /// `animated` 只用于布局提交后的一次性平移（不逐帧跟随抽屉 spring）；
    /// 首次定位窗口尚未可见，走无动画分支。
    func positionSettingsWindow(animated: Bool = false, keepX: Bool = true) {
        guard let window = settingsWindowController?.window else { return }
        guard let pair = activePair ?? pairs.first else { return }
        let placement = currentSettingsPlacement(for: pair)
        let centeredX = round(pair.screenFrame.midX - window.frame.width / 2)
        let onAnchorScreen = window.frame.midX >= pair.screenFrame.minX
            && window.frame.midX <= pair.screenFrame.maxX
        let preserveX = keepX && window.isVisible && onAnchorScreen
        let origin = NSPoint(
            x: preserveX ? window.frame.minX : centeredX,
            y: round(placement.frameOriginY(bandHeight: window.frame.height))
        )
        guard animated, window.isVisible else {
            window.setFrameOrigin(origin)
            return
        }
        // 只平移不改尺寸：target-frame 取当前 frame 换原点。**必须经
        // `animator().setFrame(_:display:)`**——`setFrameOrigin` 不在 NSWindow
        // 的可动画方法之列，经 animator 代理调用会被静默吞掉（no-op），
        // 表现为切页/布局提交后摆位已重裁、窗口却纹丝不动（探针实锤）。
        var targetFrame = window.frame
        targetFrame.origin = origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    /// 调试页调整设置窗口尺寸：内容区按 store 当前值（钳制进区间）重设，
    /// 按新高度重裁摆位并重摆，防抖重算抽屉限高（高度变化改让位带宽；
    /// 全量重建不能逐滑杆 tick 执行，与网格指标变化同用 100ms 停顿合并）。
    func applySettingsWindowSize() {
        guard let window = settingsWindowController?.window else { return }
        let store = settingsStore
        let width = min(
            max(store.settingsWindowWidth, SettingsWindowMetrics.widthRange.lowerBound),
            SettingsWindowMetrics.widthRange.upperBound
        )
        let height = min(
            max(store.settingsWindowHeight, SettingsWindowMetrics.heightRange.lowerBound),
            SettingsWindowMetrics.heightRange.upperBound
        )
        if width != store.settingsWindowWidth { store.settingsWindowWidth = width }
        if height != store.settingsWindowHeight { store.settingsWindowHeight = height }
        // setContentSize 保持顶缘不动（origin 随之下移/上移），锚定的
        // origin 必须重摆；窗口高度变了，摆位（下方是否还放得下）也要重裁。
        // 宽度可能变化，横向不做保留、回屏幕中线（keepX: false）。
        window.setContentSize(NSSize(width: width, height: height))
        updateSettingsPlacement()
        positionSettingsWindow(keepX: false)
        settingsResizeTask?.cancel()
        settingsResizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            guard !Task.isCancelled, let self else { return }
            self.refreshAfterLayoutChange()
        }
    }
}
