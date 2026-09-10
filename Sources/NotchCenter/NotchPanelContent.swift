import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 块视图复用键

/// `makeView` 可观察输入的完整快照：逐项相等 ⟺ 重新调 `makeView` 必然产出
/// 等价的视图值。字段清单按 `BlockContext` 反推——`pluginID/blockID/placementID/
/// stateStore/hostController/layoutInfo`，其中 layoutInfo 的每个字段（region、
/// frame、origin/跨度、isEditing、slotIndex、isPreview）插件都可能读
/// （Notes 读 originRow/heightRows/isPreview，Pomodoro/Scratchpad/Caffeinate 读
/// frame.size）。stateStore 与 hostController 都挂在 entry 上，经
/// `ObjectIdentifier(entry)` 覆盖（插件重载会换 entry 实例 → 强制重建）。
/// （模块内可见：控制器存储缓存字典需要这个类型。）
struct BlockViewCacheKey: Equatable {
    var pluginID: String
    var blockID: String
    var placementID: String
    var entryID: ObjectIdentifier
    var region: BlockRegion
    var frame: CGRect
    var originColumn: Int?
    var originRow: Int?
    var widthColumns: Int?
    var heightRows: Int?
    var isEditing: Bool
    var compactSlotIndex: Int?
    var isPreview: Bool
    var hasSettings: Bool
}

// MARK: - HostController 编辑模式（文档 §4.5）

extension NotchPanelController {
    /// 首启默认布局：启用全部内置插件，把所有官方紧凑块加入紧凑带（带宽随图标数
    /// 伸缩），抽屉自动放置官方抽屉块，让首次启动即可看到面板内容（空布局对
    /// 用户不直观）。
    func seedDefaultLayout() {
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
        // 官方「快捷按钮」默认布局：声明 `defaultInStrip` 的动作补进快速区
        // （它们的前身正是默认进带的紧凑块，动作化后以动作槽位入带）。
        for entry in enabledEntries {
            guard let actions = entry.instance?.quickActions else { continue }
            for action in actions where action.defaultInStrip {
                _ = layoutEngine.addQuickActionSlot(pluginID: entry.id, actionID: action.id)
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
            // 揭示完成后再进入编辑（两段式，各自走已验证路径）；等待期内
            // 悬停判定视为停留（否则鼠标不在停留区会在揭示中途收起）。
            isEditEntryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                self?.isEditEntryPending = false
                self?.applyEditMode()
            }
        } else {
            applyEditMode()
        }
    }

    /// 进入编辑状态的内容过渡（`drawerWindowSize` spring 增高，窗口不动）。
    private func applyEditMode() {
        // 编辑模式视觉（顶栏按钮切换、提示标签、块编辑 chrome）全部由
        // `ui.isEditing` 驱动，且没有任何块视图读取 layoutInfo.isEditing，
        // 这里只翻转状态、不做全量块视图重建（编辑期的增删/移动/缩放各自
        // 已走 refreshAfterEdit 全量路径；进出编辑本身不改变任何布局数据
        // 与窗口尺寸）。
        withAnimation(DrawerAnimation.spring) {
            isEditing = true
        }
    }

    /// 由 HostController.exitEditMode / 视图动作调用。
    /// 高度收缩由内容 spring + 窗口逐帧跟随完成（syncDrawerFrame）。
    func stopEditMode() {
        guard isEditing else { return }
        // 退出编辑时锚定块可能消失/移位，设置浮窗先随编辑态一起收场。
        SettingPopover.shared.dismiss()
        // 只翻转状态（同 applyEditMode：视觉全由 ui.isEditing 驱动，
        // 不做全量块视图重建）。
        withAnimation(DrawerAnimation.spring) {
            isEditing = false
        }
        if !isPinned {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    /// 设置面板切到 / 离开「组件」页：组件页期间抽屉进入编辑模式——从页内
    /// 拖进来的组件落位后即可继续拖动、缩放、删除，无需再点一次编辑按钮。
    /// 离开该页（或关闭面板）时退出编辑模式。
    func setComponentsPageActive(_ active: Bool) {
        guard active != isEditingForComponentsPage else { return }
        isEditingForComponentsPage = active
        if active {
            if !isExpanded {
                expand(animated: true, activate: false)
            }
            startEditMode()
        } else {
            stopEditMode()
        }
    }

    // MARK: - 视图构建

    /// 刷新面板内容：把布局与元素写入 `uiState`（@Published 驱动 SwiftUI 刷新），
    /// 所有屏幕的宿主视图共享同一份状态。宿主视图只创建一次，之后不再重新赋值
    /// rootView——在透明无边框 NSPanel 上 rootView 重赋值不能保证立即重绘。
    /// `animated: true` 时状态变化套 spring（编辑模式窗口高度过渡）。
    ///
    /// 纯内容重建：紧凑区几何（缩放到当前图标数）由调用方先行
    /// `refreshCompactGeometry()` 同步——只有增删紧凑图标/换屏的路径需要，
    /// 其余路径计数未变无需调用。
    func rebuildContent(animated: Bool = false) {
        // 紧凑元素的上下文 frame 以主屏几何近似（槽位尺寸跨屏一致，
        // 视觉几何由各面板的 layout 参数精确持有）。
        let contextLayout = primaryLayout()

        let apply = {
            self.uiState.showsClickModeHint = self.settingsStore.triggerMode == .click
            self.uiState.compactElements = self.buildCompactElements(layout: contextLayout)

            // 页面集合/几何/块元素一律按激活页计算。
            let activePage = self.uiState.drawerActivePage
            self.uiState.drawerPages = self.layoutEngine.drawerPages
            self.uiState.drawerPageTitles = self.layoutEngine.drawerPageTitles
            self.uiState.drawerPageIcons = self.layoutEngine.drawerPageIcons
            self.uiState.drawerContentSize = self.layoutEngine.drawerContentSize(page: activePage)
            self.uiState.drawerGridLeftColumn = self.layoutEngine.gridLeftColumn(page: activePage)
            // 与上面的尺寸同批写入（分两批即一帧裁切，见 `DrawerGridGeometry.minimumRows`）。
            self.uiState.drawerGridMinRows = self.layoutEngine.minimumRowCount()
            self.uiState.drawerGridMinColumns = self.layoutEngine.minimumColumnCount()
            self.uiState.drawerWindowSize = self.drawerWindowSize(for: self.activePair ?? self.pairs.first)
            self.uiState.drawerElements = self.buildDrawerElements()
            // 内容重建即几何已变，半截滑入层不得残留（收起 / 进入编辑 /
            // 增删块等路径共用这一处兜底；提交切页时它本就先被清掉）。
            // 在飞的自驱弹簧一并停表：会话被清后它的帧与收敛拍不再有意义。
            self.swipeSpringDriver.cancel()
            self.uiState.drawerSwipe = nil
        }
        if animated {
            withAnimation(DrawerAnimation.spring) {
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
            let host = DrawerHostingView(
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
                    bridge: drawerInteractionBridge()
                )
            )
            host.visibleHeightProvider = { [weak self, weak pair] in
                guard let self, let pair else { return 0 }
                return pair.layout.compactHeight + self.uiState.drawerWindowSize.height
            }
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            pair.drawerPanel.contentView = host
            pair.drawerHostingView = host
        }
    }

    private func buildCompactElements(layout: NotchLayout) -> [CompactElement] {
        var elements: [CompactElement] = []
        elements.reserveCapacity(compactIconCount)
        var cache: [Int: (key: BlockViewCacheKey, view: AnyView)] = [:]
        for index in 0..<compactIconCount {
            let frame = compactSlotFrame(index: index, layout: layout, slotCount: compactIconCount)
            guard let reference = layoutEngine.compactSlot(at: index),
                  let entry = pluginManager.entry(for: reference.pluginID),
                  entry.isEnabled,
                  let store = entry.stateStore else {
                elements.append(CompactElement(
                    slotIndex: index,
                    reference: nil,
                    block: nil,
                    view: nil,
                    frame: frame,
                    hasSettings: false
                ))
                continue
            }
            // 解析槽位身份：优先插件声明的 compact 块（第三方插件自带视图）；
            // 没有则回退到**快捷动作**——官方一键入口已统一为快捷按钮，动作 id
            // 与旧紧凑块 id 同名，旧布局槽位无需迁移即指向动作。动作解析用
            // 注册表实例（identity 稳定、可观察 isActive），不复用插件 computed
            // 属性（每次新建实例会破坏状态同步）。
            if let block = pluginManager.block(
                pluginID: reference.pluginID,
                blockID: reference.blockID
            ), block.kind == .compact {
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
                let hasSettings = block.instanceSettingsView != nil
                    || entry.instance?.settingsView != nil
                let key = BlockViewCacheKey(
                    pluginID: reference.pluginID,
                    blockID: reference.blockID,
                    placementID: reference.placementID,
                    entryID: ObjectIdentifier(entry),
                    region: .compact,
                    frame: frame,
                    originColumn: nil,
                    originRow: nil,
                    widthColumns: nil,
                    heightRows: nil,
                    isEditing: isEditing,
                    compactSlotIndex: index,
                    isPreview: false,
                    hasSettings: hasSettings
                )
                // 键逐项相等 → makeView 必然产出等价视图值，复用上一次的结果。
                let view: AnyView
                if let old = compactViewCache[index], old.key == key {
                    view = old.view
                } else {
                    view = block.makeView(context)
                }
                cache[index] = (key, view)
                elements.append(CompactElement(
                    slotIndex: index,
                    reference: reference,
                    block: block,
                    view: view,
                    frame: frame,
                    hasSettings: hasSettings
                ))
            } else if let action = quickActionStore.action(id: reference.blockID) {
                // 统一快捷按钮：宿主标准外观 + 点击/确认由动作驱动（无块设置）。
                elements.append(CompactElement(
                    slotIndex: index,
                    reference: reference,
                    block: nil,
                    view: AnyView(
                        QuickActionStripCell(action: action, slotSize: frame.size)
                    ),
                    frame: frame,
                    hasSettings: false
                ))
            } else {
                elements.append(CompactElement(
                    slotIndex: index,
                    reference: reference,
                    block: nil,
                    view: nil,
                    frame: frame,
                    hasSettings: false
                ))
            }
        }
        compactViewCache = cache
        return elements
    }

    /// 构建某页的抽屉块元素；`isPreview` 原样透传给插件（契约见 `BlockLayoutInfo.isPreview`）。
    private func buildDrawerElements(
        page: Int? = nil,
        isPreview: Bool = false
    ) -> [DrawerElement] {
        let targetPage = page ?? uiState.drawerActivePage
        var elements: [DrawerElement] = []
        elements.reserveCapacity(layoutEngine.drawerBlocks(onPage: targetPage).count)
        var cache: [String: (key: BlockViewCacheKey, view: AnyView)] = [:]
        for placement in layoutEngine.drawerBlocks(onPage: targetPage) {
            guard let entry = pluginManager.entry(for: placement.pluginID),
                  entry.isEnabled,
                  let block = pluginManager.block(pluginID: placement.pluginID, blockID: placement.blockID),
                  block.kind.occupiesDrawerGrid,
                  let store = entry.stateStore else {
                // 插件不可用（停用 / 卸载 / 块定义已不存在）时静默跳过，宿主
                // 卡片里留一格空白。
                continue
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
                    size: currentSpan,
                    originColumn: placement.originColumn,
                    originRow: placement.originRow,
                    widthColumns: placement.widthColumns,
                    heightRows: placement.heightRows,
                    isEditing: isEditing,
                    isPreview: isPreview
                )
            )
            let hasSettings = block.instanceSettingsView != nil
                || entry.instance?.settingsView != nil
            let key = BlockViewCacheKey(
                pluginID: placement.pluginID,
                blockID: placement.blockID,
                placementID: placement.placementID,
                entryID: ObjectIdentifier(entry),
                region: .drawer,
                frame: frame,
                originColumn: placement.originColumn,
                originRow: placement.originRow,
                widthColumns: placement.widthColumns,
                heightRows: placement.heightRows,
                isEditing: isEditing,
                compactSlotIndex: nil,
                isPreview: isPreview,
                hasSettings: hasSettings
            )
            // 键逐项相等 → 复用上一次的视图值（切页往返、条带层换绑重建等
            // 场景不再反复重挂插件视图；placementID 全局唯一，跨页不会误配）。
            let view: AnyView
            if let old = drawerViewCache[placement.placementID], old.key == key {
                view = old.view
            } else {
                view = block.makeView(context)
            }
            cache[placement.placementID] = (key, view)
            // 物理像素三档 → 当前格子的允许格跨盒（缩放钳制用；格子变化会经
            // didChangeNotification 重建元素，盒随之刷新）。
            let metrics = GridMetrics.current
            let box = block.sizeBox(cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight)
            elements.append(DrawerElement(
                placement: placement,
                view: view,
                minSize: box?.min ?? GridSpan.globalMinimum,
                maxSize: box?.max ?? GridSpan.globalMinimum,
                currentSpan: currentSpan,
                hasSettings: hasSettings
            ))
        }
        // 提交布局（非预览）构建后更新缓存：与旧缓存**并集**保留——切页往返时
        // 另一页的复用键不被本次页挤掉，往返复用才成立；被删除的 placement
        // （UUID 全局唯一，无误配风险）按现存集合修剪出表。预览副本的键含
        // isPreview 不会与真实例互配，且不回写缓存（否则会把激活页真实例的
        // 键挤掉，落位重建退回全量 makeView）。
        if !isPreview {
            var merged = drawerViewCache
            let alive = Set(layoutEngine.drawerBlocks.map(\.placementID))
            for placementID in merged.keys where !alive.contains(placementID) {
                merged.removeValue(forKey: placementID)
            }
            for (placementID, entry) in cache {
                merged[placementID] = entry
            }
            drawerViewCache = merged
        }
        return elements
    }

    /// 槽位矩形（窗口内容坐标，左上原点）；与视图共享同一 strip 布局。
    /// 宽度随当前紧凑图标数动态伸缩。
    ///
    /// **刻意不带摘要带宽**：本矩形只喂 `CompactElement.frame`（插件
    /// `layoutInfo.frame` 尺寸源与块视图缓存键）。插件渲染用的槽位**尺寸**
    /// 不随摘要带宽变化；若此处按摘要带宽计算，摘要出现/更新会让 frame 逐帧
    /// 变化 → 块视图缓存整批失效重建（紧凑图标随摘要闪烁）。图标**位置**由
    /// `CompactPanelView` 用摘要感知的 `ui.compactStrip` 排布，与插件无关。
    func compactSlotFrame(index: Int, layout: NotchLayout, slotCount: Int) -> CGRect {
        layout.compactStrip(slotCount: slotCount)
            .slotRect(at: index) ?? .zero
    }

    private func compactActions() -> CompactActions {
        CompactActions(
            onRemoveBlock: { [weak self] index in
                guard let self else { return }
                // 锚定图标即将消失，设置浮窗先收场。
                SettingPopover.shared.dismiss()
                if let reference = self.layoutEngine.compactSlot(at: index) {
                    self.notifyPlacementRemoved(reference)
                }
                self.layoutEngine.setCompactSlot(index, to: nil)
                // 紧凑图标数减少：先同步条带几何/热区窗口，再重建内容。
                self.refreshCompactGeometry()
                self.rebuildContent()
            },
            onShowSettings: { [weak self] pluginID, placementID, anchorFrame in
                // 紧凑小图标贴下方弹出（同心叠加会被钳回悬在刘海带上）。
                self?.showPluginSettings(
                    pluginID: pluginID,
                    placementID: placementID,
                    anchorFrame: anchorFrame,
                    placement: .below
                )
            },
            onTapBackground: { [weak self] in
                self?.expand(animated: true, activate: true)
            },
            onExpand: { [weak self] in
                self?.expand(animated: true, activate: true)
            },
            onReorderPreview: { [weak self] draggingSlot, screenPosition, pointerX in
                self?.updateCompactReorderPreview(
                    draggingSlot: draggingSlot,
                    screenPosition: screenPosition,
                    pointerX: pointerX
                )
            },
            onReorderCommit: { [weak self] from, screenPosition in
                self?.moveCompactBlock(from: from, toScreenPosition: screenPosition)
            }
        )
    }

    func drawerActions() -> DrawerActions {
        DrawerActions(
            onShowSettings: { [weak self] in
                // 打开设置并直入「组件」页：非编辑态由 setComponentsPageActive
                // 联动进入编辑模式；编辑态下传 .components 无强制退出编辑副作用。
                // 再次点击 = 关闭面板 → 联动退出编辑模式。
                self?.showSettings(page: .components)
            },
            onTogglePin: { [weak self] in
                guard let self else { return }
                // 只翻 @Published：顶栏钉住图标与收起守卫（DrawerStayConditions）
                // 都直接读 uiState.isPinned，无需全量重建块视图。
                self.isPinned.toggle()
                if !self.isPinned, !self.isEditing {
                    self.handleMouseLocation(NSEvent.mouseLocation)
                }
            },
            onRemoveBlock: { [weak self] placementID in
                guard let self else { return }
                // 锚定块即将消失，设置浮窗先收场。
                SettingPopover.shared.dismiss()
                if let removed = self.layoutEngine.drawerBlocks.first(where: { $0.placementID == placementID }) {
                    self.notifyPlacementRemoved(
                        pluginID: removed.pluginID,
                        blockID: removed.blockID,
                        placementID: removed.placementID
                    )
                }
                self.layoutEngine.removeDrawerBlock(placementID: placementID)
                self.refreshAfterEdit()
            },
            onShowBlockSettings: { [weak self] pluginID, placementID, anchorFrame in
                // 抽屉块同心覆盖弹出（与服务卡浮窗同一摆放语义）。
                self?.showPluginSettings(
                    pluginID: pluginID,
                    placementID: placementID,
                    anchorFrame: anchorFrame,
                    placement: .overlay
                )
            },            onReorderBlocks: { [weak self] in
                self?.layoutEngine.reorderDrawerBlocks(page: self?.uiState.drawerActivePage ?? 0)
                self?.refreshAfterEdit()
            },
            onSelectPage: { [weak self] page in
                self?.selectDrawerPage(page)
            },
            onAddPage: { [weak self] side in
                self?.addDrawerPage(side)
            },
            onMovePage: { [weak self] page, targetIndex in
                self?.moveDrawerPage(from: page, to: targetIndex)
            },
            onShowPageSettings: { [weak self] page, anchorFrame in
                self?.showPageSettings(page: page, anchorFrame: anchorFrame)
            },
            onRemovePage: { [weak self] page in
                self?.removeDrawerPage(page)
            },
            onSwipeDrag: { [weak self] translation in
                self?.drawerSwipeDrag(translation: translation)
            },
            onSwipeDragEnded: { [weak self] translation, predictedEndTranslation in
                self?.drawerSwipeDragEnded(
                    translation: translation,
                    predictedEndTranslation: predictedEndTranslation
                )
            }
        )
    }

    // MARK: 抽屉页面

    /// 切页是否安全（分页胶囊与左右滑动共用）：切页会整屏换掉抽屉内容，
    /// 而落位飞行、跨窗口拖拽与设置面板的落点预览都按**当前页**计算，
    /// 中途换页会让它们把结果写到错的页上。唯一例外是拖拽驻留切页
    ///（`switchDrawerPageForDrag`）：它只在指针压在胶囊行上触发，此刻
    /// 落点判定为顶栏、`dropPreview` 已同帧清空，不存在错页写入。
    private var canSwitchDrawerPage: Bool {
        isExpanded
            && !isEditEntryPending
            && uiState.dropPreview == nil
            && !BlockDragCoordinator.shared.isDragging
            && activeMenuTrackingCount == 0
    }

    /// 切换激活页（带 spring 重建，面板尺寸随新页内容自适应）。
    func selectDrawerPage(_ page: Int) {
        guard canSwitchDrawerPage,
              page != uiState.drawerActivePage,
              layoutEngine.drawerPages.contains(page) else { return }
        uiState.drawerActivePage = page
        rebuildContentAfterPageChange()
    }

    /// 组件页拖拽的驻留切页：拖动中指针压在分页胶囊上驻留 0.5s 触发
    /// （计时与复核在 `BlockDragCoordinator`）。绕过 `canSwitchDrawerPage`
    /// 的"拖拽进行中"禁令——该禁令防的是落点预览按旧页计算、结果写到
    /// 错页；而驻留切换只发生在指针压在胶囊行上时，`dropZone` 判顶栏恒无
    /// 落点、`dropPreview` 已同帧清空，松手落位仍按**切换后的激活页**算。
    /// 其余守卫（展开 / 编辑入场 / 菜单追踪 / 滑动会话）照常保留。
    func switchDrawerPageForDrag(_ page: Int) {
        let guards = (
            expanded: isExpanded,
            editEntryPending: isEditEntryPending,
            dropPreviewNil: uiState.dropPreview == nil,
            menuTrackingIdle: activeMenuTrackingCount == 0,
            noSwipe: uiState.drawerSwipe == nil,
            targetDiffers: page != uiState.drawerActivePage,
            pageExists: layoutEngine.drawerPages.contains(page)
        )
        guard guards.expanded, !guards.editEntryPending, guards.dropPreviewNil,
              guards.menuTrackingIdle, guards.noSwipe, guards.targetDiffers, guards.pageExists else {
            if BlockDragCoordinator.dragProbeLogEnabled {
                print("[drag-probe] switch blocked: target=\(page) \(guards)")
            }
            return
        }
        uiState.drawerActivePage = page
        if BlockDragCoordinator.dragProbeLogEnabled {
            print("[drag-probe] switch done: active=\(page)")
        }
        rebuildContentAfterPageChange()
    }

    /// 切页/加页后的内容重建：抽屉高度随页变化，设置面板摆位必须**先重裁**
    /// 再重建（限高读摆位，见 `drawerWindowSize`），新页更高时面板顺带让开。
    /// 与 `refreshAfterLayoutChange` 的区别：不做抽屉窗口 `setFrame`——切页
    /// 不改窗口 frame，省掉满高窗口的重绘。
    func rebuildContentAfterPageChange(animated: Bool = true) {
        let placementChanged = updateSettingsPlacement()
        rebuildContent(animated: animated)
        if placementChanged {
            positionSettingsWindow(animated: animated)
        }
    }

    /// 滑动切页是否可用：`canSwitchDrawerPage` 之外再排除拖拽/缩放预览进行中
    /// （块的推挤预览按激活页计算，中途切页会把预览提交到错的页上）。
    /// **在飞会话不再禁用滑动**：落位/回弹由自驱弹簧驱动（状态值即表现值），
    /// 新输入随时接管续接（grab），无输入锁定期。编辑模式本身不禁用滑动——
    /// 空隙上的拖拽与触控板轻扫与非编辑态一致跟手切页，块拖拽/缩放期间则
    /// 暂停切页，松手后恢复（`isDrawerInteractionActive` 由 DrawerPanelView 的
    /// DrawerInteractionState 经 PanelUIState 同步）。
    private var canSwipeDrawerPage: Bool {
        canSwitchDrawerPage && !uiState.isDrawerInteractionActive
    }

    /// 位移上限 = 当前页宽（滑到刚好覆盖整页）。
    private var drawerSwipeLimit: CGFloat { max(uiState.drawerContentSize.width, 1) }

    /// 让路：光标下的块要消费横向滑动——放弃本次切页（重置轨迹与在途会话），
    /// 横向增量留给块自己。
    private func yieldDrawerSwipeToBlock() {
        drawerScrollTracker.reset()
        endDrawerSwipe(commit: false, offset: 0)
    }

    func handleDrawerScroll(_ event: NSEvent) {
        let phase = event.phase
        // 过滤：非精确增量是鼠标滚轮（只有纵向）；惯性尾巴足以再翻一页；
        // `.mayBegin` 试探事件不喂（随后的 `.began` 会重置，喂了能一次翻两页）。
        // 坑：`momentumPhase.isEmpty` 不能写成 `== .none`——`NSEvent.MomentumPhase`
        // 没有 `none` 成员，`.none` 会被解析成 `Optional.none` 再隐式提升比较，
        // 恒为 false（真机上表现为横向轻扫全部失效）。
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              !phase.contains(.mayBegin), canSwipeDrawerPage else { return }

        // 位移上限在会话期冻结（`drawerContentSize` 随进度插值，现读会让
        // 橡皮筋与位移换算逐帧漂移）；无会话时 = 当前页宽。
        let limit = uiState.drawerSwipe?.limit ?? drawerSwipeLimit
        // 光标落在块上时经 `DrawerScrollProbe` 子树枚举核实"光标下确有横向
        // 溢出的滚动视图"才让路——静态卡片与纵向 ScrollView（无横向溢出，如
        // 亮度滑杆块）放行切页，空/未满的横向 ScrollView（如文件架）亦放行。
        // **让路只在会话建立前判定**（与拖拽通路 `drawerSwipeDrag` 一致）：
        // 会话进行中页带滑行、面板尺寸随进度插值，探针的实时 NSView 几何随
        // 之漂移——此时再探针，横向溢出的滚动视图（如暂存区）会滑到静止的
        // 光标下翻真，把已开始的切页中途弹回（真机：轻扫途中被暂存区打断）。
        // 会话一旦建立即锁定本次手势，切页必然走完提交/回弹；穿越溢出滚动
        // 视图时块内可能跟随滚一点，属已知双响应取舍（见领域文档）。
        // 探针从窗口 contentView 向下 DFS，不依赖命中链（SwiftUI 在宿主视图层
        // 接管事件，hitTest 到不了内部滚动机构，旧的"沿 superview 向上找
        // NSScrollView"实测恒 false，勿改回）。最低支持 macOS 15（SwiftUI 内部
        // 滚动机构已实测），"没找到 → 放行"的反向推断可信。
        if uiState.drawerSwipe == nil,
           let window = event.window,
           drawerElement(at: window.convertPoint(toScreen: event.locationInWindow)) != nil,
           DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
               in: window,
               cursorWindowPoint: event.locationInWindow) {
            yieldDrawerSwipeToBlock()
            return
        }
        // 落位/回弹在飞（驱动器运行中）：输入帧即**接管候选**。有边界的触控板
        // 手势任意帧可接管；无边界输入须等冷却外（冷却是它们唯一的防连翻手段，
        // 冷却内的事件照旧被吞）。光标压在横向溢出块上则让路——驱动器继续
        // 落位，块自己消费滚动；探测逐帧进行，块让路后光标移出即恢复可接管。
        if let session = uiState.drawerSwipe, swipeSpringDriver.isRunning,
           !phase.isEmpty || !drawerScrollTracker.isCoolingDown(at: event.timestamp) {
            if let window = event.window,
               drawerElement(at: window.convertPoint(toScreen: event.locationInWindow)) != nil,
               DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
                   in: window,
                   cursorWindowPoint: event.locationInWindow) {
                return
            }
            grabDrawerSwipe(session, inputPosition: drawerScrollTracker.accumulatedX)
        }
        if let frame = drawerScrollTracker.feed(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: phase,
            at: event.timestamp,
            limit: limit
        ) {
            beginDrawerSwipe(frame.side)
            if let session = uiState.drawerSwipe {
                // 跟手位移 = 重锚种子 + 锚后增量 × 屏幕换算比（面板居中偏移）：
                // 新建会话种子/锚皆零，退化为旧行为；接管/前进后从当前表现值
                // 续接，手指不丢行程、带不瞬移。
                let scale = abs(session.gap) / max(session.limit, 1)
                let gridOffset = session.gestureSeed + frame.offset * scale
                updateDrawerSwipe(offset: gridOffset, inputPosition: drawerScrollTracker.accumulatedX)
                if frame.commits { endDrawerSwipe(commit: true, offset: gridOffset) }
            } else {
                updateDrawerSwipe(offset: frame.offset)
                if frame.commits { endDrawerSwipe(commit: true, offset: frame.offset) }
            }
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            // 提交门在 endDrawerSwipe 里按"手势净方向 == 条带方向"再核一道
            // （净方向取锚后增量：接管回拉时带位移仍深在目标侧，按带符号会把
            // "往回取消"读成"继续落位"）；反手滑回原点的松手天然不匹配，只
            // 弹回、不落位。
            let gestureDelta = drawerScrollTracker.netTravel
            let willCommit = drawerScrollTracker.finish(at: event.timestamp, limit: limit) != nil
            endDrawerSwipe(
                commit: willCommit,
                offset: uiState.drawerSwipe?.offset ?? 0,
                gestureDelta: gestureDelta
            )
        }
    }

    /// 拖拽通路（视图侧背景手势）的跟手帧。
    func drawerSwipeDrag(translation: CGSize) {
        // 非编辑态全区域拖动需与触控板一致让路：起始点落在横向可滚动块上时不启动切页（探针核实溢出）。
        if uiState.drawerSwipe == nil, shouldYieldMouseSwipe() { return }
        guard let side = DrawerPageSwipe.side(
            for: translation,
            threshold: DrawerPageSwipe.dragMinDistance
        ) else { return }
        beginDrawerSwipe(side)
        guard let session = uiState.drawerSwipe else { return }
        // 落位/回弹在飞：拖拽帧即接管候选（方向判定先行，横纵比不够不动带）。
        // 光标压在横向可滚动块上则让路，驱动器继续落位。
        if swipeSpringDriver.isRunning {
            if shouldYieldMouseSwipe() { return }
            grabDrawerSwipe(session, inputPosition: translation.width)
        }
        guard let swipe = uiState.drawerSwipe else { return }
        // 跟手位移 = 重锚种子 + 锚后增量 × 屏幕换算比：手指位移是屏幕总位移，
        // 需按比例映射到网格位移（gap），否则页宽差异时手指与页面距离不一致
        // （面板居中偏移导致）。接管帧锚=当前输入位、种子=当前表现值，本帧
        // 增量为零、带不瞬移。
        let scale = abs(swipe.gap) / max(swipe.limit, 1)
        let delta = translation.width - swipe.gestureAnchor
        let gridOffset = swipe.gestureSeed
            + DrawerPageSwipe.offset(translation: delta, limit: swipe.limit) * scale
        updateDrawerSwipe(offset: gridOffset, inputPosition: translation.width)
    }

    /// 鼠标拖动是否应让路给块的横向滚动（与 handleDrawerScroll 的探针一致）。
    private func shouldYieldMouseSwipe() -> Bool {
        guard let pair = activePair else { return false }
        let screenPoint = NSEvent.mouseLocation
        guard drawerElement(at: screenPoint) != nil else { return false }
        let window = pair.drawerPanel
        let windowPoint = NSPoint(
            x: screenPoint.x - window.frame.minX,
            y: screenPoint.y - window.frame.minY
        )
        return DrawerScrollProbe.hasHorizontalOverflowUnderCursor(in: window, cursorWindowPoint: windowPoint)
    }

    /// 拖拽通路：松手定夺（过阈值落位，否则弹回）。速度判据经 DragGesture 的
    /// 预测终点折算成"预测位移"——松手瞬间的强速度 = 预测终点越过门槛 →
    /// 落位（与触控板通路的 `velocityEstimate` 走同一份 `shouldCommit`）。
    /// 提交判据统一在**屏幕位移**域进行（`limit` 是屏幕行程），种子先折回
    /// 屏幕域再相加；传给 `endDrawerSwipe` 的条带位移留在 band 域。
    func drawerSwipeDragEnded(translation: CGSize, predictedEndTranslation: CGSize) {
        guard let session = uiState.drawerSwipe else { return }
        let scale = abs(session.gap) / max(session.limit, 1)
        let delta = translation.width - session.gestureAnchor
        let predictedDelta = predictedEndTranslation.width - session.gestureAnchor
        let deltaScreen = DrawerPageSwipe.offset(translation: delta, limit: session.limit)
        let predictedScreen = DrawerPageSwipe.offset(translation: predictedDelta, limit: session.limit)
        let seedScreen = session.gestureSeed / scale
        endDrawerSwipe(
            commit: DrawerPageSwipe.shouldCommit(
                offset: seedScreen + deltaScreen,
                limit: session.limit,
                predictedOffset: seedScreen + predictedScreen
            ),
            offset: session.gestureSeed + deltaScreen * scale,
            // 意图 = 锚后净增量（回拉反向必弹回，见 endDrawerSwipe 顶部）。
            gestureDelta: delta
        )
    }

    /// 开始一次滑动会话（**仅在无会话时创建**；动画在飞时新手势走
    /// `grabDrawerSwipe` 接管既有会话，不在此建房）。条带方向一旦建立，中途
    /// 反手绝不整会话替换——那是旧实现的病根（反手被重算成"激活页的另一侧
    /// 邻居"、尺寸起点被中间插值污染、再反手时方向相等守卫挡住换回）。反手
    /// 换绑由 `updateDrawerSwipe` 按条带位移穿越原点统一驱动，这里只负责
    /// 首次建房；推过目标页覆盖点的**前进**（连页）同在 `updateDrawerSwipe`。
    /// 目标页的**真实例**（`isPreview: false`，
    /// 走正常缓存键并回写 `drawerViewCache`）只在首次进入时构建并缓存进会话
    /// （换绑时重建一次）——每帧重建会让插件视图反复出现消失，编辑器与选区
    /// 状态首帧就废。真实例让插件副作用（监控采样、缩略图加载、DDC 枚举等）
    /// 在滑动期间预热，落位即就绪；落位时这份元素直接转正为 `drawerElements`
    /// （见 `landDrawerSwipe`），页带里的子视图身份保持、零重挂载。
    ///
    /// 会话同时冻结尺寸插值的起点与位移上限：`drawerWindowSize` /
    /// `drawerContentSize` 会在整个会话期间随进度在起止两端间插值
    /// （见 `updateDrawerSwipe`），这些量若现读就会逐帧漂移。
    func beginDrawerSwipe(_ side: DrawerPageSide) {
        guard uiState.drawerSwipe == nil else { return }
        guard canSwipeDrawerPage,
              let target = LayoutModel.neighborPage(
                  in: uiState.drawerPages,
                  active: uiState.drawerActivePage,
                  side: side
              ) else {
            uiState.drawerSwipe = nil
            return
        }
        let targetContentSize = layoutEngine.drawerContentSize(page: target)
        // gap 与留白都冻结在会话起点：落位途中指标被调整也不改条带几何。
        let spacing = DrawerPageSwipe.bandSpacing(contentPadding: GridMetrics.current.contentPadding)
        let gap = DrawerPageSwipe.gap(
            side: side,
            gridWidth: uiState.drawerContentSize.width,
            targetWidth: targetContentSize.width,
            spacing: spacing
        )
        // 手指在屏幕上的总位移 = 网格位移 + 面板居中偏移，限位需按总行程（两页平均宽度 + 留白）取，否则页宽差异大时手指与页面 1:1 跟手被打破。
        let total = (uiState.drawerContentSize.width + targetContentSize.width) / 2 + spacing
        uiState.drawerSwipe = PanelUIState.DrawerSwipe(
            originPage: uiState.drawerActivePage,
            side: side,
            targetPage: target,
            elements: buildDrawerElements(page: target),
            contentSize: targetContentSize,
            targetWindowSize: drawerWindowSize(for: activePair, page: target),
            leftColumn: layoutEngine.gridLeftColumn(page: target),
            gap: gap,
            startContentSize: uiState.drawerContentSize,
            startWindowSize: uiState.drawerWindowSize,
            // 位移上限 = 屏幕总行程（平均页宽 + 留白），保证手指移动距离 = 页面在屏幕上的总滑动距离（网格位移 + 面板居中偏移），1:1 跟手。
            limit: total,
            offset: 0
        )
        // 进入滑动「驻留期」：滑动中面板随目标页尺寸收缩，光标可能被甩到
        // 抽屉外——此时若不设防，收起任务会在落位前就挂起（0.25s 后把刚
        // 切好的页收走）。置位后鼠标在抽屉外不收起，待重入停留区再移出才
        // 正常收起（`handleMouseLocation` 清除），或点另一块屏的刘海搬走。
        cancelCollapse()
        isAwaitingDrawerReentry = true
    }

    /// 跟手位移（**不加动画**：加了就变成"追赶手指"）。面板尺寸随同一份
    /// 进度在起止两端间插值——滑动往目标页推进，面板就同步长大/缩小，
    /// 往回滑进度减小、尺寸恢复（两维都插值，与位移线性一致）。
    ///
    /// 条带位移穿越原点（死区外）时在这里完成**换绑**：方向翻到另一侧、
    /// 目标页/条带层/gap/位移上限随之更换，唯独原点锚两尺寸保持不动——
    /// 换绑只发生在 |s| ≈ 死区，旧目标页层整层在视口外、新目标页层整层
    /// 还没进视口，这一帧的层替换不可见（与落位交接同一条"像素重合"原理）。
    /// 起点尺寸若跟着换绑重冻结，回退到 0 的终点就变成中间值，抽屉尺寸
    /// 卡死（旧实现的次生缺陷）。无该侧邻居（首/末页硬边界）时条带硬停
    /// 在原点：没有可揭示的页，条带不得滑过起点。
    ///
    /// 推过**目标页覆盖点**时完成**前进**（连页）：原点推进到目标页、条带
    /// 换绑到更远邻居（见 `advanceDrawerSwipe`），手指行程经种子/锚衔接、
    /// 带不瞬移；无更远邻居则硬停在覆盖点（与首/末页边界同一语义）。
    /// `inputPosition` 是本帧的原始屏幕输入位（触控板 = 累计量、拖拽 =
    /// translation.width），前进重锚时写回会话——调用方两通路都会传。
    func updateDrawerSwipe(offset: CGFloat, inputPosition: CGFloat? = nil) {
        guard var swipe = uiState.drawerSwipe else { return }
        var s = offset
        var changed = s != swipe.offset
        if let newSide = DrawerPageSwipe.reversedSide(current: swipe.side, offset: s) {
            changed = true
            if let target = LayoutModel.neighborPage(
                in: uiState.drawerPages,
                active: swipe.originPage,
                side: newSide
            ) {
                let targetContentSize = layoutEngine.drawerContentSize(page: target)
                let spacing = DrawerPageSwipe.bandSpacing(contentPadding: GridMetrics.current.contentPadding)
                let gap = DrawerPageSwipe.gap(
                    side: newSide,
                    gridWidth: swipe.startContentSize.width,
                    targetWidth: targetContentSize.width,
                    spacing: spacing
                )
                let total = (swipe.startContentSize.width + targetContentSize.width) / 2 + spacing
                swipe.rebind(
                    side: newSide,
                    targetPage: target,
                    elements: buildDrawerElements(page: target),
                    contentSize: targetContentSize,
                    targetWindowSize: drawerWindowSize(for: activePair, page: target),
                    leftColumn: layoutEngine.gridLeftColumn(page: target),
                    gap: gap,
                    limit: total
                )
            } else {
                // 该侧没有邻居（首/末页）：硬停在原点。
                s = 0
            }
        }
        if DrawerPageSwipe.coverCrossed(offset: s, gap: swipe.gap) {
            if let advanced = advanceDrawerSwipe(swipe, pushedTo: s, inputPosition: inputPosition) {
                swipe = advanced
                s = advanced.offset
                changed = true
            } else {
                // 更远侧没有邻居：硬停在覆盖点（推不出去，橡皮筋到此为止）。
                let clamped = DrawerPageSwipe.arrivalOffset(gap: swipe.gap)
                changed = changed || clamped != s
                s = clamped
            }
        }
        guard changed else { return }
        swipe.offset = s
        let p = swipe.progress
        uiState.drawerWindowSize = DrawerPageSwipe.interpolatedSize(
            from: swipe.startWindowSize,
            to: swipe.targetWindowSize,
            progress: p
        )
        uiState.drawerContentSize = DrawerPageSwipe.interpolatedSize(
            from: swipe.startContentSize,
            to: swipe.contentSize,
            progress: p
        )
        uiState.drawerSwipe = swipe
    }

    /// 结束会话。**提交门 = 位移 × 方向双重校验**：`commit`（输入通路的判据）
    /// 之外还要求松手位移的意图方向 == 会话当前条带方向——反手滑回原点后的
    /// 松手方向必然与条带不匹配，只弹回、绝不落位到错误一侧（旧实现只认
    /// 输入通路的方向，向 B 的回摆会落到换绑后的 C）。不提交：位移弹回、
    /// 尺寸随同一进度回退到起点，回弹收敛后散场。提交：自驱弹簧把两层刚性
    /// 滑到位（目标页层落到 x=0 全覆盖、面板尺寸随同一进度插值到目标页），
    /// **收敛拍**（驱动器自己的数学触发，不依赖 `withAnimation(completion:)`
    /// ——触控板通路经 `NSPanel.sendEvent` 进来时它实测不保证触发）转正换页。
    /// 绝不能在松手那一帧就撤层 + `selectDrawerPage`：那会把撤层、位移归零与
    /// 换页全挤进同一条 spring，真机上表现为目标页原地淡出、新页再反向滑一遍。
    ///
    /// 驱动器运行中的重复 `endDrawerSwipe`（无边界设备就地提交后 `.ended`
    /// 又到）直接忽略——落位已在飞；接管（grab）会先取消驱动器，松手帧
    /// 到达时它已不在运行，本函数照常定夺。
    ///
    /// **松手意图 = 手势自身净方向（`gestureDelta`，锚后增量），不是带位移
    /// 符号**：接管续接后带位移会偏离手势方向——回拉的带仍深在目标侧，按
    /// 带符号读意图会把"往回取消"判成"对目标的再次提交"（真机：快扫提交
    /// 后回扫，带未拉回原点就重新落位到目标页）。增量反向 → 必弹回原页；
    /// 同向 → 正常落位；|增量| ≤ 换向死区（接住未推）→ 回落带位移符号兜底
    /// （触控板 finish 是增量判据、自然 bounce；拖拽按带位置就近落点）。
    func endDrawerSwipe(commit: Bool, offset: CGFloat, gestureDelta: CGFloat? = nil) {
        guard let swipe = uiState.drawerSwipe, !swipeSpringDriver.isRunning else { return }
        let intentSide = gestureDelta.map {
            DrawerPageSwipe.side(for: CGSize(width: $0, height: 0), threshold: DrawerPageSwipe.flipDeadBand)
        } ?? DrawerPageSwipe.side(forOffset: offset)
        guard commit && intentSide == swipe.side else {
            // 回弹：p → 0，插值尺寸同步回落到起点（往回滑立即恢复原大小）；
            // 收敛即散场（身份不符时收敛拍自动空跑）。
            startDrawerSwipeDriver(session: swipe, to: 0, settle: .dissolve)
            return
        }
        startDrawerSwipeDriver(
            session: swipe,
            to: DrawerPageSwipe.arrivalOffset(gap: swipe.gap),
            settle: .land
        )
    }

    /// 收尾去向：落位（转正换页 + 散场）或纯散场（回弹归位）。
    private enum DrawerSwipeSettle {
        case land
        case dissolve
    }

    /// 启动自驱弹簧：从会话当前表现值（初速零，与原 SwiftUI spring 起跳一致）
    /// 弹向目标，逐帧写表现值，收敛拍按去向转正或散场。会话身份钉进驱动器
    /// ——期间被接管/清场/换绑推进（id 不变则继续有效；前进保留 id，接管
    /// 取消后 id 仍在但驱动器已停）后各守卫自然空跑。
    private func startDrawerSwipeDriver(
        session: PanelUIState.DrawerSwipe,
        to target: CGFloat,
        settle: DrawerSwipeSettle
    ) {
        let token = session.id
        swipeSpringDriver.run(
            from: session.offset,
            to: target,
            token: token,
            onFrame: { [weak self] x in
                self?.applyDrawerSwipeFrame(x, token: token)
            },
            onSettle: { [weak self] in
                guard let self, self.uiState.drawerSwipe?.id == token else { return }
                switch settle {
                case .land:
                    self.landDrawerSwipe(session)
                case .dissolve:
                    self.dissolveDrawerSwipe(matching: token)
                }
            }
        )
    }

    /// 弹簧帧：把表现值写进会话并按同一进度插值面板尺寸（与跟手帧同一条
    /// 写入路径）。身份不符（会话已被清/换）即静默停表——驱动器由接管或
    /// 重建路径取消，这里只是最后一道防线。
    private func applyDrawerSwipeFrame(_ x: CGFloat, token: UUID) {
        guard var swipe = uiState.drawerSwipe, swipe.id == token else {
            swipeSpringDriver.cancel()
            return
        }
        swipe.offset = x
        let p = swipe.progress
        uiState.drawerWindowSize = DrawerPageSwipe.interpolatedSize(
            from: swipe.startWindowSize,
            to: swipe.targetWindowSize,
            progress: p
        )
        uiState.drawerContentSize = DrawerPageSwipe.interpolatedSize(
            from: swipe.startContentSize,
            to: swipe.contentSize,
            progress: p
        )
        uiState.drawerSwipe = swipe
    }

    /// 动画中接管（grab）：取消驱动器，以当前表现值为种子、当前输入位为锚
    /// 续接跟手。自驱弹簧每帧都把屏幕表现值写进 `swipe.offset`，种子即真实
    /// 位置——接管帧增量为零，带不瞬移；后续帧 = 种子 + 锚后增量 × 换算比。
    private func grabDrawerSwipe(_ session: PanelUIState.DrawerSwipe, inputPosition: CGFloat) {
        swipeSpringDriver.cancel()
        var grabbed = session
        grabbed.gestureSeed = session.offset
        grabbed.gestureAnchor = inputPosition
        uiState.drawerSwipe = grabbed
        // 触控板通路的输入锚同步钉下（拖拽通路的锚在 `gestureAnchor`）。
        drawerScrollTracker.reanchor()
    }

    /// 覆盖点前进（连页）：条带被推过目标页覆盖点且更远侧有邻居时，原点
    /// 推进到目标页、条带换绑到该邻居，一次手势继续跟手吃掉下一页。前进帧
    /// 与落位拍同一事务语义——目标页真实例就地转正（同一 ForEach 身份、
    /// 零重挂载）、逻辑换页，此刻基座网格与页带目标层像素完全重合、旧原点
    /// 页整层在视口外、新目标页整层在视口外，交接不可见。位移经
    /// `advanceCarry` 像素连续衔接（新带原点 = 旧目标页），输入锚与种子同步
    /// 重置，手指行程不丢。返回前进后的会话；无更远邻居返回 nil（调用方
    /// 硬停在覆盖点）。
    private func advanceDrawerSwipe(
        _ swipe: PanelUIState.DrawerSwipe,
        pushedTo offset: CGFloat,
        inputPosition: CGFloat?
    ) -> PanelUIState.DrawerSwipe? {
        guard let nextPage = LayoutModel.neighborPage(
            in: uiState.drawerPages,
            active: swipe.targetPage,
            side: swipe.side
        ) else { return nil }
        let targetContentSize = layoutEngine.drawerContentSize(page: nextPage)
        let spacing = DrawerPageSwipe.bandSpacing(contentPadding: GridMetrics.current.contentPadding)
        let carry = DrawerPageSwipe.advanceCarry(offset: offset, gap: swipe.gap)
        uiState.drawerActivePage = swipe.targetPage
        uiState.drawerGridLeftColumn = swipe.leftColumn
        uiState.drawerElements = swipe.elements
        var advanced = swipe
        advanced.originPage = swipe.targetPage
        // 原点锚重冻结在前进帧的插值终点上：此刻 p=1、尺寸恰为目标页值，
        // 起点与终点重合自洽（反手换绑不得重冻结的禁令不适用于前进——
        // 那是"中途值当起点"的坑，这里是"整值换锚"）。
        advanced.startContentSize = swipe.contentSize
        advanced.startWindowSize = swipe.targetWindowSize
        advanced.rebind(
            side: swipe.side,
            targetPage: nextPage,
            elements: buildDrawerElements(page: nextPage),
            contentSize: targetContentSize,
            targetWindowSize: drawerWindowSize(for: activePair, page: nextPage),
            leftColumn: layoutEngine.gridLeftColumn(page: nextPage),
            gap: DrawerPageSwipe.gap(
                side: swipe.side,
                gridWidth: swipe.contentSize.width,
                targetWidth: targetContentSize.width,
                spacing: spacing
            ),
            limit: (swipe.contentSize.width + targetContentSize.width) / 2 + spacing
        )
        advanced.gestureSeed = carry
        if let inputPosition { advanced.gestureAnchor = inputPosition }
        advanced.offset = carry
        drawerScrollTracker.reanchor()
        uiState.drawerSwipe = advanced
        return advanced
    }

    /// 落位收敛拍：换页**不加动画**（目标页层恰好落在 x=0，窗口尺寸已在
    /// 弹簧里到目标值——这一帧不动任何尺寸，整帧保持非动画帧）。元素
    /// **沿用会话里的目标页真实例**（`session.elements`，与页带里正在显示的
    /// 是同一份视图值），不做 `buildDrawerElements` 重建：单一页带结构
    /// （`DrawerPanelView.pageSlide`）里这些子视图的 ForEach 身份保持不变，
    /// 落位零重挂载；随后的 `rebuildContentAfterPageChange` 按缓存键复用同一
    /// 批视图值（会话构建时已回写缓存），同样无可见交接。同一事务内散场
    /// （清会话 + 重建）：会话即清即走，无输入锁定期。
    private func landDrawerSwipe(_ session: PanelUIState.DrawerSwipe) {
        guard uiState.drawerSwipe?.id == session.id else { return }
        guard session.targetPage != uiState.drawerActivePage else {
            dissolveDrawerSwipe(matching: session.id)
            return
        }
        uiState.drawerActivePage = session.targetPage
        uiState.drawerGridLeftColumn = session.leftColumn
        // 直接沿用会话真实例：一旦重建就换掉视图身份，页带里的目标页子视图
        // 会在落位帧整批重挂（暂存区缩略图归零回退图标、监控重挂探针的
        // 落位闪烁根因）。
        uiState.drawerElements = session.elements
        dissolveDrawerSwipe(matching: session.id)
    }

    /// 散场：清会话 + 重建。身份守卫保证只清当初那一次（期间被前进换绑的
    /// 会话 id 不变，仍算同一次；被接管续接的同理）。
    private func dissolveDrawerSwipe(matching token: UUID) {
        guard uiState.drawerSwipe?.id == token else { return }
        uiState.drawerSwipe = nil
        rebuildContentAfterPageChange()
    }

    /// 新增页面并切换过去（胶囊行首/行尾的加号）。
    func addDrawerPage(_ side: DrawerPageSide) {
        guard layoutEngine.canAddDrawerPage() else { return }
        let page = layoutEngine.addDrawerPage(side)
        uiState.drawerActivePage = page
        rebuildContentAfterPageChange()
    }

    /// 拖动排序：把页面移到显示序列的目标槽位。只改次序，块上的 `page` 不动。
    /// 提交与预览同帧瞬移，避免基座 spring 与让位 spring 叠加成二次排序交换动画（见 DrawerPageCapsule.onDragCommit）。
    func moveDrawerPage(from page: Int, to targetIndex: Int) {
        guard layoutEngine.moveDrawerPage(from: page, to: targetIndex) else { return }
        rebuildContent(animated: false)
    }

    /// 重命名页面（空串 = 清除自定义名，回落为序号）。
    func renameDrawerPage(_ page: Int, title: String) {
        layoutEngine.setDrawerPageTitle(page: page, title: title)
        rebuildContent()
    }

    /// 设置页面图标（SF Symbol 名；空串 = 清除，主页回落房子、其余页纯文本）。
    func setPageIcon(_ page: Int, icon: String) {
        layoutEngine.setDrawerPageIcon(page: page, icon: icon)
        rebuildContent()
    }

    /// 页面设置浮窗（分页胶囊齿轮角标触发）：名称即时生效 + 图标宫格点选。
    /// 胶囊在屏幕顶端，`.below` 贴下方弹出（与紧凑图标同一摆放理由）。
    func showPageSettings(page: Int, anchorFrame: CGRect) {
        // 回落图标 = 清除自定义后的有效图标（主页房子、其余页 nil），
        // 借空 icons 字典让 `pageIcon` 保持唯一解析点。
        let fallbackIcon = LayoutModel.pageIcon(page: page, icons: [:])
        SettingPopover.shared.present(
            anchoredTo: anchorFrame,
            placement: .below,
            title: L("panel.page.settings.title")
        ) {
            DrawerPageSettingsPopover(
                title: layoutEngine.drawerPageTitle(page) ?? "",
                icon: layoutEngine.drawerPageIcon(page),
                fallbackIcon: fallbackIcon,
                onTitleChange: { [weak self] in self?.renameDrawerPage(page, title: $0) },
                onIconChange: { [weak self] in self?.setPageIcon(page, icon: $0) }
            )
        }
    }

    /// 删除页面：连同页内的块一起移除。块里可能装着用户的笔记内容，
    /// 因此非空页先二次确认（与插件卸载同一套确认样式）。
    func removeDrawerPage(_ page: Int) {
        let pages = layoutEngine.drawerPages
        guard page != LayoutModel.homePage, pages.contains(page) else { return }
        let blocks = layoutEngine.drawerBlocks(onPage: page)
        // 锚定在该页某块上的设置浮窗先收场（与删单个块同一路径）。
        SettingPopover.shared.dismiss()
        if !blocks.isEmpty, !confirmDeletePage(page, blockCount: blocks.count) { return }

        for block in blocks {
            notifyPlacementRemoved(
                pluginID: block.pluginID,
                blockID: block.blockID,
                placementID: block.placementID
            )
        }
        // 删页前的相邻页即回落脚：右邻优先，最右页则回落左邻。
        let fallback = LayoutModel.neighborPage(in: pages, active: page, side: .right)
            ?? LayoutModel.neighborPage(in: pages, active: page, side: .left)
            ?? LayoutModel.homePage
        guard layoutEngine.removeDrawerPage(page: page) != nil else { return }
        if uiState.drawerActivePage == page {
            uiState.drawerActivePage = fallback
        }
        rebuildContent(animated: true)
    }

    private func confirmDeletePage(_ page: Int, blockCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = LF(
            "panel.page.delete.confirmTitle",
            LayoutModel.pageDisplayName(in: layoutEngine.drawerPages, page: page, titles: layoutEngine.drawerPageTitles)
        )
        alert.informativeText = LF("panel.page.delete.confirmBody", blockCount)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("panel.page.delete"))
        alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 抽屉拖拽 / 缩放与引擎之间的接口（由 `DrawerInteractionState` 驱动）。
    ///
    /// 与 `DrawerActions` 分开：这些回调承载"预览即最终布局"的时序契约，
    /// 需要能被测试用假实现整组替换。
    func drawerInteractionBridge() -> DrawerInteractionState.Bridge {
        DrawerInteractionState.Bridge(
            previewMove: { [weak self] placementID, column, row in
                self?.applyDrawerDrag(
                    placementID: placementID,
                    column: column,
                    row: row,
                    phase: .preview
                ) ?? [:]
            },
            previewResize: { [weak self] placementID, columns, rows in
                self?.applyDrawerResize(
                    placementID: placementID,
                    columns: columns,
                    rows: rows,
                    phase: .preview
                ) ?? [:]
            },
            commitMove: { [weak self] placementID, column, row in
                self?.applyDrawerDrag(
                    placementID: placementID,
                    column: column,
                    row: row,
                    phase: .commit
                )
            },
            commitResize: { [weak self] placementID, columns, rows in
                self?.applyDrawerResize(
                    placementID: placementID,
                    columns: columns,
                    rows: rows,
                    phase: .commit
                )
            },
            setReorderPreview: { [weak self] origin, span in
                self?.updateDrawerReorderPreview(origin, span: span)
            },
            capsulePage: { [weak self] point in
                self?.drawerPageCapsuleHitTest(at: point)
            },
            crossPageMove: { [weak self] placementID, column, row, page in
                self?.moveDraggedBlockCrossPage(
                    placementID: placementID,
                    column: column,
                    row: row,
                    page: page
                )
            }
        )
    }

    // MARK: - 放置实例生命周期（每实例状态基本能力的清理侧）

    /// 通知插件某放置实例已被移除（NotchCenterPluginServices.placementWasRemoved，
    /// 默认空实现）：插件借此清理该实例 placementStore 里的持久化数据。
    private func notifyPlacementRemoved(_ reference: CompactSlotReference) {
        notifyPlacementRemoved(
            pluginID: reference.pluginID,
            blockID: reference.blockID,
            placementID: reference.placementID
        )
    }

    private func notifyPlacementRemoved(pluginID: String, blockID: String, placementID: String) {
        (pluginManager.entry(for: pluginID)?.instance as? any NotchCenterPluginServices)?
            .placementWasRemoved(blockID: blockID, placementID: placementID)
    }

    // MARK: - 插件设置浮窗（编辑模式齿轮按钮的统一入口）

    /// 经 Kit 的 SettingPopover 展示设置：优先块的实例级 `instanceSettingsView`
    /// （携带完整 BlockContext，含 placementID / placementStore，多个放置实例
    /// 可各自单独设置），块未声明时回退插件级 `settingsView`（文档 §4.7）。
    /// 本方法只负责解析上下文与锚定。
    func showPluginSettings(
        pluginID: String,
        placementID: String,
        anchorFrame: CGRect,
        placement: BlockPopoverPlacement
    ) {
        guard let entry = pluginManager.entry(for: pluginID),
              let instance = entry.instance,
              let stateStore = entry.stateStore else {
            return
        }

        // 解析锚定块的引用信息（blockID 与所在区域），构建完整 BlockContext。
        let drawerPlacement = layoutEngine.drawerBlocks.first { $0.placementID == placementID }
        let compactSlot = layoutEngine.compactSlot(withPlacementID: placementID)
        let blockID = drawerPlacement?.blockID ?? compactSlot?.blockID
        guard let blockID,
              let block = pluginManager.block(pluginID: pluginID, blockID: blockID) else {
            return
        }
        let region: BlockRegion = drawerPlacement != nil ? .drawer : .compact
        let context = BlockContext(
            pluginID: pluginID,
            blockID: blockID,
            placementID: placementID,
            stateStore: stateStore,
            hostController: self,
            layoutInfo: BlockLayoutInfo(
                region: region,
                placementID: placementID,
                frame: anchorFrame,
                isEditing: isEditing
            )
        )

        if let instanceSettingsView = block.instanceSettingsView {
            SettingPopover.shared.present(
                anchoredTo: anchorFrame,
                placement: placement,
                title: entry.metadata.displayName
            ) {
                instanceSettingsView(context)
            }
        } else if let settingsView = instance.settingsView {
            SettingPopover.shared.present(
                anchoredTo: anchorFrame,
                placement: placement,
                title: entry.metadata.displayName
            ) {
                settingsView(context.settingsContext)
            }
        }
    }
}
