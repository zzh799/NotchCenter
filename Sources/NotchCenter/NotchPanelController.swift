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
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
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

// MARK: - 宿主控制器

/// 核心控制器：刘海交互、窗口管理、插件生命周期编排、布局渲染（文档 §2.1 / §5 / §6 / §7）。
@MainActor
final class NotchPanelController: NSObject {
    let settingsStore = SettingsStore()
    private(set) var layoutEngine: LayoutEngine!
    private(set) var pluginManager: PluginManager!

    private let hotPanel: NotchPanel
    private let drawerPanel: NotchPanel
    private var hotHostingView: TransparentHitHostingView<CompactPanelView>?
    private var drawerHostingView: NSHostingView<DrawerPanelView>?

    private var isExpanded = false
    private var isPinned = false
    private var isEditing = false
    private var isRevealedForFileDrag = false
    private var activeMenuTrackingCount = 0
    private var collapseTask: DispatchWorkItem?
    private var mousePollingTimer: Timer?
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var lastTargetScreen: NSScreen?
    private var pluginManagerWindowController: PluginManagerWindowController?

    override init() {
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

        super.init()
        configurePanel(hotPanel)
        configurePanel(drawerPanel)

        pluginManager = PluginManager(hostController: self)
        layoutEngine = LayoutEngine(blockResolver: { [weak self] pluginID, blockID in
            self?.pluginManager.block(pluginID: pluginID, blockID: blockID)
        })

        pluginManager.onEnabledPluginIDsChanged = { [weak self] _, newIDs in
            guard let self else { return }
            self.layoutEngine.syncEnabledPluginIDs(newIDs)
            self.rebuildContent()
        }

        layoutEngine.updateScreenConstraint(width: targetScreenFrame().width)

        // 启用状态恢复（文档 §5.4）：layout.json 记录 enabledPluginIDs。
        if layoutEngine.didLoadFromDisk {
            pluginManager.restoreEnabledState(from: layoutEngine.enabledPluginIDs)
        } else {
            seedDefaultLayout()
        }

        rebuildContent()
        startMousePolling()
        observeScreenChanges()
        observePanelMouseEvents()
        observeGlobalMouseEvents()
        observeMenuTracking()
    }

    // MARK: - 对外入口

    func showDocked() {
        let layout = currentLayout()
        rebuildContent(layout: layout)
        isExpanded = false
        hotPanel.setFrame(hotFrame(for: layout), display: true)
        drawerPanel.alphaValue = 1
        hotPanel.orderFrontRegardless()
        drawerPanel.orderOut(nil)
    }

    func expand(animated: Bool, activate: Bool = true) {
        if isExpanded {
            if activate {
                NSApp.activate(ignoringOtherApps: true)
                drawerPanel.makeKeyAndOrderFront(nil)
            }
            return
        }
        let layout = currentLayout()
        cancelCollapse()
        isExpanded = true
        isRevealedForFileDrag = false
        rebuildContent(layout: layout)
        // 紧凑 UI 常驻顶部：展开后仍显示（文档 §5.1 紧凑区始终可见），抽屉位于其下方。
        hotPanel.setFrame(hotFrame(for: layout), display: true)
        hotPanel.orderFrontRegardless()
        drawerPanel.setFrame(drawerFrame(for: layout), display: true)
        drawerPanel.alphaValue = 0
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            drawerPanel.makeKeyAndOrderFront(nil)
        } else {
            drawerPanel.orderFrontRegardless()
        }
        // 抽屉浮在紧凑面板之上（保持紧凑区可交互用于编辑添加，但视觉仍在顶部）。
        hotPanel.orderFrontRegardless()
        let duration: TimeInterval = animated ? 0.16 : 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.drawerPanel.animator().alphaValue = 1
        })
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        isExpanded = false
        isRevealedForFileDrag = false
        if isEditing {
            isEditing = false
        }
        let layout = currentLayout()
        let completion = { [weak self] in
            guard let self, !self.isExpanded else { return }
            self.drawerPanel.orderOut(nil)
            self.hotPanel.setFrame(self.hotFrame(for: layout), display: true)
            self.hotPanel.orderFrontRegardless()
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.drawerPanel.animator().alphaValue = 0
            }, completionHandler: completion)
        } else {
            drawerPanel.orderOut(nil)
            completion()
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
        if isExpanded {
            let layout = currentLayout()
            drawerPanel.setFrame(drawerFrame(for: layout), display: true)
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
    func startEditMode() {
        if !isExpanded {
            expand(animated: true, activate: false)
        }
        isEditing = true
        isPinned = true
        rebuildContent()
    }

    /// 由 HostController.exitEditMode / 视图动作调用。
    func stopEditMode() {
        guard isEditing else { return }
        isEditing = false
        rebuildContent()
        if !isPinned {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    // MARK: - 视图构建

    private func rebuildContent(layout: NotchLayout? = nil) {
        let layout = layout ?? currentLayout()
        let compactView = CompactPanelView(
            layout: layout,
            elements: buildCompactElements(layout: layout),
            isEditing: isEditing,
            showsClickModeHint: settingsStore.triggerMode == .click,
            compactCatalog: buildCompactCatalog(),
            canAddCompact: layoutEngine.compactSlots.contains(where: { $0 == nil }),
            actions: compactActions()
        )

        if let hotHostingView {
            hotHostingView.rootView = compactView
        } else {
            let host = TransparentHitHostingView(rootView: compactView)
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            hotPanel.contentView = host
            hotHostingView = host
        }

        let contentSize = layoutEngine.drawerContentSize()
        let drawerView = DrawerPanelView(
            contentWidth: contentSize.width,
            contentHeight: contentSize.height,
            windowSize: layoutEngine.drawerWindowSize(),
            elements: buildDrawerElements(),
            catalogPlugins: buildCatalogPlugins(),
            isPinned: isPinned,
            isEditing: isEditing,
            actions: drawerActions()
        )

        if let drawerHostingView {
            drawerHostingView.rootView = drawerView
        } else {
            let host = FirstMouseHostingView(rootView: drawerView)
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            drawerPanel.contentView = host
            drawerHostingView = host
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
            let sizes = BlockSize.allCases.filter { block.supportedSizes.contains($0) }
            let currentSize = sizes.first {
                $0.gridSpan.columns == placement.widthColumns
                    && $0.gridSpan.rows == placement.heightRows
            }
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
                    size: currentSize,
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
                supportedSizes: sizes,
                currentSize: currentSize
            )
        }
    }

    private func buildCatalogPlugins() -> [CatalogPluginGroup] {
        pluginManager.entries
            .filter { $0.isEnabled && $0.instance != nil }
            .map { entry in
                CatalogPluginGroup(
                    pluginID: entry.id,
                    displayName: entry.metadata.displayName,
                    drawerBlocks: entry.blocks.filter { $0.kind == .drawer }
                )
            }
    }

    /// 紧凑块目录（编辑模式“+”菜单）。
    private func buildCompactCatalog() -> [CompactCatalogItem] {
        pluginManager.entries
            .filter { $0.isEnabled && $0.instance != nil }
            .flatMap { entry in
                entry.blocks
                    .filter { $0.kind == .compact }
                    .map { block in
                        CompactCatalogItem(
                            pluginID: entry.id,
                            blockID: block.id,
                            displayName: block.displayName
                        )
                    }
            }
    }

    private func compactSlotFrame(index: Int, layout: NotchLayout) -> CGRect {
        let totalWidth = CGFloat(NotchGeometry.compactSlotCount) * NotchGeometry.compactSlotSize.width
            + CGFloat(NotchGeometry.compactSlotCount - 1) * NotchGeometry.compactSlotSpacing
        let x = (layout.compactSize.width - totalWidth) / 2
            + CGFloat(index) * (NotchGeometry.compactSlotSize.width + NotchGeometry.compactSlotSpacing)
        let y = layout.compactSize.height - NotchGeometry.compactSlotSize.height - 1
        return CGRect(origin: CGPoint(x: x, y: y), size: NotchGeometry.compactSlotSize)
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
            },
            onAddCompact: { [weak self] pluginID, blockID in
                guard let self else { return }
                self.layoutEngine.addCompactBlock(pluginID: pluginID, blockID: blockID)
                self.rebuildContent()
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
                self?.rebuildContent()
            },
            onMoveBlock: { [weak self] placementID, column, row in
                self?.layoutEngine.moveDrawerBlock(placementID: placementID, toColumn: column, toRow: row)
                self?.rebuildContent()
            },
            onResizeBlock: { [weak self] placementID, size in
                self?.layoutEngine.resizeDrawerBlock(placementID: placementID, to: size)
                self?.rebuildContent()
            },
            onAddBlock: { [weak self] pluginID, blockID in
                guard let self else { return }
                if let block = self.pluginManager.block(pluginID: pluginID, blockID: blockID),
                   block.kind == .compact {
                    self.layoutEngine.addCompactBlock(pluginID: pluginID, blockID: blockID)
                } else {
                    self.layoutEngine.autoPlaceDrawerBlock(pluginID: pluginID, blockID: blockID)
                }
                self.rebuildContent()
            },
            onPreviewMove: { [weak self] placementID, column, row in
                self?.layoutEngine.previewArrangement(
                    moving: placementID,
                    toColumn: column,
                    toRow: row
                ) ?? [:]
            },
            onCommitDrag: { [weak self] placementID, column, row in
                guard let self else { return }
                let origins = self.layoutEngine.previewArrangement(
                    moving: placementID,
                    toColumn: column,
                    toRow: row
                )
                _ = self.layoutEngine.commitArrangement(origins)
                self.rebuildContent()
            }
        )
    }

    // MARK: - 面板配置与事件

    private func configurePanel(_ panel: NotchPanel) {
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

    private func observePanelMouseEvents() {
        hotPanel.onMouseEvent = { [weak self] event in
            guard let self else { return }
            guard event.type == .leftMouseDown else { return }
            // 块视图自身处理点击；仅当点击落在槽位之外才视为面板级展开。
            let location = NSEvent.mouseLocation
            if !self.isPointInAnyCompactSlot(location, layout: self.currentLayout()) {
                self.expand(animated: true, activate: true)
            }
        }

        drawerPanel.onMouseEvent = { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                NSApp.activate(ignoringOtherApps: true)
                self.drawerPanel.makeKeyAndOrderFront(nil)
            }
        }

        hotPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
        drawerPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
    }

    private func observeGlobalMouseEvents() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      !self.isExpanded,
                      self.settingsStore.triggerMode == .click,
                      self.activationFrame().contains(NSEvent.mouseLocation) else {
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
        let location = NSEvent.mouseLocation
        let screen = NotchGeometry.targetScreen()
        if screen !== lastTargetScreen {
            lastTargetScreen = screen
            relocateToScreen(screen)
        }
        handleMouseLocation(location)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        lastTargetScreen = nil
        relocateToScreen(NotchGeometry.targetScreen())
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
               activationFrame().contains(point) {
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

    private func isPointInExpandedStayRegion(_ point: NSPoint) -> Bool {
        let margin: CGFloat = 10
        return drawerPanel.frame.insetBy(dx: -margin, dy: -margin).contains(point)
            || activationFrame().contains(point)
    }

    private func isPointInAnyCompactSlot(_ point: NSPoint, layout: NotchLayout) -> Bool {
        let hotFrame = hotFrame(for: layout)
        let slots = (0..<NotchGeometry.compactSlotCount).map { index in
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
        return activationFrame().contains(point)
    }

    // MARK: - 多显示器（文档 §6.3 / §7.3）

    private func relocateToScreen(_ screen: NSScreen?) {
        let screenFrame = screen?.frame ?? targetScreenFrame()
        layoutEngine.updateScreenConstraint(width: screenFrame.width)
        let layout = currentLayout()
        rebuildContent(layout: layout)
        hotPanel.setFrame(hotFrame(for: layout), display: true)
        if isExpanded {
            drawerPanel.setFrame(drawerFrame(for: layout), display: true)
        }
    }

    private func currentLayout() -> NotchLayout {
        NotchGeometry.layout(for: NotchGeometry.targetScreen())
    }

    private func targetScreen() -> NSScreen? {
        NotchGeometry.targetScreen()
    }

    private func targetScreenFrame() -> NSRect {
        targetScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func hotFrame(for layout: NotchLayout) -> NSRect {
        NotchGeometry.activationFrame(for: layout, in: targetScreenFrame())
    }

    private func drawerFrame(for layout: NotchLayout) -> NSRect {
        let screenFrame = targetScreenFrame()
        var size = layoutEngine.drawerWindowSize()
        // 文档 §5.3：达到屏幕可用高度上限后内容区域滚动（窗口高度封顶）。
        let maxHeight = screenFrame.height - 8
        if size.height > maxHeight {
            size.height = maxHeight
        }
        if size.height > screenFrame.height - layout.compactSize.height - 4 {
            size.height = max(screenFrame.height - layout.compactSize.height - 4, 120)
        }
        // 紧凑区常驻顶部：抽屉从紧凑面板下方开始展开（文档 §5.1 / §6）。
        return NotchGeometry.topCenteredFrame(
            for: size,
            topY: screenFrame.maxY - layout.compactSize.height,
            in: screenFrame
        )
    }

    private func activationFrame() -> NSRect {
        hotFrame(for: currentLayout())
    }

    // MARK: - 插件管理窗口

    /// 开发期调试：把两个面板内容渲染为 PNG（无需屏幕录制权限）。
    func capturePanelsForDebug() {
        func writePNG(of view: NSView?, to path: String) {
            guard let view else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        writePNG(of: hotPanel.contentView, to: "/tmp/nc_hot.png")
        writePNG(of: drawerPanel.contentView, to: "/tmp/nc_drawer.png")
        print("debug windows: hot=\(hotPanel.frame) drawer=\(drawerPanel.frame)")
        print("debug sizes: content=\(layoutEngine.drawerContentSize()) window=\(layoutEngine.drawerWindowSize()) blocks=\(layoutEngine.drawerBlocks.count)")
        let layout = currentLayout()
        print("debug compact: layout.compact=\(layout.compactSize) panelWidth=\(NotchGeometry.compactPanelWidth) notch=\(layout.notchSize)")
        for index in 0..<NotchGeometry.compactSlotCount {
            print("debug slot\(index): \(compactSlotFrame(index: index, layout: layout))")
        }
        if let hotContentView = hotPanel.contentView {
            print("debug hot contentView frame: \(hotContentView.frame) bounds: \(hotContentView.bounds)")
        }
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