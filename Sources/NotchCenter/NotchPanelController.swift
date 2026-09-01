import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 宿主控制器

/// 核心控制器：刘海交互、窗口管理、插件生命周期编排、布局渲染（文档 §2.1 / §5 / §6 / §7）。
/// 每个连接的屏幕都有一套自己的面板；抽屉同一时刻只在鼠标所在的屏幕展开。
/// 窗口类型见 PanelWindows.swift；编辑模式与视图构建见 NotchPanelContent.swift；
/// 事件监听与收起协调见 NotchPanelInteraction.swift；调试支持见 NotchPanelDebugSupport.swift。
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

    /// 编辑模式。经 uiState 发布；编辑期间抽屉不会自动收起（与钉住无关，
    /// 固定按钮只反映用户的显式选择）。
    var isEditing: Bool {
        get { uiState.isEditing }
        set { uiState.isEditing = newValue }
    }

    /// 抽屉是否处于展开状态（纯控制器逻辑，不进 UI 状态）。
    private(set) var isExpanded = false

    /// 设置面板是否可见：可见期间抽屉常驻展开（不自动收起），面板贴挂在
    /// 抽屉下方并置顶（见 `showSettings` / `settingsWindowDidClose`）。
    /// 经 uiState 发布，抽屉顶栏提示标签据此显隐。
    var isSettingsPresented: Bool {
        get { uiState.isSettingsPresented }
        set { uiState.isSettingsPresented = newValue }
    }

    /// 设置面板停在「组件」页：该页期间抽屉保持编辑模式（拖进来的组件可
    /// 立即继续拖动 / 缩放 / 删除），离开该页或关闭面板时退出编辑模式。
    ///
    /// ⚠️ 权威来源约定：这个标志由 `setComponentsPageActive` 独占写入；
    /// 关闭面板或切走组件页时清零，避免之后切页时两个来源
    /// 对编辑态的判断打架。`isEditing` 是两者合并后的只读视图。
    var isEditingForComponentsPage = false

    var isRevealedForFileDrag = false
    /// 收起态进入编辑的等待期（揭示 → 编辑两段式之间）：悬停判定视为停留。
    ///
    /// 两段式存在的原因：窗口固定满高，揭示（收起尺寸 → 全尺寸）与编辑
    /// 高度变化共用 `uiState.drawerWindowSize` 这**唯一一条** spring 通道，
    /// 同帧叠加会让动画从中间值起跳。等待期内该标志必须参与收起守卫
    /// （`DrawerStayConditions`）——漏判会让揭示在中途被收起。
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
            self.rebuildContent()
        }

        // 注入拖拽协调器：设置面板的组件拖拽由此处的落点命中测试接管。
        BlockDragCoordinator.shared.controller = self

        syncScreens()
        updateScreenConstraint()
        observeGridMetricsChanges()

        // 启用状态恢复（文档 §5.4）：layout.json 记录 enabledPluginIDs。
        if layoutEngine.didLoadFromDisk {
            pluginManager.restoreEnabledState(from: layoutEngine.enabledPluginIDs)
        } else {
            seedDefaultLayout()
        }

        // 首建/恢复后的 pairs 持默认 0 图标数：先同步紧凑区几何
        // （带宽、热区窗口随图标数伸缩），再重建内容。
        refreshCompactGeometry()
        rebuildContent()
        startMousePolling()
        observeScreenChanges()
        observeGlobalMouseEvents()
        observeMenuTracking()
    }

    /// 网格指标（单元大小 / 间隔 / 内边距）变化后重建内容：抽屉几何全部
    /// 由 `NotchGridMetrics` 推导，尺寸变化必须走一次完整重建，设置面板
    /// 也要跟着重新贴挂到新的抽屉底缘。
    @objc private func gridMetricsDidChange(_ notification: Notification) {
        // 滑杆拖动会逐格发通知（每格一次全量重建 + 窗口重排）。全量重建合并
        // 到停顿 100ms 后执行一次；store 侧每格仍即时持久化，设置页预览
        // （GridMetricsPreview 等）走 objectWillChange 即时刷新，不受合并影响。
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

        // 移除已断开屏幕的面板对（NSScreen 实例在部分显示重配后会换新身份，
        // 同一物理屏也会命中此路径）。窗口不会随 pair 移除自动隐藏，残留的
        // 常置顶面板会与新 pair 叠影，必须显式收回。
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

    /// 把某屏幕的紧凑面板摆到其刘海位置（宽度随当前紧凑图标数伸缩，
    /// 由 `refreshCompactGeometry` 在图标增删/换屏时调用）。
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

    /// 当前紧凑图标数（唯一来源：布局引擎模型；各 pair 的镜像与
    /// `uiState.compactCount` 经 `refreshCompactGeometry` 同步）。
    var compactIconCount: Int { layoutEngine.compactSlots.count }

    /// 某屏幕（或回退主屏）在当前图标数下的紧凑条带几何。
    /// 面板/命中测试/收起尺寸都通过这里取带宽，不再各自读引擎。
    func compactStrip(for pair: ScreenPanelPair?) -> CompactStripLayout {
        if let pair { return pair.compactStrip }
        return primaryLayout().compactStrip(slotCount: compactIconCount)
    }

    /// 紧凑区几何同步：把引擎的紧凑图标数推到各 pair 镜像与 `uiState`
    /// （视图侧条带宽度随其伸缩），并按新带宽重摆热区窗口。
    /// 任何**改变紧凑图标数**的路径必须先调它、再调 `rebuildContent`
    /// （后者保持纯内容重建，不再有窗口副作用）；宽度未变化时
    /// `setFrame` 同 frame 无副作用。
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
        // 兜底同步（启动/唤起时计数未变则无副作用），保证收起带宽对应当前图标数。
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
        rebuildContent()
        positionCompactPanel(pair)
        // 参考codex-island：窗口固定尺寸，只上线不动画；可见面板经
        // `drawerWindowSize`（唯一动画真源）从紧凑带 spring 变形到全尺寸。
        pair.drawerPanel.setFrame(drawerFrame(for: pair), display: true)
        // 自愈：其他屏可能残留跨屏竞态的抽屉窗口（收起完成回调前又在
        // 别屏展开），一并收回。
        hideOtherDrawers(keeping: pair)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            pair.drawerPanel.makeKeyAndOrderFront(nil)
        } else {
            pair.drawerPanel.orderFrontRegardless()
        }
        setDrawerRevealed(true, animated: animated)
    }

    /// 抽屉单例不变量：任一时刻至多一个屏的抽屉窗口在屏（当前展开屏的）。
    /// 收起完成回调有 0.43s 窗口，期间在另一块屏重新展开会绕过旧 pair 的
    /// orderOut；残留窗口与活动屏共享 uiState，会渲染出一份一模一样的
    /// 活抽屉（“新建笔记多出一块面板”的根因）。
    private func hideOtherDrawers(keeping kept: ScreenPanelPair?) {
        for pair in pairs where pair !== kept {
            pair.drawerPanel.orderOut(nil)
        }
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        isExpanded = false
        isRevealedForFileDrag = false
        if isEditing {
            isEditing = false
        }
        // 抽屉消失后进行中的拖拽会话与落位飞行都失去意义：立即收尾，
        // 否则浮窗会悬在空气里、新块可能卡在隐形状态（landingPlacementID）。
        BlockDragCoordinator.shared.cancel()
        DragPreviewLanding.shared.cancel()
        setDrawerRevealed(false, animated: animated)
        // 浮窗锚定的块随抽屉消失：Kit 的 BlockPopover 订阅此通知立即关闭，
        // 不等收起动画结束（否则浮窗悬在已消失的块上方）。
        NotificationCenter.default.post(name: .notchCenterDrawerDidCollapse, object: nil)
        let completion = { [weak self] in
            guard let self else { return }
            // 等待期内可能再次展开（同屏返回，或移到了另一块屏）：只保留
            // 当前展开屏的抽屉，其余屏（含本次收起的屏）一律收回。不能
            // 因“已重新展开”整体跳过——跨屏再展开时上一块屏的抽屉会
            // 永久残留。
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

    /// 展开/收起 = `drawerWindowSize`（model.size 模式）在紧凑带尺寸与
    /// 完整抽屉尺寸之间的 withAnimation 变形；容器 frame 绑定它随之
    /// spring 缩放，窗口 frame 不参与（固定满高）。
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
        // 先无动画贴到起点（rebuildContent 可能已把尺寸写成全量），再在
        // 同一节拍内 spring 到目标——用户看到的是从紧凑带“长出”。
        // 只有展开需要贴起点；收起的起点就是当前（全量）尺寸：若也在
        // 这里无动画写成目标，收起会瞬跳到紧凑带，且过渡中布局错位
        // （图标下坠），easeOut(0.16) 收起动画也随之丢失。
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

    /// 收起态的可见面板尺寸：紧凑带宽度（随当前图标数）× 0 内容高
    /// （容器总高 = 带高）。
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
    func refreshAfterLayoutChange() {
        rebuildContent()
        if isExpanded, let pair = activePair {
            pair.drawerPanel.setFrame(drawerFrame(for: pair), display: true)
        }
    }

    // MARK: - 几何

    /// 抽屉窗口内容尺寸（不含岛顶紧凑带）：布局内容增高；超出屏幕可用
    /// 高度时封顶（网格 ScrollView 可视高度随之压缩，文档 §5.3）。
    /// 与 `DrawerPanelView` 根视图共享该尺寸，保证布局一致。
    /// `previewRows` 用于拖拽/缩放预览（按预览布局的最低行临时增高）；
    /// `previewColumns` 同理（按预览布局的实际占用列数临时增宽）；
    /// `page` 缺省 = 当前激活页（滑动切页的尺寸插值终点按目标页取）。
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

    /// 抽屉窗口（方案 E：固定满高满宽）：顶缘钉死屏幕顶端，高度一次摆到
    /// 屏高上限；宽度固定为屏幕能容纳的最大列数。可见面板尺寸
    /// （`drawerWindowSize`）随实际占用列数自适应收缩并在窗口内水平居中，
    /// 窗口比可见面板宽的部分是透明区（命中测试由 `DrawerHostingView`
    /// 可见矩形限定 + `ignoresMouseEvents` 光标跟踪双机制穿透）。
    /// 窗口 frame 不跟随内容宽度动画——跟随会导致宽度变化期间裁剪
    /// spring 变形中的内容、面板偏离屏幕中线。
    private func drawerFrame(for pair: ScreenPanelPair) -> NSRect {
        let screenFrame = pair.screenFrame
        let width = NotchGridMetrics.contentWidth(columns: layoutEngine.effectiveMaxColumns())
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

    /// 拖拽/缩放预览期间面板按需增高/增宽（方案 E：纯 SwiftUI）：只更新
    /// `uiState.drawerWindowSize`，遮罩/内容即时随预览布局的最低行与
    /// 列跨度扩展（窗口高度固定，无需任何 frame 操作）；提交后由
    /// `refreshAfterEdit` 的 spring 回落到压实尺寸。`resized` 为正在缩放
    /// 块的新跨度（底层块长高/加宽时唯一能反映变化的来源）。
    ///
    /// 尺寸变化与块推挤同帧完成（不等松手）：`drawerWindowSize`、
    /// `drawerContentSize`（网格容器实时更新）与 `drawerGridLeftColumn`
    /// （左扩渲染偏移）在一次 withAnimation 里更新——与视图内推挤预览
    /// 使用同一 spring，面板扩大、容器扩展与其余块推挤动画同步起效。
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
            // 容器高度随预览最低行同步更新：若高度仍钉在提交布局的旧行高，
            // 缩小时网格内容会高过可视区，ScrollView 反复亮起滚动条。
            uiState.drawerContentSize = metrics.contentSize
            guard uiState.drawerWindowSize != metrics.windowSize else { return }
            uiState.drawerWindowSize = metrics.windowSize
        }
    }

    /// 拖拽**落点预览**期间的面板增高/增宽：只按「占位框 ∪ 提交布局」的
    /// 并集扩展，**绝不写 `drawerGridLeftColumn`**——所有块的渲染横坐标都
    /// 减左列，改左列等于让全体块横移，与「拖动期间其余块零位移」直接
    /// 冲突；也不写推挤预览原点（`DrawerInteractionState.previewOrigins`）。
    ///
    /// 与 `applyPreviewWindowSize` 的分工就在这里：后者服务**块已被推挤**
    /// 的预览（缩放/抽屉内重排，可以重算左列），本方法服务**块还没动、
    /// 只有占位框**的预览（从设置面板拖入）。
    ///
    /// 顺带修掉一个既有缺陷：网格内容高度（`gridFrameHeight`）虽已计入
    /// 落点行，但窗口可见高度没跟着长，落点落在新行时占位框会被
    /// ScrollView 裁掉。
    ///
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
        // 值未变直接返回：拖动中每帧都调用，重复赋值会不断重启 spring
        // （表现为面板尺寸抖动）。
        guard uiState.drawerWindowSize != metrics.windowSize
                || uiState.drawerContentSize != metrics.contentSize else { return }
        // 内容尺寸与窗口尺寸必须同相同帧，否则 ScrollView 会反复亮灭滚动条。
        // 注意这里**不写** `drawerGridLeftColumn`——`metrics.leftColumn`
        // 为 nil 正是这个约束的类型化表达。
        withAnimation(DrawerAnimation.spring) {
            uiState.drawerContentSize = metrics.contentSize
            uiState.drawerWindowSize = metrics.windowSize
        }
    }

    /// 网格内容 ↔ 屏幕的换算桥：格 → 屏幕（`drawerScreenRect`）与
    /// 屏幕 → 格（`BlockDropTargeting.dropZone`）**共用同一份**，互逆性由
    /// `DrawerScreenMapper` 的结构保证（同一表达式的正逆），不再靠
    /// "两处改同一套常量"的注释约定。
    ///
    /// 跟手浮窗的落位终点若与占位框差一格，飞行结束时会看到一次明显跳动。
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

    /// 屏幕坐标是否落在**当前激活页**的任一抽屉块上。
    /// 格 → 屏幕走 `drawerScreenMapper`，与占位框、落点判定同一份换算。
    func isPointOverDrawerBlock(_ screenPoint: NSPoint) -> Bool {
        drawerElement(at: screenPoint) != nil
    }

    /// 屏幕坐标处的当前页抽屉块。`scrollUsage`（插件声明的横向滑动消费）是
    /// 滑动切页的让路判据——只有声明 `.horizontal` 的块才让路，其余块上
    /// 滑动照常切页（见 `NotchPanelContent.handleDrawerScroll`）。
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

    /// 屏幕横坐标 → 紧凑带内容坐标（各屏的槽位布局一致，热区窗口与抽屉
    /// 可见面板共用这条换算）。
    func compactContentX(_ screenX: CGFloat, pair: ScreenPanelPair) -> CGFloat {
        screenX - pair.hotFrame.minX
    }

    /// 网格格坐标 → 屏幕矩形（Cocoa 坐标，左下原点）。
    ///
    /// 面板布局链（见 `DrawerPanelView.content` / `body`）：
    /// 可见面板 = 紧凑带(`compactHeight`) + 顶栏(`drawerTopBarHeight`) +
    /// 网格（水平内边距 `contentPadding`），顶缘钉死屏幕顶端。
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

    /// 落位飞行的终点：某块**提交后**的最终屏幕矩形。
    /// 必须用提交后的几何算——面板宽度与最左列都可能因落位而改变，
    /// 用拖动时的旧几何会让终点偏离真实块几 pt 到一整格。
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

    /// 编辑操作提交后的刷新：内容 spring 重建（窗口高度固定，
    /// 无空行、面板贴合内容）。
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
