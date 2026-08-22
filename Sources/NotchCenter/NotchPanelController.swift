import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 窗口类型

@MainActor
final class NotchPanel: NSPanel {
    var onMouseEvent: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // 只拦截“裸” Escape：输入法用户需要 Esc 取消编辑器中的 marked text，
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

// MARK: - 宿主控制器

/// 核心控制器：刘海交互、窗口管理、插件生命周期编排、布局渲染（文档 §2.1 / §5 / §6 / §7）。
/// 每个连接的屏幕都有一套自己的面板；抽屉同一时刻只在鼠标所在的屏幕展开。
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
    private var isPinned: Bool {
        get { uiState.isPinned }
        set { uiState.isPinned = newValue }
    }

    /// 编辑模式。经 uiState 发布；编辑期间抽屉不会自动收起（与钉住无关，
    /// 固定按钮只反映用户的显式选择）。
    private(set) var isEditing: Bool {
        get { uiState.isEditing }
        set { uiState.isEditing = newValue }
    }

    /// 抽屉是否处于展开状态（纯控制器逻辑，不进 UI 状态）。
    private(set) var isExpanded = false

    private var isRevealedForFileDrag = false
    private var activeMenuTrackingCount = 0
    private var collapseTask: DispatchWorkItem?
    private var mousePollingTimer: Timer?
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var pluginManagerWindowController: PluginManagerWindowController?

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

        syncScreens()
        updateScreenConstraint()

        // 启用状态恢复（文档 §5.4）：layout.json 记录 enabledPluginIDs。
        if layoutEngine.didLoadFromDisk {
            pluginManager.restoreEnabledState(from: layoutEngine.enabledPluginIDs)
        } else {
            seedDefaultLayout()
        }

        rebuildContent()
        startMousePolling()
        observeScreenChanges()
        observeGlobalMouseEvents()
        observeMenuTracking()
    }

    // MARK: - 多屏幕管理（文档 §6.3：每个屏幕单独显示一个 NotchCenter）

    /// 同步屏幕与面板对：新屏幕创建、断开的屏幕移除，并重新定位全部面板。
    private func syncScreens() {
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens

        // 移除已断开屏幕的面板对。
        pairs.removeAll { pair in !screens.contains { $0 === pair.screen } }

        // 为新接入的屏幕创建面板对。
        for screen in screens where !pairs.contains(where: { $0.screen === screen }) {
            let pair = ScreenPanelPair(screen: screen) { Self.configurePanel($0) }
            wirePairEvents(pair)
            pairs.append(pair)
        }

        // 各自定位紧凑热区；展开中的那块同时定位抽屉。
        for pair in pairs {
            positionCompactPanel(pair)
        }
        if let active = activePair, isExpanded {
            active.drawerPanel.setFrame(drawerFrame(for: active), display: true)
        }

        if activePair == nil || !pairs.contains(where: { $0 === activePair }) {
            activePair = pairs.first
        }
    }

    /// 把某屏幕的紧凑面板摆到其刘海位置。
    private func positionCompactPanel(_ pair: ScreenPanelPair) {
        pair.hotPanel.setFrame(pair.hotFrame, display: true)
        pair.hotPanel.orderFrontRegardless()
    }

    /// 主屏布局（用于共享渲染内容；窗口几何按各屏自身计算）。
    private func primaryLayout() -> NotchLayout {
        NotchGeometry.layout(for: pairs.first?.screen)
    }

    /// 鼠标所在屏幕的面板对；不在任何激活区时返回 nil。
    private func pairContainingLocation(_ point: NSPoint) -> ScreenPanelPair? {
        pairs.first { $0.hotFrame.contains(point) }
    }

    private func updateScreenConstraint() {
        let width = pairs.first?.screenFrame.width ?? 1440
        layoutEngine.updateScreenConstraint(width: width)
    }

    // MARK: - 对外入口

    func showDocked() {
        rebuildContent()
        isExpanded = false
        uiState.revealProgress = 0
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
        // 窗口直接摆到最终尺寸，“从刘海展开”由视图内遮罩插值完成
        // （沿用 NotchNotes 的 DrawerState.revealProgress 方案）。
        #if DEBUG
        if ResizeProbeLog.isEnabled {
            NSLog("expand setFrame -> %@ (isEditing=%@)", NSStringFromRect(drawerFrame(for: pair)), String(describing: isEditing))
        }
        #endif
        pair.drawerPanel.setFrame(drawerFrame(for: pair), display: true)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            uiState.revealProgress = 0
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            pair.drawerPanel.makeKeyAndOrderFront(nil)
        } else {
            pair.drawerPanel.orderFrontRegardless()
        }
        setDrawerRevealed(true, animated: animated)
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        isExpanded = false
        isRevealedForFileDrag = false
        if isEditing {
            isEditing = false
        }
        setDrawerRevealed(false, animated: animated)
        let pair = activePair
        let completion = { [weak self] in
            guard let self, !self.isExpanded else { return }
            pair?.drawerPanel.orderOut(nil)
            positionCompactPanel(pair!)
        }
        if animated {
            // 与 easeOut(0.16) 收起动画匹配，等遮罩缩回刘海再隐藏窗口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: completion)
        } else {
            completion()
        }
    }

    /// 灵动岛式展开/收起：动画 revealProgress，视图内遮罩随之缩放
    /// （展开 spring、收起 easeOut，参数与旧版 NotchNotes 一致）。
    private func setDrawerRevealed(_ revealed: Bool, animated: Bool) {
        uiState.isDrawerExpanded = revealed
        guard animated else {
            uiState.revealProgress = revealed ? 1 : 0
            return
        }
        withAnimation(revealed ? .spring(response: 0.28, dampingFraction: 0.86) : .easeOut(duration: 0.16)) {
            uiState.revealProgress = revealed ? 1 : 0
        }
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

    // MARK: - HostController（文档 §4.5）

    /// 首启默认布局：启用全部内置插件，紧凑 3 槽放官方紧凑块，抽屉自动放置官方抽屉块，
    /// 让首次启动即可看到面板内容（空布局对用户不直观）。
    private func seedDefaultLayout() {
        layoutEngine.seedEnabledBuiltIns(pluginManager.builtInPluginIDs)
        pluginManager.restoreEnabledState(from: layoutEngine.enabledPluginIDs)

        let enabledEntries = pluginManager.entries.filter { entry in
            entry.metadata.isBuiltIn
                && layoutEngine.enabledPluginIDs.contains(entry.id)
                && entry.instance != nil
        }

        for entry in enabledEntries {
            for block in entry.blocks where block.kind == .compact {
                _ = layoutEngine.addCompactBlock(pluginID: entry.id, blockID: block.id)
            }
        }
        for entry in enabledEntries {
            for block in entry.blocks where block.kind == .drawer {
                _ = layoutEngine.autoPlaceDrawerBlock(pluginID: entry.id, blockID: block.id)
            }
        }
    }

    /// 由 HostController.enterEditMode / 视图动作调用。
    /// 收起态进入时先完整展开（普通小揭示），揭示完成后再进入编辑：
    /// 揭示与高度增长串行，各自走已验证路径——两者叠加是首次进入特有
    /// 异常（宿主视图刚上线、preference 跟随未参与）的来源。
    /// 不要改成叠加（同帧翻转 isEditing）或“先置编辑再 expand”（收起态
    /// 直接向编辑终高大揭示，每次进入都有显眼的顶部展开）。
    func startEditMode() {
        if !isExpanded {
            expand(animated: true, activate: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                self?.applyEditMode()
            }
        } else {
            applyEditMode()
        }
    }

    /// 进入编辑状态的内容过渡（内容 spring 增高、窗口由跟随器贴合）。
    private func applyEditMode() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            isEditing = true
        }
        rebuildContent(animated: true)
    }

    /// 由 HostController.exitEditMode / 视图动作调用。
    /// 高度收缩由内容 spring + 窗口逐帧跟随完成（syncDrawerFrame）。
    func stopEditMode() {
        guard isEditing else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            isEditing = false
        }
        rebuildContent(animated: true)
        if !isPinned {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    // MARK: - 视图构建

    /// 刷新面板内容：把布局与元素写入 `uiState`（@Published 驱动 SwiftUI 刷新），
    /// 所有屏幕的宿主视图共享同一份状态。宿主视图只创建一次，之后不再重新赋值
    /// rootView——在透明无边框 NSPanel 上 rootView 重赋值不能保证立即重绘。
    /// `animated: true` 时状态变化套 spring（编辑模式目录条/窗口高度过渡）。
    private func rebuildContent(animated: Bool = false) {
        // 紧凑元素的上下文 frame 以主屏几何近似（槽位尺寸跨屏一致，
        // 视觉几何由各面板的 layout 参数精确持有）。
        let contextLayout = primaryLayout()
        let catalogPlugins = buildCatalogPlugins()

        let apply = {
            self.uiState.showsClickModeHint = self.settingsStore.triggerMode == .click
            self.uiState.compactElements = self.buildCompactElements(layout: contextLayout)
            self.uiState.canAddCompact = self.layoutEngine.compactSlots.contains(where: { $0 == nil })

            self.uiState.drawerContentSize = self.layoutEngine.drawerContentSize()
            // 目录先就位，窗口尺寸才能计入 AddBlock 区域高度。
            self.uiState.catalogPlugins = catalogPlugins
            self.uiState.drawerWindowSize = self.drawerWindowSize(for: self.activePair ?? self.pairs.first)
            self.uiState.drawerElements = self.buildDrawerElements()
        }
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                apply()
            }
        } else {
            apply()
        }

        for pair in pairs {
            buildViewsIfNeeded(pair)
            // 显式标记重绘：应用未激活时也保证状态变化立即上屏。
            pair.hotHostingView?.needsDisplay = true
            pair.drawerHostingView?.needsDisplay = true
        }
    }

    /// 为某个屏幕的面板对创建宿主视图（每屏一份，共享 uiState）。
    /// 紧凑带几何按所属屏幕传入：外接屏回退与内建屏实测刘海的宽度/槽位
    /// 布局不同，视图不得读共享的主屏几何。
    private func buildViewsIfNeeded(_ pair: ScreenPanelPair) {
        if pair.hotHostingView == nil {
            let host = TransparentHitHostingView(
                rootView: CompactPanelView(
                    ui: uiState,
                    layout: pair.layout,
                    actions: compactActions()
                )
            )
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            pair.hotPanel.contentView = host
            pair.hotHostingView = host
        }

        if pair.drawerHostingView == nil {
            let host = FirstMouseHostingView(
                rootView: DrawerPanelView(
                    ui: uiState,
                    layout: pair.layout,
                    // 岛顶嵌入紧凑区（不自绘底衬）：展开后刘海带与抽屉一体呈现。
                    compactView: CompactPanelView(
                        ui: uiState,
                        layout: pair.layout,
                        actions: compactActions(),
                        showsBand: false
                    ),
                    actions: drawerActions(),
                    onContentSizeChange: { [weak self, weak pair] size in
                        self?.syncDrawerFrame(toContentSize: size, pair: pair)
                    }
                )
            )
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            pair.drawerPanel.contentView = host
            pair.drawerHostingView = host
        }
    }

    private func buildCompactElements(layout: NotchLayout) -> [CompactElement] {
        (0..<NotchGeometry.compactSlotCount).map { index in
            let frame = compactSlotFrame(index: index, layout: layout)
            guard let reference = layoutEngine.compactSlot(at: index),
                  let entry = pluginManager.entry(for: reference.pluginID),
                  entry.isEnabled,
                  let block = pluginManager.block(pluginID: reference.pluginID, blockID: reference.blockID),
                  block.kind == .compact,
                  let store = entry.stateStore else {
                return CompactElement(
                    slotIndex: index,
                    reference: nil,
                    block: nil,
                    view: nil,
                    frame: frame
                )
            }
            let context = BlockContext(
                pluginID: reference.pluginID,
                blockID: reference.blockID,
                placementID: reference.placementID,
                stateStore: store,
                hostController: self,
                layoutInfo: BlockLayoutInfo(
                    region: .compact,
                    placementID: reference.placementID,
                    frame: frame,
                    isEditing: isEditing,
                    compactSlotIndex: index
                )
            )
            return CompactElement(
                slotIndex: index,
                reference: reference,
                block: block,
                view: block.makeView(context),
                frame: frame
            )
        }
    }

    private func buildDrawerElements() -> [DrawerElement] {
        layoutEngine.drawerBlocks.compactMap { placement in
            guard let entry = pluginManager.entry(for: placement.pluginID),
                  entry.isEnabled,
                  let block = pluginManager.block(pluginID: placement.pluginID, blockID: placement.blockID),
                  block.kind == .drawer,
                  let store = entry.stateStore else {
                return nil
            }
            let frame = layoutEngine.frame(for: placement)
            let currentSpan = GridSpan(columns: placement.widthColumns, rows: placement.heightRows)
            let context = BlockContext(
                pluginID: placement.pluginID,
                blockID: placement.blockID,
                placementID: placement.placementID,
                stateStore: store,
                hostController: self,
                layoutInfo: BlockLayoutInfo(
                    region: .drawer,
                    placementID: placement.placementID,
                    frame: frame,
                    size: nil,
                    originColumn: placement.originColumn,
                    originRow: placement.originRow,
                    widthColumns: placement.widthColumns,
                    heightRows: placement.heightRows,
                    isEditing: isEditing
                )
            )
            return DrawerElement(
                placement: placement,
                view: block.makeView(context),
                supportedSpans: block.supportedSpans.sorted { lhs, rhs in
                    lhs.columns == rhs.columns ? lhs.rows < rhs.rows : lhs.columns < rhs.columns
                },
                currentSpan: currentSpan
            )
        }
    }

    private func buildCatalogPlugins() -> [CatalogPluginGroup] {
        pluginManager.entries
            .filter { $0.isEnabled && $0.instance != nil }
            .compactMap { entry -> CatalogPluginGroup? in
                // AddBlock 目录同时列紧凑块（上栏）与抽屉块（下栏）；
                // 两者皆无的插件不出现，避免空分组。
                let compactBlocks = entry.blocks.filter { $0.kind == .compact }
                let drawerBlocks = entry.blocks.filter { $0.kind == .drawer }
                guard !compactBlocks.isEmpty || !drawerBlocks.isEmpty else { return nil }
                return CatalogPluginGroup(
                    pluginID: entry.id,
                    displayName: entry.metadata.displayName,
                    compactBlocks: compactBlocks,
                    drawerBlocks: drawerBlocks
                )
            }
    }

    /// 槽位矩形（窗口内容坐标，左上原点）；与视图共享同一 strip 布局。
    private func compactSlotFrame(index: Int, layout: NotchLayout) -> CGRect {
        layout.compactStrip.slotRect(at: index) ?? .zero
    }

    private func compactActions() -> CompactActions {
        CompactActions(
            onRemoveBlock: { [weak self] index in
                self?.layoutEngine.setCompactSlot(index, to: nil)
                self?.rebuildContent()
            },
            onTapBackground: { [weak self] in
                self?.expand(animated: true, activate: true)
            },
            onExpand: { [weak self] in
                self?.expand(animated: true, activate: true)
            }
        )
    }

    private func drawerActions() -> DrawerActions {
        DrawerActions(
            onTogglePin: { [weak self] in
                guard let self else { return }
                self.isPinned.toggle()
                // 立即重建：顶部按钮（钉住图标）与实际状态保持一致。
                self.rebuildContent()
                if !self.isPinned, !self.isEditing {
                    self.handleMouseLocation(NSEvent.mouseLocation)
                }
            },
            onToggleEdit: { [weak self] in
                guard let self else { return }
                if self.isEditing {
                    self.stopEditMode()
                } else {
                    self.startEditMode()
                }
            },
            onCollapse: { [weak self] in
                self?.collapse(animated: true)
            },
            onRemoveBlock: { [weak self] placementID in
                self?.layoutEngine.removeDrawerBlock(placementID: placementID)
                self?.refreshAfterEdit()
            },
            onMoveBlock: { [weak self] placementID, column, row in
                self?.layoutEngine.moveDrawerBlock(placementID: placementID, toColumn: column, toRow: row)
                self?.refreshAfterEdit()
            },
            onResizeBlock: { [weak self] placementID, columns, rows in
                self?.layoutEngine.resizeDrawerBlock(placementID: placementID, toColumns: columns, toRows: rows)
                self?.refreshAfterEdit()
            },
            onAddBlock: { [weak self] pluginID, blockID in
                guard let self else { return }
                if let block = self.pluginManager.block(pluginID: pluginID, blockID: blockID),
                   block.kind == .compact {
                    self.layoutEngine.addCompactBlock(pluginID: pluginID, blockID: blockID)
                } else {
                    self.layoutEngine.autoPlaceDrawerBlock(pluginID: pluginID, blockID: blockID)
                }
                self.refreshAfterEdit()
            },
            onReorderBlocks: { [weak self] in
                self?.layoutEngine.reorderDrawerBlocks()
                self?.refreshAfterEdit()
            },
            onPreviewMove: { [weak self] placementID, column, row in
                guard let self else { return [:] }
                let origins = self.layoutEngine.previewArrangement(
                    moving: placementID,
                    toColumn: column,
                    toRow: row
                )
                self.applyPreviewWindowSize(origins)
                return origins
            },
            onPreviewResize: { [weak self] placementID, columns, rows in
                guard let self else { return [:] }
                let origins = self.layoutEngine.previewArrangement(
                    resizing: placementID,
                    toColumns: columns,
                    toRows: rows
                )
                // 底层块长高不推挤任何人：新行数必须显式传入才会增高面板。
                self.applyPreviewWindowSize(origins, resized: (placementID, rows))
                return origins
            },
            onCommitDrag: { [weak self] placementID, column, row in
                guard let self else { return }
                let origins = self.layoutEngine.previewArrangement(
                    moving: placementID,
                    toColumn: column,
                    toRow: row
                )
                _ = self.layoutEngine.commitArrangement(origins)
                self.refreshAfterEdit()
            }
        )
    }

    // MARK: - 面板配置与事件

    private static func configurePanel(_ panel: NotchPanel) {
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

    /// 接入每个屏幕面板对的交互事件（点击展开、Escape 收起等）。
    private func wirePairEvents(_ pair: ScreenPanelPair) {
        pair.hotPanel.onMouseEvent = { [weak self, weak pair] event in
            guard let self, let pair else { return }
            guard event.type == .leftMouseDown else { return }
            // 块视图自身处理点击；仅当点击落在槽位之外才视为面板级展开。
            let location = NSEvent.mouseLocation
            if !self.isPointInAnyCompactSlot(location, layout: pair.layout, hotFrame: pair.hotFrame) {
                self.expand(animated: true, activate: true)
            }
        }

        pair.drawerPanel.onMouseEvent = { [weak pair] event in
            guard event.type == .leftMouseDown else { return }
            NSApp.activate(ignoringOtherApps: true)
            pair?.drawerPanel.makeKeyAndOrderFront(nil)
        }

        pair.hotPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
        pair.drawerPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
    }

    private func observeGlobalMouseEvents() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      !self.isExpanded,
                      self.settingsStore.triggerMode == .click,
                      self.pairContainingLocation(NSEvent.mouseLocation) != nil else {
                    return
                }
                self.expand(animated: true, activate: true)
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRevealedForFileDrag = false
                let location = NSEvent.mouseLocation
                if self.isExpanded {
                    self.handleMouseLocation(location)
                }
            }
        }
    }

    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func startMousePolling() {
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(mousePollingTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        mousePollingTimer = timer
    }

    @objc private func mousePollingTick(_ timer: Timer) {
        handleMouseLocation(NSEvent.mouseLocation)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        cancelCollapse()
        syncScreens()
        updateScreenConstraint()
        rebuildContent()
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        activeMenuTrackingCount += 1
        cancelCollapse()
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        activeMenuTrackingCount = max(0, activeMenuTrackingCount - 1)
        guard activeMenuTrackingCount == 0 else { return }
        handleMouseLocation(NSEvent.mouseLocation)
    }

    // MARK: - 展开/收起协调（文档 §6）

    private func handleMouseLocation(_ point: NSPoint) {
        if !isExpanded {
            if isFileDrag(at: point) {
                if !isRevealedForFileDrag {
                    isRevealedForFileDrag = true
                    expand(animated: true, activate: false)
                }
                return
            }

            if settingsStore.triggerMode == .hover,
               NSEvent.pressedMouseButtons & 1 == 0,
               pairContainingLocation(point) != nil {
                expand(animated: true, activate: false)
            }
            return
        }

        // 已展开。
        if activeMenuTrackingCount > 0 {
            cancelCollapse()
            return
        }
        if isEditing || isPinned {
            cancelCollapse()
            return
        }
        if settingsStore.triggerMode == .click {
            cancelCollapse()
            return
        }
        if isPointInExpandedStayRegion(point) {
            cancelCollapse()
        } else {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        guard activeMenuTrackingCount == 0 else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseTask = nil
            guard self.activeMenuTrackingCount == 0 else { return }
            guard !self.isEditing, !self.isPinned else { return }
            guard !self.isPointInExpandedStayRegion(NSEvent.mouseLocation) else { return }
            self.collapse(animated: true)
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    /// 停留区域：当前抽屉窗口附近，或任一屏幕的紧凑热区。
    private func isPointInExpandedStayRegion(_ point: NSPoint) -> Bool {
        let margin: CGFloat = 10
        if let frame = activePair?.drawerPanel.frame,
           frame.insetBy(dx: -margin, dy: -margin).contains(point) {
            return true
        }
        return pairs.contains { $0.hotFrame.contains(point) }
    }

    private func isPointInAnyCompactSlot(_ point: NSPoint, layout: NotchLayout, hotFrame: NSRect) -> Bool {
        let slots = (0..<NotchGeometry.compactSlotCount).map { index -> NSRect in
            let slot = compactSlotFrame(index: index, layout: layout)
            // 槽位 frame 是内容坐标（左上原点）；换算到屏幕坐标。
            return NSRect(
                x: hotFrame.minX + slot.minX,
                y: hotFrame.maxY - slot.maxY,
                width: slot.width,
                height: slot.height
            )
        }
        return slots.contains { $0.contains(point) }
    }

    private func isFileDrag(at point: NSPoint) -> Bool {
        guard NSEvent.pressedMouseButtons & 1 == 1,
              FileDragDetector.containsFileURLs(NSPasteboard(name: .drag)) else {
            return false
        }
        return pairContainingLocation(point) != nil
    }

    // MARK: - 几何

    /// 抽屉窗口内容尺寸（不含岛顶紧凑带）：布局内容 + 编辑模式 AddBlock
    /// 区域增高；超出屏幕可用高度时封顶（网格 ScrollView 可视高度随之压缩，
    /// 文档 §5.3）。与 `DrawerPanelView` 根视图共享该尺寸，保证布局一致。
    /// `previewRows` 用于拖拽/缩放预览（按预览布局的最低行临时增高）。
    private func drawerWindowSize(for pair: ScreenPanelPair?, previewRows: Int? = nil) -> CGSize {
        var size = layoutEngine.drawerWindowSize(contentRows: previewRows)
        if isEditing {
            size.height += AddBlockArea.height(for: uiState.catalogPlugins)
        }
        if let pair {
            let maxHeight = pair.screenFrame.height - 8 - pair.layout.compactSize.height
            if size.height > maxHeight {
                size.height = maxHeight
            }
        }
        return size
    }

    /// 窗口作为内容几何的逐帧跟随者：`DrawerPanelView` 经 preference 上报
    /// 实际渲染尺寸（含 spring 动画的每一帧），窗口 frame 直接贴合（顶缘
    /// 钉死屏幕顶端、底缘与内容严丝合缝）——窗口与内容共用同一
    /// SwiftUI spring。注意：沙箱化进程上 preference 不传播，诊断须在
    /// 非沙箱环境运行（此前在沙箱中误判为“不触发”并将其移除，导致
    /// 解析 spring 等替代方案的曲线/时钟偏差）。
    private func syncDrawerFrame(toContentSize contentSize: CGSize, pair: ScreenPanelPair?) {
        guard isExpanded, let pair, contentSize.height > 0, contentSize.width > 0 else { return }
        var size = contentSize
        size.height += pair.layout.compactSize.height
        let frame = NotchGeometry.topCenteredFrame(
            for: size,
            topY: pair.screenFrame.maxY,
            in: pair.screenFrame
        )
        guard pair.drawerPanel.frame != frame else { return }
        pair.drawerPanel.setFrame(frame, display: true)
    }

    /// 抽屉窗口：从屏幕顶端开始（包含刘海高度带的岛顶区域），
    /// 展开动画时遮罩从紧凑带尺寸放大到完整窗口，与刘海视觉融合。
    private func drawerFrame(for pair: ScreenPanelPair) -> NSRect {
        let screenFrame = pair.screenFrame
        var size = drawerWindowSize(for: pair)
        size.height += pair.layout.compactSize.height
        return NotchGeometry.topCenteredFrame(
            for: size,
            topY: screenFrame.maxY,
            in: screenFrame
        )
    }

    /// 拖拽/缩放预览期间面板按需增高：以预览布局的最低行为准直接设置窗口
    /// （紧跟指针、不做动画）；提交后由 `refreshAfterEdit` 的 spring 回落
    /// 到压实尺寸。`resized` 为正在缩放块的新行数（底层块长高时唯一能
    /// 反映增高的来源）。
    private func applyPreviewWindowSize(
        _ origins: [String: LayoutEngine.GridOrigin],
        resized: (placementID: String, heightRows: Int)? = nil
    ) {
        guard isExpanded, let pair = activePair, !origins.isEmpty else { return }
        let size = drawerWindowSize(
            for: pair,
            previewRows: layoutEngine.previewBottomRow(origins: origins, resized: resized)
        )
        guard uiState.drawerWindowSize != size else { return }
        uiState.drawerWindowSize = size
        var frameSize = size
        frameSize.height += pair.layout.compactSize.height
        pair.drawerPanel.setFrame(
            NotchGeometry.topCenteredFrame(
                for: frameSize,
                topY: pair.screenFrame.maxY,
                in: pair.screenFrame
            ),
            display: true
        )
    }

    /// 编辑操作提交后的刷新：内容 spring 重建，窗口按同参数解析 spring
    /// 贴合新高度（无空行、面板贴合内容）。
    private func refreshAfterEdit() {
        rebuildContent(animated: true)
    }

    // MARK: - 插件管理窗口

    /// 开发期调试：模拟点击钉住按钮（走与视图相同的动作路径）。
    func debugTogglePin() {
        drawerActions().onTogglePin()
    }

    /// 开发期调试：把所有屏幕的面板内容渲染为 PNG（无需屏幕录制权限）。
    func capturePanelsForDebug(suffix: String = "") {
        func writePNG(of view: NSView?, to path: String) {
            guard let view else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        for (index, pair) in pairs.enumerated() {
            let tag = pairs.count > 1 ? "\(suffix)_\(index)" : suffix
            writePNG(of: pair.hotPanel.contentView, to: "/tmp/nc_hot\(tag).png")
            writePNG(of: pair.drawerPanel.contentView, to: "/tmp/nc_drawer\(tag).png")
            print("debug[\(index)] \(pair.screen.localizedName) hot=\(pair.hotPanel.frame) drawer=\(pair.drawerPanel.frame)")
        }
        print("debug reveal=\(uiState.revealProgress) expanded=\(isExpanded) screens=\(pairs.count)")
        print("debug sizes: content=\(layoutEngine.drawerContentSize()) window=\(layoutEngine.drawerWindowSize()) blocks=\(layoutEngine.drawerBlocks.count)")
        let layout = primaryLayout()
        print("debug compact: layout.compact=\(layout.compactSize) notch=\(layout.notchSize)")
    }

    func showPluginManager() {
        let controller = pluginManagerWindowController ?? {
            let controller = PluginManagerWindowController(
                pluginManager: pluginManager,
                hostController: self
            )
            pluginManagerWindowController = controller
            return controller
        }()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
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
