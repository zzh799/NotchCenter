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

    /// 设置面板是否可见：期间抽屉常驻展开，面板贴挂抽屉下方并置顶。经 uiState 发布。
    var isSettingsPresented: Bool {
        get { uiState.isSettingsPresented }
        set { uiState.isSettingsPresented = newValue }
    }

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
    var collapseTask: DispatchWorkItem?
    /// 网格指标变化的重建合并任务（滑杆拖动逐格通知 → 停顿后重建一次）。
    var metricsRebuildTask: Task<Void, Never>?
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

        pluginManager = PluginManager(hostController: self)
        layoutEngine = LayoutEngine(blockResolver: { [weak self] pluginID, blockID in
            self?.pluginManager.block(pluginID: pluginID, blockID: blockID)
        })

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

    /// 网格指标变化后重建内容：抽屉几何全部由 `NotchGridMetrics` 推导，
    /// 设置面板也要跟着重新贴挂到新的抽屉底缘。
    @objc private func gridMetricsDidChange(_ notification: Notification) {
        // 滑杆拖动逐格发通知，全量重建合并到停顿 100ms 后执行一次；
        // store 侧每格仍即时持久化，设置页预览即时刷新，不受合并影响。
        metricsRebuildTask?.cancel()
        metricsRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            guard !Task.isCancelled, let self else { return }
            self.refreshAfterLayoutChange()
            if self.isSettingsPresented {
                self.positionSettingsWindow()
            }
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
            stale.islandPanel.orderOut(nil)
        }

        // 为新接入的屏幕创建面板对。
        for screen in screens where !pairs.contains(where: { $0.screen === screen }) {
            let pair = ScreenPanelPair(screen: screen) { Self.configurePanel($0) }
            wirePairEvents(pair)
            pairs.append(pair)
        }

        // 各自定位紧凑热区与活动岛；展开中的那块同时定位抽屉。
        for pair in pairs {
            positionCompactPanel(pair)
            syncIslandPanel(pair)
        }
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

    func updateScreenConstraint() {
        let width = pairs.first?.screenFrame.width ?? 1440
        layoutEngine.updateScreenConstraint(width: width)
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
                layoutEngine.updateScreenConstraint(width: pair.screenFrame.width)
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
        activePair = pair
        layoutEngine.updateScreenConstraint(width: pair.screenFrame.width)

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
    }

    /// 收起态的可见面板尺寸：紧凑带宽度 × 0 内容高。
    private func collapsedPanelSize() -> CGSize {
        CGSize(width: compactStrip(for: activePair).windowWidth, height: 0)
    }

    private func setCollapsedSize() {
        uiState.isDrawerExpanded = false
        uiState.drawerWindowSize = collapsedPanelSize()
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
        rebuildContent(animated: animated)
        if isExpanded, let pair = activePair {
            pair.drawerPanel.setFrame(drawerFrame(for: pair), display: true)
        }
    }

    // MARK: - 几何

    /// 抽屉窗口内容尺寸（不含岛顶紧凑带），超出屏幕可用高度时封顶（文档 §5.3）。
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
        if let pair {
            let maxHeight = pair.screenFrame.height - 8 - pair.layout.compactHeight
            if size.height > maxHeight {
                size.height = maxHeight
            }
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
            maxHeight: maxDrawerHeight(for: pair)
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
            maxHeight: maxDrawerHeight(for: pair)
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

    /// 屏幕坐标处的当前页抽屉块。`scrollUsage` 是滑动切页让路的门控：
    /// `.none` 不让路、`.always` 无条件让路、`.horizontal` 经
    /// `DrawerScrollProbe` 核实横向溢出。
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

    /// 编辑操作提交后的刷新：内容 spring 重建，面板贴合内容。
    func refreshAfterEdit() {
        rebuildContent(animated: true)
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
}
