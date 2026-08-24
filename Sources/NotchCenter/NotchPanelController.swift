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

    var isRevealedForFileDrag = false
    /// 收起态进入编辑的等待期（揭示→编辑两段式之间）：悬停判定视为停留。
    var isEditEntryPending = false
    var activeMenuTrackingCount = 0
    var collapseTask: DispatchWorkItem?
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
    func syncScreens() {
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens

        // 移除已断开屏幕的面板对（NSScreen 实例在部分显示重配后会换新身份，
        // 同一物理屏也会命中此路径）。窗口不会随 pair 移除自动隐藏，残留的
        // 常置顶面板会与新 pair 叠影，必须显式收回。
        let stalePairs = pairs.filter { pair in !screens.contains { $0 === pair.screen } }
        pairs.removeAll { pair in !screens.contains { $0 === pair.screen } }
        for stale in stalePairs {
            GhostProbe.log("syncScreens hide stale pair=\(NSStringFromRect(stale.screen.frame))")
            stale.hotPanel.orderOut(nil)
            stale.drawerPanel.orderOut(nil)
        }

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

    /// 把某屏幕的紧凑面板摆到其刘海位置（宽度随当前紧凑图标数伸缩，
    /// 由 `rebuildContent` 在图标增删时调用）。
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
        GhostProbe.log("expand enter isExpanded=\(isExpanded) activate=\(activate) mouse=\(NSStringFromPoint(NSEvent.mouseLocation))")
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
        GhostProbe.log("expand pair=\(pair.screen.frame)")

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
            GhostProbe.log("hideOtherDrawers orderOut pair=\(NSStringFromRect(pair.screen.frame))")
            pair.drawerPanel.orderOut(nil)
        }
    }

    func collapse(animated: Bool) {
        GhostProbe.log("collapse enter isExpanded=\(isExpanded) pair=\(activePair.map { NSStringFromRect($0.screen.frame) } ?? "nil")")
        guard isExpanded else { return }
        isExpanded = false
        isRevealedForFileDrag = false
        if isEditing {
            isEditing = false
        }
        setDrawerRevealed(false, animated: animated)
        let completion = { [weak self] in
            guard let self else { return }
            // 等待期内可能再次展开（同屏返回，或移到了另一块屏）：只保留
            // 当前展开屏的抽屉，其余屏（含本次收起的屏）一律收回。不能
            // 因“已重新展开”整体跳过——跨屏再展开时上一块屏的抽屉会
            // 永久残留。
            let kept = self.isExpanded ? self.activePair : nil
            GhostProbe.log("collapse completion kept=\(kept.map { NSStringFromRect($0.screen.frame) } ?? "nil")")
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
        let strip: CompactStripLayout
        if let pair = activePair {
            strip = pair.layout.compactStrip(slotCount: pair.compactCount)
        } else {
            strip = primaryLayout().compactStrip(slotCount: layoutEngine.compactSlots.count)
        }
        return CGSize(width: strip.windowWidth, height: 0)
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

    /// 抽屉窗口内容尺寸（不含岛顶紧凑带）：布局内容 + 编辑模式 AddBlock
    /// 区域增高；超出屏幕可用高度时封顶（网格 ScrollView 可视高度随之压缩，
    /// 文档 §5.3）。与 `DrawerPanelView` 根视图共享该尺寸，保证布局一致。
    /// `previewRows` 用于拖拽/缩放预览（按预览布局的最低行临时增高）；
    /// `previewColumns` 同理（按预览布局的实际占用列数临时增宽）。
    func drawerWindowSize(
        for pair: ScreenPanelPair?,
        previewRows: Int? = nil,
        previewColumns: Int? = nil
    ) -> CGSize {
        var size = layoutEngine.drawerWindowSize(
            contentRows: previewRows,
            contentColumns: previewColumns
        )
        if isEditing {
            size.height += AddBlockArea.height(for: uiState.catalogPlugins)
        }
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
        let resizedColumns = resized.map { ($0.placementID, $0.widthColumns) }
        let columnRange = layoutEngine.previewColumnRange(origins: origins, resized: resizedColumns)
        let columnSpan = min(
            max(columnRange.max - columnRange.min, 1),
            layoutEngine.effectiveMaxColumns()
        )
        let bottomRow = layoutEngine.previewBottomRow(
            origins: origins,
            resized: resized.map { ($0.placementID, $0.heightRows) }
        )
        let size = drawerWindowSize(
            for: pair,
            previewRows: bottomRow,
            previewColumns: layoutEngine.previewOccupiedColumns(origins: origins, resized: resizedColumns)
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            uiState.drawerGridLeftColumn = columnRange.min
            // 容器高度随预览最低行同步更新（曾只更新宽度、高度钉在提交布局
            // 的旧行高）：缩小时网格内容比可视区高一截，ScrollView 反复亮起
            // 滚动条。与宽度一样按预览几何计，DrawerPanelView 的网格高度
            // 只读这个值。
            uiState.drawerContentSize = CGSize(
                width: NotchGridMetrics.contentWidth(columns: columnSpan),
                height: NotchGridMetrics.contentHeight(rows: max(bottomRow, 1))
            )
            guard uiState.drawerWindowSize != size else { return }
            uiState.drawerWindowSize = size
        }
    }

    /// 编辑操作提交后的刷新：内容 spring 重建（窗口高度固定，
    /// 无空行、面板贴合内容）。
    func refreshAfterEdit() {
        rebuildContent(animated: true)
    }
}

// MARK: - HostController 协议实现

/// 临时探针：NOTCHCENTER_GHOST_PROBE=1 时输出展开/收起/换屏决策日志。
enum GhostProbe {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["NOTCHCENTER_GHOST_PROBE"] == "1" }
    static func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("[ghost] \(message)")
    }
}

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
