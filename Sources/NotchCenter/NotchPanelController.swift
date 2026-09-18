import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 宿主控制器

/// 核心控制器：刘海交互、窗口管理、插件生命周期编排、布局渲染（文档 §2.1 / §5 / §6 / §7）。
/// 每块屏一套面板，抽屉只在鼠标所在屏展开；视图构建 / 事件监听 / 调试支持
/// 分别见 NotchPanelContent.swift / NotchPanelInteraction.swift / NotchPanelDebugSupport.swift。
@MainActor
final class NotchPanelController: NSObject {
    let settingsStore = SettingsStore()
    private(set) var layoutEngine: LayoutEngine!
    private(set) var pluginManager: PluginManager!

    /// 快捷动作注册表：宿主经 `HostController.quickActions()` 暴露给插件，
    /// 编辑模式的「快捷动作」目录与快捷按钮盒都从这里取数（文档 §4.11）。
    let quickActionStore = QuickActionStore()

    /// 面板 UI 状态（所有屏幕的 SwiftUI 视图共享此对象；root 视图只在创建时设置一次）。
    let uiState: PanelUIState

    /// 每个屏幕的面板对。
    var pairs: [ScreenPanelPair] = []
    /// 当前展开抽屉的屏幕面板对。
    var activePair: ScreenPanelPair?

    /// 钉住状态（抽屉是否保持常开）。经 uiState 发布，顶部按钮即时同步。
    var isPinned: Bool {
        get { uiState.isPinned }
        set { uiState.isPinned = newValue }
    }

    /// 编辑模式。经 uiState 发布；编辑期间抽屉不会自动收起（与钉住无关）。
    var isEditing: Bool {
        get { uiState.isEditing }
        set { uiState.isEditing = newValue }
    }

    /// 抽屉是否处于展开状态（纯控制器逻辑，不进 UI 状态）。
    private(set) var isExpanded = false

    /// 设置面板是否可见：期间抽屉常驻展开且限高让位于面板。经 uiState 发布。
    var isSettingsPresented: Bool {
        get { uiState.isSettingsPresented }
        set { uiState.isSettingsPresented = newValue }
    }

    /// 设置面板当前摆位（贴抽屉下方 / 停靠屏幕底部）：打开时按抽屉**自然**
    /// 高度裁定，布局提交后重裁，关闭清空。摆位是抽屉限高的输入——限高
    /// 依赖摆位、摆位又依赖限高会自激，因此裁定只用未限高的高度。
    var settingsPlacement: SettingsPlacement?

    /// 设置面板停在「组件」页：期间抽屉保持编辑模式，离开该页或关闭面板时退出。
    /// 由 `setComponentsPageActive` 独占写入；`isEditing` 是两者合并后的只读视图。
    var isEditingForComponentsPage = false

    var isRevealedForFileDrag = false
    /// 滑动切页后的「待重入」驻留期：滑动中面板随目标页收缩，光标可能被
    /// "甩"到抽屉外，置位期间不安排收起，等鼠标回来。会话建立时置位，
    /// 重入停留区、收起或重新展开时清除。
    var isAwaitingDrawerReentry = false
    /// 收起态进入编辑的等待期（揭示 → 编辑两段式之间）：两段共用
    /// `drawerWindowSize` 这唯一一条 spring 通道，同帧叠加会从中间值起跳。
    /// 等待期内该标志必须参与收起守卫，否则揭示中途被收起。
    var isEditEntryPending = false
    var activeMenuTrackingCount = 0
    var drawerScrollTracker = DrawerPageScrollTracker()
    /// 滑动切页落位/回弹的自驱弹簧（见 `DrawerSwipeSpringDriver`）：解析解
    /// 逐帧把表现值写进会话，收敛拍自己触发——`withAnimation(completion:)`
    /// 在 AppKit 事件上下文不保证触发，兜底时钟方案已随本驱动器删除。
    /// 状态值 ≡ 表现值也让"动画中接管"成为零成本操作（取消即接管）。
    let swipeSpringDriver = DrawerSwipeSpringDriver()
    /// 顶栏胶囊行的**边缘自动滚**：拖动期指针压进滚动区两侧边带时逐帧滚行
    /// （视野外的胶囊与加号才够得着）。偏移本体在 `uiState`，驱动器只做步进。
    let capsuleScrollDriver = DrawerCapsuleScrollDriver()
    var collapseTask: DispatchWorkItem?
    /// 网格指标变化的重建合并任务（滑杆拖动逐格通知 → 停顿后重建一次）。
    var metricsRebuildTask: Task<Void, Never>?
    /// 调试页改设置窗口尺寸后的抽屉限高重算合并任务（同上防抖策略）。
    var settingsResizeTask: Task<Void, Never>?
    var mousePollingTimer: Timer?
    var globalMouseDownMonitor: Any?
    var globalMouseUpMonitor: Any?
    var pluginManagerWindowController: PluginManagerWindowController?
    var settingsWindowController: SettingsWindowController?

    /// 上一次内容重建的视图复用键（紧凑按槽位下标、抽屉按 placementID）：
    /// `rebuildContent` 是编辑提交/切页/展开的高频路径，每次都为**每个块**
    /// 重新 `makeView` 会把没变的插件视图也整树重挂（AnyView 新实例 →
    /// SwiftUI 子树全部重渲染）。键 = makeView 可观察输入的完整快照
    /// （`BlockViewCacheKey`），逐项相等时直接复用上一次的视图值——SwiftUI
    /// 端等价于"父视图重渲染、子视图输入未变"。每次构建整体替换缓存，
    /// 被移除的槽位/块自动出表。
    var compactViewCache: [Int: (key: BlockViewCacheKey, view: AnyView)] = [:]
    var drawerViewCache: [String: (key: BlockViewCacheKey, view: AnyView)] = [:]

    override init() {
        uiState = PanelUIState()

        super.init()

        pluginManager = PluginManager(hostController: self, quickActionStore: quickActionStore)
        layoutEngine = LayoutEngine(
            blockResolver: { [weak self] pluginID, blockID in
                self?.pluginManager.block(pluginID: pluginID, blockID: blockID)
            },
            // 清理判据与占位文案同源（placementAvailability）；判据在这里而不是
            // 交给块解析器，是因为插件被停用时解析器返回 nil（实例已释放），
            // 照它清理会删掉可逆停用状态下的摆放。
            placementLiveness: { [weak self] pluginID, blockID in
                guard let self else { return true }
                return placementAvailability(pluginID: pluginID, blockID: blockID).isLive
            }
        )

        pluginManager.onEnabledPluginIDsChanged = { [weak self] _, newIDs in
            guard let self else { return }
            self.layoutEngine.syncEnabledPluginIDs(newIDs)
            // 启用/禁用（含安装/卸载路径）会改 makeView 依赖的插件全局状态
            // （如 NotesModel 按 store 重新解析、pluginWasDisabled 清实例数据），
            // 复用键里的 entry 身份不足以察觉——视图复用缓存整体失效。
            self.compactViewCache.removeAll()
            self.drawerViewCache.removeAll()
            self.rebuildContent()
        }

        // 设置面板拖出的组件块，落点命中测试由此接管。
        BlockDragCoordinator.shared.controller = self

        syncScreens()
        updateScreenConstraint()
        observeGridMetricsChanges()

        // 启用状态恢复（文档 §5.4）。
        if layoutEngine.didLoadFromDisk {
            pluginManager.restoreEnabledState(from: layoutEngine.enabledPluginIDs)
        } else {
            seedDefaultLayout()
        }

        // 先同步紧凑区几何（带宽随图标数伸缩），再重建内容。
        refreshCompactGeometry()
        rebuildContent()
        startMousePolling()
        observeScreenChanges()
        observeGlobalMouseEvents()
        observeMenuTracking()
    }

    /// 网格指标变化后重建内容：抽屉几何全部由 `NotchGridMetrics` 推导。
    /// （设置面板的重定位由 `refreshAfterLayoutChange` 统一负责，见
    /// `updateSettingsPlacement`。）
    @objc private func gridMetricsDidChange(_ notification: Notification) {
        // 滑杆拖动逐格发通知，全量重建合并到停顿 100ms 后执行一次；
        // store 侧每格仍即时持久化，设置页预览即时刷新，不受合并影响。
        metricsRebuildTask?.cancel()
        metricsRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            guard !Task.isCancelled, let self else { return }
            self.refreshAfterLayoutChange()
        }
    }

    private func observeGridMetricsChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gridMetricsDidChange(_:)),
            name: GridMetricsStore.didChangeNotification,
            object: nil
        )
    }

    // MARK: - 多屏幕管理（文档 §6.3：每个屏幕单独显示一个 NotchCenter）

    /// 同步屏幕与面板对：新屏幕创建、断开的屏幕移除，并重新定位全部面板。
    func syncScreens() {
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens

        // 移除断开屏幕的面板对（NSScreen 身份在显示重配后会换新身份）。
        // 窗口不会随 pair 移除自动隐藏，必须显式收回，否则与新 pair 叠影。
        let stalePairs = pairs.filter { pair in !screens.contains { $0 === pair.screen } }
        pairs.removeAll { pair in !screens.contains { $0 === pair.screen } }
        for stale in stalePairs {
            stale.hotPanel.orderOut(nil)
            stale.drawerPanel.orderOut(nil)
        }

        // 为新接入的屏幕创建面板对。
        for screen in screens where !pairs.contains(where: { $0.screen === screen }) {
            let pair = ScreenPanelPair(screen: screen, uiState: uiState) { Self.configurePanel($0) }
            wirePairEvents(pair)
            pairs.append(pair)
        }

        // 各自定位紧凑热区；展开中的那块同时定位抽屉。
        for pair in pairs {
            positionCompactPanel(pair)
        }
        // 新接入的 pair 摘要宽度镜像默认 0：按当前生效摘要宽度同步一次。
        syncSummaryGeometryMirrors()
        if let active = activePair, isExpanded {
            active.drawerPanel.setFrame(drawerFrame(for: active), display: true)
        }

        if activePair == nil || !pairs.contains(where: { $0 === activePair }) {
            activePair = pairs.first
        }
    }

    /// 把某屏幕的紧凑面板摆到其刘海位置（带宽随当前紧凑图标数伸缩）。
    func positionCompactPanel(_ pair: ScreenPanelPair) {
        pair.hotPanel.setFrame(pair.hotFrame, display: true)
        pair.hotPanel.orderFrontRegardless()
    }

    /// 主屏布局（用于共享渲染内容；窗口几何按各屏自身计算）。
    func primaryLayout() -> NotchLayout {
        NotchGeometry.layout(
            for: pairs.first?.screen,
            compactCount: pairs.first?.compactCount ?? 0
        )
    }

    /// 当前紧凑图标数（唯一来源：布局引擎模型，镜像经 `refreshCompactGeometry` 同步）。
    var compactIconCount: Int { layoutEngine.compactSlots.count }

    /// 某屏幕（或回退主屏）的紧凑条带几何；取带宽统一走这里。
    func compactStrip(for pair: ScreenPanelPair?) -> CompactStripLayout {
        if let pair { return pair.compactStrip }
        return primaryLayout().compactStrip(slotCount: compactIconCount)
    }

    /// 紧凑区几何同步：把引擎的紧凑图标数推到各 pair 镜像与 `uiState`，
    /// 并按新带宽重摆热区窗口。任何改变紧凑图标数的路径必须先调它、
    /// 再调 `rebuildContent`（后者是纯内容重建，无窗口副作用）。
    func refreshCompactGeometry() {
        let compactCount = layoutEngine.compactSlots.count
        uiState.compactCount = compactCount
        for pair in pairs where pair.compactCount != compactCount {
            pair.compactCount = compactCount
            positionCompactPanel(pair)
        }
    }

    /// 鼠标所在屏幕的面板对；不在任何激活区时返回 nil。
    func pairContainingLocation(_ point: NSPoint) -> ScreenPanelPair? {
        pairs.first { $0.hotFrame.contains(point) }
    }

    /// 屏幕约束同步：宽度 + **可用抽屉高度**（行容量与行档位的来源）。
    ///
    /// 高度取 `maxDrawerHeight`（屏高 − 顶部留白 − 紧凑带），**不取**
    /// `drawerMaxVisibleHeight`——后者含设置面板让位量、随面板开合瞬变，
    /// 会让行列档位在打开设置面板时突然缩水。
    ///
    /// 取**所有屏幕**的最小可用尺寸（文档 §7.1 / §7.2）：布局是全屏共享的一份，
    /// 按单块屏算会让抽屉搬到小屏放不下、档位随所在的屏跳变。因此这里不接收
    /// pair——没有"当前屏"的概念，活动屏换到哪块都不影响结果。
    func updateScreenConstraint() {
        guard !pairs.isEmpty else {
            layoutEngine.updateScreenConstraint(width: 1440, height: nil)
            return
        }
        layoutEngine.updateScreenConstraint(
            availableScreenSizes: pairs.map {
                CGSize(width: $0.screenFrame.width, height: maxDrawerHeight(for: $0))
            }
        )
    }

    // MARK: - 对外入口

    func showDocked() {
        // 兜底同步，保证收起带宽对应当前图标数。
        refreshCompactGeometry()
        rebuildContent()
        isExpanded = false
        setCollapsedSize()
        isRevealedForFileDrag = false
        for pair in pairs {
            positionCompactPanel(pair)
            pair.drawerPanel.orderOut(nil)
        }
    }

    func expand(animated: Bool, activate: Bool = true) {
        if isExpanded {
            // 已展开：点击另一块屏的热区 = 把抽屉搬过去（旧屏收走，新屏
            // 常规揭示），也是滑动驻留期里在其他屏点击的逃生通道；
            // 同屏点击只做焦点前置。
            if let pair = pairContainingLocation(NSEvent.mouseLocation),
               pair !== activePair {
                activePair = pair
                // 容量与所在屏无关（全屏最小值，见 `updateScreenConstraint()`）；
                // 这里同步只是保新鲜（屏配置可能刚变过），结果不随 pair 变。
                updateScreenConstraint()
                cancelCollapse()
                isAwaitingDrawerReentry = false
                presentDrawer(animated: animated, activate: activate)
                return
            }
            if activate {
                NSApp.activate(ignoringOtherApps: true)
                activePair?.drawerPanel.makeKeyAndOrderFront(nil)
            }
            hideOtherDrawers(keeping: activePair)
            return
        }
        // 在鼠标所在屏幕展开；不在任何激活区则沿用上次的屏幕。
        guard let pair = pairContainingLocation(NSEvent.mouseLocation) ?? activePair ?? pairs.first else {
            return
        }
        // 性能探针会话从**冷路径入口**起算（守卫之后、动状态之前）：用户
        // 感知的等待 = 这里到内容淡入完成，中间每一段都由后续埋点分解。
        DrawerOpenPerfCollector.shared.begin()
        activePair = pair
        updateScreenConstraint()

        cancelCollapse()
        isExpanded = true
        isRevealedForFileDrag = false
        isAwaitingDrawerReentry = false
        presentDrawer(animated: animated, activate: activate)
    }

    /// 在（已是新的）`activePair` 上呈现抽屉；新建展开与跨屏搬移共用。
    private func presentDrawer(animated: Bool, activate: Bool) {
        guard let pair = activePair else { return }
        rebuildContent()
        DrawerOpenPerfCollector.shared.mark(.rebuilt)
        positionCompactPanel(pair)
        // 窗口固定尺寸，只上线不动画；可见面板经 `drawerWindowSize`（唯一
        // 动画真源）从紧凑带 spring 变形到全尺寸。
        pair.drawerPanel.setFrame(drawerFrame(for: pair), display: true)
        // 自愈：收回其他屏残留的抽屉窗口（跨屏竞态，见 `hideOtherDrawers`）。
        hideOtherDrawers(keeping: pair)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            pair.drawerPanel.makeKeyAndOrderFront(nil)
        } else {
            pair.drawerPanel.orderFrontRegardless()
        }
        setDrawerRevealed(true, animated: animated)
        // 窗口已上线、尺寸 spring 已起播：此后到首次布局的耗时 = SwiftUI
        // 构建并布局整棵内容树的成本（块数 N 的主战场）。
        DrawerOpenPerfCollector.shared.mark(.revealed)
    }

    /// 抽屉单例不变量：任一时刻至多一个屏的抽屉窗口在屏。收起完成回调有
    /// 0.43s 窗口，期间跨屏再展开会绕过旧 pair 的 orderOut，残留窗口共享
    /// uiState、渲染成一份活抽屉（“新建笔记多出一块面板”的根因）。
    private func hideOtherDrawers(keeping kept: ScreenPanelPair?) {
        for pair in pairs where pair !== kept {
            pair.drawerPanel.orderOut(nil)
        }
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        isExpanded = false
        isRevealedForFileDrag = false
        // 任何收起路径都结束滑动驻留期，下次展开不继承驻留态。
        isAwaitingDrawerReentry = false
        if isEditing {
            isEditing = false
        }
        // 抽屉消失后拖拽会话与落位飞行立即收尾，否则浮窗悬空、新块卡隐形。
        BlockDragCoordinator.shared.cancel()
        DragPreviewLanding.shared.cancel()
        setDrawerRevealed(false, animated: animated)
        // Kit 的 BlockPopover 订阅此通知立即关闭浮窗，不等收起动画结束。
        NotificationCenter.default.post(name: .notchCenterDrawerDidCollapse, object: nil)
        let completion = { [weak self] in
            guard let self else { return }
            // 等待期内可能再次展开（同屏返回或跨屏搬移）：只保留当前展开
            // 屏的抽屉，其余一律收回；不能因“已重新展开”整体跳过，否则
            // 上一块屏的抽屉会永久残留。
            let kept = self.isExpanded ? self.activePair : nil
            for pair in self.pairs where pair !== kept {
                pair.drawerPanel.orderOut(nil)
                self.positionCompactPanel(pair)
            }
        }
        if animated {
            // 与 easeOut(0.16) 收起动画匹配，等面板缩回刘海再隐藏窗口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: completion)
        } else {
            completion()
        }
    }

    /// 展开/收起 = `drawerWindowSize` 在紧凑带与完整抽屉尺寸之间的
    /// withAnimation 变形；容器 frame 绑定它，窗口 frame 固定满高不参与。
    private func setDrawerRevealed(_ revealed: Bool, animated: Bool) {
        let target: CGSize
        if revealed {
            target = drawerWindowSize(for: activePair)
        } else {
            target = collapsedPanelSize()
        }
        guard animated else {
            uiState.isDrawerExpanded = revealed
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                uiState.drawerWindowSize = target
            }
            // 摘要让位/恢复：抽屉展开期间摘要不展示（带宽随之收缩），
            // 收起后按有效宽度恢复。热区窗口 frame 不参与动画，直接重摆。
            syncSummaryGeometryMirrors()
            return
        }
        // 展开先无动画贴到紧凑带起点（rebuildContent 可能已把尺寸写成
        // 全量），再同一节拍 spring 到目标。收起不能贴起点——起点就是
        // 当前全量尺寸，无动画写成目标会瞬跳且丢收起动画。
        if revealed {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                uiState.drawerWindowSize = collapsedPanelSize()
            }
        }
        withAnimation(revealed ? .spring(response: 0.28, dampingFraction: 0.86) : .easeOut(duration: 0.16)) {
            uiState.isDrawerExpanded = revealed
            uiState.drawerWindowSize = target
        }
        // 让位/恢复的带宽变化随状态翻转同步（AppKit setFrame 不经 SwiftUI
        // Transaction，这里不在 withAnimation 内也不影响抽屉动画）。
        syncSummaryGeometryMirrors()
    }

    /// 收起态的可见面板尺寸：紧凑带宽度 × 0 内容高。
    private func collapsedPanelSize() -> CGSize {
        CGSize(width: compactStrip(for: activePair).windowWidth, height: 0)
    }

    private func setCollapsedSize() {
        uiState.isDrawerExpanded = false
        uiState.drawerWindowSize = collapsedPanelSize()
        // 收起态恢复摘要展示带宽（若序列非空）。
        syncSummaryGeometryMirrors()
    }

    /// 退出前落盘（AppDelegate 调用）。
    func flush() {
        layoutEngine.saveToDisk()
    }

    func isDrawerExpanded() -> Bool {
        isExpanded
    }

    /// 布局配置（如列数）变化后的刷新：重建内容并在展开时重设抽屉窗口 frame。
    /// `animated: true` 时内容同批套 spring（设置页列数/最小行数回调）；
    /// 列数配置变化下 `drawerFrame` 恒等，`setFrame` 为无害 no-op。
    func refreshAfterLayoutChange(animated: Bool = false) {
        // 设置页打开：**先重裁摆位再重建**——限高读摆位（见
        // `drawerWindowSize`），顺序反了抽屉会用上一轮摆位让位。
        let placementChanged = updateSettingsPlacement()
        rebuildContent(animated: animated)
        if isExpanded, let pair = activePair {
            pair.drawerPanel.setFrame(drawerFrame(for: pair), display: true)
        }
        // 摆位变了才重摆窗口：面板随布局提交（增删块/改列数）平移一次，
        // 不逐帧跟随抽屉的 spring——那是被否决的旧桥。
        if placementChanged {
            positionSettingsWindow(animated: true)
        }
    }

    // MARK: - 几何

    /// 抽屉窗口内容尺寸（不含岛顶紧凑带）：先按屏幕可用高度封顶
    /// （文档 §5.3），设置面板打开时再按其**当前摆位**的顶缘限高。
    /// `previewRows` / `previewColumns` 用于拖拽/缩放预览的临时增高/增宽；
    /// `page` 缺省 = 当前激活页。
    func drawerWindowSize(
        for pair: ScreenPanelPair?,
        page: Int? = nil,
        previewRows: Int? = nil,
        previewColumns: Int? = nil
    ) -> CGSize {
        var size = layoutEngine.drawerWindowSize(
            contentRows: previewRows,
            contentColumns: previewColumns,
            page: page ?? uiState.drawerActivePage
        )
        guard let pair else { return size }
        let maxHeight = drawerMaxVisibleHeight(for: pair)
        if size.height > maxHeight {
            size.height = maxHeight
        }
        return size
    }
    /// 抽屉窗口（方案 E：固定满高满宽）：顶缘钉死屏幕顶端；宽度固定为
    /// 屏幕能容纳的最大列数（不受用户列数配置约束），可见面板在窗口内
    /// 自适应收缩并居中，多出部分靠 hitTest + `ignoresMouseEvents` 双机制
    /// 穿透。窗口 frame 不跟随内容宽度动画——否则会裁剪 spring 变形中的
    /// 内容；列数配置变化因此完全不改窗口 frame。
    private func drawerFrame(for pair: ScreenPanelPair) -> NSRect {
        let screenFrame = pair.screenFrame
        let width = NotchGridMetrics.contentWidth(columns: layoutEngine.screenColumnCapacity())
            + NotchGridMetrics.contentPadding * 2
        let size = CGSize(
            width: width,
            height: min(screenFrame.height - 8, screenFrame.height)
        )
        return NotchGeometry.topCenteredFrame(
            for: size,
            topY: screenFrame.maxY,
            in: screenFrame
        )
    }

    /// 拖拽/缩放预览期间面板按需增高/增宽：只更新 uiState 尺寸（窗口高度
    /// 固定，无 frame 操作），提交后由 `refreshAfterEdit` 回落。`resized`
    /// 为正在缩放块的新跨度。尺寸变化与块推挤同帧、同一 spring，不等松手。
    ///
    /// 设置面板打开时预览**同样遵守抽屉限高**（`drawerMaxVisibleHeight`）：
    /// 抽屉在预览中不得长回自然大小盖住面板，设置窗口因此全程不动；摆位
    /// 只随提交路径（`refreshAfterEdit`）重裁。
    func applyPreviewWindowSize(
        _ origins: [String: LayoutEngine.GridOrigin],
        resized: (placementID: String, heightRows: Int, widthColumns: Int)? = nil
    ) {
        guard isExpanded, let pair = activePair, !origins.isEmpty else { return }
        // 预览 origins 里的块同属一页，任取一个即可确定页面。
        let page = origins.keys.first.flatMap { layoutEngine.page(ofPlacementID: $0) }
            ?? uiState.drawerActivePage
        let resizedColumns = resized.map { ($0.placementID, $0.widthColumns) }
        let columnRange = layoutEngine.previewColumnRange(
            origins: origins,
            resized: resizedColumns,
            page: page
        )
        let bottomRow = layoutEngine.previewBottomRow(
            origins: origins,
            resized: resized.map { ($0.placementID, $0.heightRows) },
            page: page
        )
        let metrics = DrawerLayoutMetricsResolver.pushed(
            columnRange: columnRange,
            bottomRow: bottomRow,
            geometry: drawerGridGeometry(),
            maxHeight: drawerMaxVisibleHeight(for: pair)
        )
        withAnimation(DrawerAnimation.spring) {
            // 块已被推挤，左列必须重算：左扩 = 全体块横移 + 面板重居中。
            uiState.drawerGridLeftColumn = metrics.leftColumn ?? uiState.drawerGridLeftColumn
            // 容器高度随预览最低行同步，否则缩小时 ScrollView 反复亮滚动条。
            uiState.drawerContentSize = metrics.contentSize
            guard uiState.drawerWindowSize != metrics.windowSize else { return }
            uiState.drawerWindowSize = metrics.windowSize
        }
    }

    /// 拖拽**落点预览**期间的面板增高/增宽：按「占位框 ∪ 提交布局」的
    /// 并集扩展。与 `applyPreviewWindowSize` 的分工：本方法服务块还没动、
    /// 只有占位框的预览（从设置面板拖入），**绝不写 `drawerGridLeftColumn`**
    /// （改左列 = 全体块横移，与拖动期间其余块零位移冲突）。
    /// `zone` 为 nil 表示回到提交布局的尺寸（拖拽取消或落位后）。
    ///
    /// 设置面板打开时预览**同样遵守抽屉限高**（`drawerMaxVisibleHeight`）：
    /// 拖动组件期间抽屉保持适应大小、设置窗口全程不动；松手后的让位由
    /// `refreshAfterEdit` 的摆位重裁负责。
    func applyDropPreviewWindowSize(_ zone: BlockDragCoordinator.DropZone?) {
        guard isExpanded, let pair = activePair else { return }
        let activePage = uiState.drawerActivePage
        let left = layoutEngine.gridLeftColumn(page: activePage)
        var rows = layoutEngine.drawerContentRows(page: activePage)
        var right = left + layoutEngine.occupiedColumns(page: activePage)
        if case let .drawer(column, row, columns, blockRows)? = zone {
            rows = max(rows, row + blockRows)
            right = max(right, column + columns)
        }
        let metrics = DrawerLayoutMetricsResolver.dropZone(
            leftColumn: left,
            rightEdge: right,
            rows: rows,
            geometry: drawerGridGeometry(),
            maxHeight: drawerMaxVisibleHeight(for: pair)
        )
        // 值未变直接返回：每帧调用，重复赋值会不断重启 spring（面板抖动）。
        guard uiState.drawerWindowSize != metrics.windowSize
                || uiState.drawerContentSize != metrics.contentSize else { return }
        // 内容与窗口尺寸同相同帧，否则 ScrollView 反复亮灭滚动条；
        // 不写 `drawerGridLeftColumn`（`metrics.leftColumn` 为 nil 即此约束）。
        withAnimation(DrawerAnimation.spring) {
            uiState.drawerContentSize = metrics.contentSize
            uiState.drawerWindowSize = metrics.windowSize
        }
    }

    /// 网格内容 ↔ 屏幕的换算桥：格 → 屏与屏 → 格共用同一份，互逆性由
    /// `DrawerScreenMapper` 的结构保证。落位终点与占位框差一格即明显跳动。
    func drawerScreenMapper(for pair: ScreenPanelPair) -> DrawerScreenMapper {
        DrawerScreenMapper(
            visibleFrame: visibleDrawerFrame(for: pair),
            // 网格内容顶缘：自可见面板顶缘向下让出紧凑带与顶栏。
            topInset: pair.layout.compactHeight + NotchGridMetrics.drawerTopBarHeight,
            geometry: drawerGridGeometry()
        )
    }

    /// 网格几何（渲染基准列 + 列容量），随取随算——网格指标与布局都会变。
    func drawerGridGeometry() -> DrawerGridGeometry {
        DrawerGridGeometry(
            metrics: .current,
            leftColumn: layoutEngine.gridLeftColumn(page: uiState.drawerActivePage),
            capacity: layoutEngine.effectiveMaxColumns(),
            minimumRows: layoutEngine.minimumRowCount(),
            minimumColumns: layoutEngine.minimumColumnCount()
        )
    }

    /// 屏幕坐标是否落在当前激活页的任一抽屉块上。
    func isPointOverDrawerBlock(_ screenPoint: NSPoint) -> Bool {
        drawerElement(at: screenPoint) != nil
    }

    /// 屏幕坐标处的当前页抽屉块。抽屉滑动的让路判据用它定位光标下的块，
    /// 再经 `DrawerScrollProbe` 核实横向溢出。
    func drawerElement(at screenPoint: NSPoint) -> DrawerElement? {
        guard isExpanded, let pair = activePair else { return nil }
        let mapper = drawerScreenMapper(for: pair)
        return uiState.drawerElements.first { element in
            mapper.screenRect(for: GridCell(element.placement)).contains(screenPoint)
        }
    }

    /// 抽屉可见高度上限：屏幕高度扣掉顶部留白与岛顶紧凑带。
    func maxDrawerHeight(for pair: ScreenPanelPair) -> CGFloat {
        pair.screenFrame.height - 8 - pair.layout.compactHeight
    }

    /// 设置打开期间的抽屉限高（未打开返回 nil）：抽屉可见底缘不得低于
    /// 设置窗口顶缘再留间距（面板贴抽屉下方时该上限 == 裁定摆位时的自然
    /// 高度，即空操作）。放不开最小抽屉时返回 nil——整体放弃限高（允许
    /// 重叠），不能塌成 0；被截掉的内容走既有的 ScrollView 滚动路径。
    private func settingsDrawerHeightCap(for pair: ScreenPanelPair) -> CGFloat? {
        guard isSettingsPresented else { return nil }
        let minimumDrawerHeight = layoutEngine.drawerWindowSize(
            contentRows: layoutEngine.minimumRowCount()
        ).height
        let capped = NotchGeometry.settingsCappedDrawerHeight(
            screenMaxY: pair.screenFrame.maxY,
            settingsTopY: currentSettingsPlacement(for: pair).frameTopY,
            compactHeight: pair.layout.compactHeight
        )
        return capped >= minimumDrawerHeight ? capped : nil
    }

    /// 抽屉可见高度**总**上限：屏幕可用高度之外，设置面板打开期间再按当前
    /// 摆位顶缘让位。所有抽屉可见尺寸的写入点（展开、重建、拖拽/缩放/落位
    /// 预览）都必须经它封顶——预览路径绕过它，抽屉就会在拖拽中长回自然
    /// 大小、盖住设置面板（"组件页拖动组件抽屉恢复正常大小"事故的根因）。
    func drawerMaxVisibleHeight(for pair: ScreenPanelPair) -> CGFloat {
        guard let capped = settingsDrawerHeightCap(for: pair) else {
            return maxDrawerHeight(for: pair)
        }
        return min(maxDrawerHeight(for: pair), capped)
    }

    // MARK: - 设置面板摆位

    /// 设置窗口 frame 高度（内容高度 + 透明 titlebar）：摆位与抽屉限高共用
    /// 同一个量——两处分开算会让抽屉让位多出/少掉一个 titlebar。
    var settingsWindowBandHeight: CGFloat {
        settingsStore.settingsWindowHeight + SettingsWindowMetrics.titleBarHeight
    }

    /// 抽屉**未因设置面板让位**时的可见内容高度：摆位裁定的唯一输入。
    /// 限高结果不能反过来喂给摆位（抽屉被裁矮 → 下方更"够"→ 永远贴抽屉
    /// 下方），因此这里直接用引擎高度，不读 `drawerWindowSize`。
    private func naturalDrawerContentHeight(for pair: ScreenPanelPair) -> CGFloat {
        let natural = layoutEngine.drawerWindowSize(page: uiState.drawerActivePage).height
        return min(natural, maxDrawerHeight(for: pair))
    }

    /// 重裁设置面板摆位（按预判的最终激活屏），返回摆位是否发生变化——
    /// 变化时需要重摆窗口，见 `refreshAfterLayoutChange`。
    ///
    /// 面板可见期间抽屉高度会随布局提交变化，重裁即让面板跟着抽屉走：
    /// 贴抽屉下方时抽屉长高会把面板推下去，推到放不下则退回屏幕底部。
    @discardableResult
    func updateSettingsPlacement() -> Bool {
        guard isSettingsPresented, let pair = settingsAnchorPair() else {
            settingsPlacement = nil
            return false
        }
        let placement = makeSettingsPlacement(for: pair)
        let changed = placement != settingsPlacement
        settingsPlacement = placement
        return changed
    }

    /// 摆位裁定所用屏幕：已展开取激活屏；未展开按 `expand()` 的选屏规则
    /// 预判（鼠标所在屏 → 上次激活屏 → 首屏），保证限高落在最终承载抽屉
    /// 的那块屏上。
    private func settingsAnchorPair() -> ScreenPanelPair? {
        activePair ?? pairContainingLocation(NSEvent.mouseLocation) ?? pairs.first
    }

    /// 抽屉限高与窗口定位共用同一份摆位缓存：两处各算一次会在「布局提交」
    /// 与「重摆窗口」之间错开一帧。缓存为空（限高先于打开被求值）时按需补裁。
    func currentSettingsPlacement(for pair: ScreenPanelPair) -> SettingsPlacement {
        guard let placement = settingsPlacement else {
            let placement = makeSettingsPlacement(for: pair)
            settingsPlacement = placement
            return placement
        }
        return placement
    }

    private func makeSettingsPlacement(
        for pair: ScreenPanelPair,
        drawerContentHeight: CGFloat? = nil
    ) -> SettingsPlacement {
        let contentHeight = min(
            drawerContentHeight ?? naturalDrawerContentHeight(for: pair),
            maxDrawerHeight(for: pair)
        )
        return NotchGeometry.settingsPlacement(
            visibleMinY: pair.screen.visibleFrame.minY,
            drawerBottomY: NotchGeometry.drawerVisibleBottomY(
                screenMaxY: pair.screenFrame.maxY,
                compactHeight: pair.layout.compactHeight,
                drawerContentHeight: contentHeight
            ),
            bandHeight: settingsWindowBandHeight
        )
    }

    /// 屏幕横坐标 → 紧凑带内容坐标（热区窗口与抽屉可见面板共用）。
    func compactContentX(_ screenX: CGFloat, pair: ScreenPanelPair) -> CGFloat {
        screenX - pair.hotFrame.minX
    }

    /// 网格格坐标 → 屏幕矩形（Cocoa 坐标）。布局链：可见面板 = 紧凑带 +
    /// 顶栏 + 网格（水平内边距 `contentPadding`），顶缘钉死屏幕顶端。
    func drawerScreenRect(
        column: Int,
        row: Int,
        columns: Int,
        rows: Int
    ) -> CGRect? {
        guard let pair = activePair else { return nil }
        return drawerScreenMapper(for: pair).screenRect(
            for: GridCell(column: column, row: row, columnSpan: columns, rowSpan: rows)
        )
    }

    /// 落位飞行的终点：块**提交后**的最终屏幕矩形（面板宽度与最左列都可
    /// 能因落位改变，不能用拖动时的旧几何）。
    func landingRect(placementID: String) -> CGRect? {
        guard let placed = layoutEngine.drawerBlocks
            .first(where: { $0.placementID == placementID }) else { return nil }
        return drawerScreenRect(
            column: placed.originColumn,
            row: placed.originRow,
            columns: placed.widthColumns,
            rows: placed.heightRows
        )
    }

    /// 编辑操作提交后的刷新：内容 spring 重建，面板贴合内容。布局提交会改
    /// 抽屉自然高度（增删块、抽屉内拖拽/缩放落定、组件页拖块落位），与
    /// `refreshAfterLayoutChange` 同序——**先重裁摆位**（抽屉长高时设置
    /// 窗口让位到其下方，放不下退屏幕底部）再重建（限高读摆位，顺序反了
    /// 抽屉会用上一轮摆位让位）。
    func refreshAfterEdit() {
        let placementChanged = updateSettingsPlacement()
        rebuildContent(animated: true)
        if placementChanged {
            positionSettingsWindow(animated: true)
        }
    }
}

// MARK: - HostController 协议实现

extension NotchPanelController: HostController {
    func expandDrawer() {
        expand(animated: true, activate: false)
    }

    func collapseDrawer() {
        collapse(animated: true)
    }

    func enterEditMode() {
        startEditMode()
    }

    func exitEditMode() {
        stopEditMode()
    }

    func refreshCompactDisplay() {
        rebuildContent()
    }

    // MARK: 组件可用性（Agent Note 2026-09-11-invalid-component-visibility）

    /// 放置项指向的组件当前是否可用。**全项目唯一的可用性判据**——抽屉/紧凑带的
    /// 占位渲染与调试页「删除无效组件」都读它，避免养出第二套"什么叫失效"。
    ///
    /// 关键一条：插件已发现但未加载（= 停用中）判 `.pluginDisabled` 而非 `.missing`。
    /// 停用可逆，摆放要留着；而 `markEnabled(false)` 会释放实例，块解析器此时
    /// 返回 nil，光看解析器区分不出"停用"与"卸载"。
    func placementAvailability(pluginID: String, blockID: String) -> PlacementAvailability {
        guard let entry = pluginManager.entry(for: pluginID) else { return .missing }
        guard entry.instance != nil else { return .pluginDisabled }
        if pluginManager.block(pluginID: pluginID, blockID: blockID) != nil { return .live }
        // 快捷动作槽位合法绕过块注册表：动作 id 以 blockID 名义入槽，
        // 不能因解析不到插件块就判它失效。
        return quickActionStore.action(id: blockID) != nil ? .live : .missing
    }

    /// 调试页用：当前失效放置项数量（判据同 `placementAvailability`）。
    var invalidComponentCount: Int { layoutEngine.invalidPlacementCount() }

    /// 调试页用：删除全部失效放置项并刷新画面，返回删除数量。
    @discardableResult
    func removeInvalidComponents() -> Int {
        let removed = layoutEngine.purgeInvalidPlacements()
        if removed > 0 { rebuildContent() }
        return removed
    }

    // MARK: 快捷动作注册表通道（文档 §4.11）

    /// 当前已注册的全部快捷动作（按插件注册顺序展平）。
    func quickActions() -> [QuickAction] {
        quickActionStore.allActions()
    }

    /// 按 ID 查快捷动作；插件禁用/未知 ID 返回 nil。
    func quickAction(id: String) -> QuickAction? {
        quickActionStore.action(id: id)
    }

    // MARK: 系统权限通道（Agent Note 2026-09-11-permission-management-panel）

    /// 查询某项系统权限的当前状态（同步、无副作用、不弹窗）。
    func permissionStatus(of permission: SystemPermission) -> PermissionStatus {
        PermissionCenter.shared.status(of: permission)
    }

    /// 弹出「权限管理」弹窗；`focus` 为需要用户优先关注的权限（空 = 完整清单）。
    /// 设置页入口与插件运行时的缺权限引导都汇聚到这一条路径。
    func presentPermissions(_ focus: [SystemPermission]) {
        PermissionCenter.shared.presentPermissionGuide(focus: focus)
    }

    // MARK: 活动摘要通道（Agent Note 2026-09-03-compact-area-activity-summary）

    /// 展示或覆盖更新活动摘要：同 id 原位覆盖（不改变摘要序列中的新旧次序，
    /// 最新条目恒在序列尾），新 id 追加到序列尾。
    func showActivitySummary(_ summary: ActivitySummary) {
        if let index = uiState.activitySummaries.firstIndex(where: { $0.id == summary.id }) {
            guard uiState.activitySummaries[index] != summary else { return }
            uiState.activitySummaries[index] = summary
        } else {
            uiState.activitySummaries.append(summary)
        }
        syncSummaryWidths()
    }

    /// 收回指定活动摘要；id 不存在时无副作用。收回后可见对重算，
    /// 余下次新条目自动顶上空位（收回回退）。
    func removeActivitySummary(id: String) {
        guard uiState.activitySummaries.contains(where: { $0.id == id }) else { return }
        uiState.activitySummaries.removeAll { $0.id == id }
        syncSummaryWidths()
    }

    /// 依据当前摘要序列重算左右芯片估算宽度并同步镜像与几何。
    ///
    /// 只读模型（可见性/让位在 `PanelUIState.visibleSummaryPair` 与
    /// `effectiveSummary*Width` 一处判定）：这里把"若展示应为多宽"的估算值
    /// 写入 `summaryLeftWidth / summaryRightWidth`，并把生效宽度（含抽屉
    /// 展开让位）推到各 pair 的几何镜像——带宽变化时热区窗口 frame 随新
    /// 宽度重摆（窗口 frame 不参与动画：摘要芯片出现/更新/移除的过渡都在
    /// 窗口内容内完成）。估算宽度未变时无副作用。
    private func syncSummaryWidths() {
        // 可见性无关的芯片估算：按序列最新两条（最新在左、次新在右）——
        // 让位只影响镜像宽度（effective），不影响这里存储的估算值。
        let pair = ActivitySummaryDisplay.visiblePair(
            from: uiState.activitySummaries,
            drawerExpanded: false
        )
        let left = pair.left.map { SummaryChipMetrics.estimatedWidth(for: $0) } ?? 0
        let right = pair.right.map { SummaryChipMetrics.estimatedWidth(for: $0) } ?? 0
        if left != uiState.summaryLeftWidth || right != uiState.summaryRightWidth {
            uiState.summaryLeftWidth = left
            uiState.summaryRightWidth = right
        }
        syncSummaryGeometryMirrors()
    }

    /// 把生效摘要宽度（让位/无摘要 = 0）同步到各 pair 镜像并重摆热区窗口。
    /// 抽屉展开让位、收起恢复都走这里（`isDrawerExpanded` 翻转后调用）。
    func syncSummaryGeometryMirrors() {
        let left = uiState.effectiveSummaryLeftWidth
        let right = uiState.effectiveSummaryRightWidth
        var changed = false
        for pair in pairs where pair.summaryLeftWidth != left || pair.summaryRightWidth != right {
            pair.summaryLeftWidth = left
            pair.summaryRightWidth = right
            changed = true
        }
        guard changed else { return }
        for pair in pairs {
            positionCompactPanel(pair)
        }
    }
}
