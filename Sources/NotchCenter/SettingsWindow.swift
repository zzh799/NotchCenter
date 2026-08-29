import AppKit
import SwiftUI

// MARK: - 设置面板（文档 §6.1 / §4.8）

/// 设置面板窗口：带侧边栏的多页结构（通用 / 组件 / 布局 / 插件）。
///
/// 与抽屉的关系（本次改造的核心）：
/// - 面板**贴挂在抽屉下方**（顶缘 = 抽屉可见底缘 + 间距），由
///   `NotchPanelController.positionSettingsWindow()` 在抽屉尺寸变化时重新对齐；
/// - 面板**置顶**（level 高于抽屉），跨 Space、不随其他应用隐藏；
/// - 面板可见期间抽屉**常驻展开**（`isSettingsPresented`），改设置即可在
///   抽屉上看到实时效果，也可直接从「组件」页拖块到抽屉/快速区。
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

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowMetrics.width,
                height: SettingsWindowMetrics.height
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
        panel.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.062, alpha: 1)
        panel.animationBehavior = .none

        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: SettingsRootView(controller: panelController, selection: selection)
        )
        // 显式约束内容区：root view 的 `.frame(...)` 不足以阻止 hosting view
        // 因 HStack/Spacer 把 fitting size 撑到 616，把 contentSize 锁回 560
        // 后窗口 frame = 588（titlebar 28），与 layout 计算一致。
        panel.setContentSize(
            NSSize(
                width: SettingsWindowMetrics.width,
                height: SettingsWindowMetrics.height
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
    static let width: CGFloat = 780
    static let height: CGFloat = 560
    /// 面板顶缘与抽屉可见底缘的间距。
    static let gapFromDrawer: CGFloat = 8
}

// MARK: - 页面

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case components
    case layout
    case plugins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("settings.tab.general")
        case .components: return L("settings.tab.components")
        case .layout: return L("settings.tab.layout")
        case .plugins: return L("settings.tab.plugins")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .components: return "square.grid.2x2"
        case .layout: return "rectangle.3.group"
        case .plugins: return "puzzlepiece.extension"
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
                .overlay(.white.opacity(0.07))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.055, green: 0.055, blue: 0.062))
        .environment(\.colorScheme, .dark)
        .frame(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
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
                        .font(.system(size: 11, weight: .semibold))
                    Text(L("settings.quit"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.45))
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
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(page.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.12 : 0))
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
        }
    }
}

// MARK: - 控制器入口

extension NotchPanelController {
    /// 打开设置面板：抽屉常驻展开（不自动收起），面板贴挂到抽屉下方并置顶。
    /// 面板已可见时再触发一次即关闭（抽屉顶栏齿轮 = 开关）。
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
        if !isExpanded {
            expand(animated: true, activate: false)
        }
        controller.showSettings(page: targetPage)
        // 显式驱动组件页联动：onChange(of: selection.page) 只在视图挂载并
        // 求值后才触发，首次打开（rootView 未求值）或页值未变时不可靠；
        // setComponentsPageActive 自带幂等 guard，与 onChange 双触发也只
        // 生效一次。
        setComponentsPageActive(targetPage == .components)
        positionSettingsWindow()
    }

    /// 关闭设置面板（齿轮按钮 / 抽屉关闭按钮 / 窗口关闭）。
    func closeSettings() {
        isSettingsPresented = false
        // 面板关闭即离开组件页：先退出其联动的编辑模式，再按常规逻辑收起。
        setComponentsPageActive(false)
        settingsWindowController?.close()
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
        if !isPinned {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    /// 把设置面板对齐到抽屉可见底缘：屏幕中线水平居中，顶缘 = 抽屉底缘
    /// + 间距；屏幕高度不足时贴屏幕底（面板层级更高，允许与抽屉重叠）。
    func positionSettingsWindow() {
        SettingsSwitchProbe.measure("positionSettingsWindow") {
            guard let window = settingsWindowController?.window else { return }
            guard let pair = activePair ?? pairs.first else { return }
            let visible = visibleDrawerFrame(for: pair)
            let size = window.frame.size
            let originY = max(
                visible.minY - SettingsWindowMetrics.gapFromDrawer - size.height,
                pair.screenFrame.minY + 12
            )
            let originX = pair.screenFrame.midX - size.width / 2
            window.setFrameOrigin(NSPoint(x: round(originX), y: round(originY)))
        }
    }
}
