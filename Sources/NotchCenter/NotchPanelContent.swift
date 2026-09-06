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
                  block.kind == .drawer,
                  let store = entry.stateStore else {
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
                    size: nil,
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
            // 键逐项相等 → 复用上一次的视图值（切页往返、预览层重复构建等
            // 场景不再反复重挂插件视图；placementID 全局唯一，跨页不会误配）。
            let view: AnyView
            if let old = drawerViewCache[placement.placementID], old.key == key {
                view = old.view
            } else {
                view = block.makeView(context)
            }
            cache[placement.placementID] = (key, view)
            elements.append(DrawerElement(
                placement: placement,
                view: view,
                supportedSpans: block.supportedSpans.sorted { lhs, rhs in
                    lhs.columns == rhs.columns ? lhs.rows < rhs.rows : lhs.columns < rhs.columns
                },
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
    /// （块的推挤预览按激活页计算，中途切页会把预览提交到错的页上）与落位拍
    /// （滑到位动画只有唯一一个 offset 可写）。编辑模式本身不再禁用滑动——
    /// 空隙上的拖拽与触控板轻扫与非编辑态一致跟手切页，块拖拽/缩放期间则暂停
    /// 切页，松手后恢复（`isDrawerInteractionActive` 由 DrawerPanelView 的
    /// DrawerInteractionState 经 PanelUIState 同步）。
    private var canSwipeDrawerPage: Bool {
        canSwitchDrawerPage
            && !uiState.isDrawerInteractionActive
            && uiState.drawerSwipe?.isLanding != true
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
        // 探针从窗口 contentView 向下 DFS，不依赖命中链（SwiftUI 在宿主视图层
        // 接管事件，hitTest 到不了内部滚动机构，旧的"沿 superview 向上找
        // NSScrollView"实测恒 false，勿改回）。最低支持 macOS 15（SwiftUI 内部
        // 滚动机构已实测），"没找到 → 放行"的反向推断可信。
        if let window = event.window,
           drawerElement(at: window.convertPoint(toScreen: event.locationInWindow)) != nil,
           DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
               in: window,
               cursorWindowPoint: event.locationInWindow) {
            yieldDrawerSwipeToBlock()
            return
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
                // 触控板累加量是屏幕总位移，需映射到网格位移以保持与鼠标 1:1 一致（面板居中偏移）。
                let gridOffset = frame.offset * (abs(session.gap) / max(session.limit, 1))
                updateDrawerSwipe(offset: gridOffset)
                if frame.commits { endDrawerSwipe(commit: true, offset: gridOffset) }
            } else {
                updateDrawerSwipe(offset: frame.offset)
                if frame.commits { endDrawerSwipe(commit: true, offset: frame.offset) }
            }
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            // 提交门在 endDrawerSwipe 里按"松手位移的意图方向 == 条带方向"
            // 再核一道：反手滑回原点的松手只弹回、不落位。
            let willCommit = drawerScrollTracker.finish(at: event.timestamp, limit: limit) != nil
            endDrawerSwipe(commit: willCommit, offset: uiState.drawerSwipe?.offset ?? 0)
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
        // 手指位移是屏幕总位移，需按比例映射到网格位移（gap），否则页宽差异时手指与页面距离不一致（面板居中偏移导致）。
        let totalOffset = DrawerPageSwipe.offset(translation: translation.width, limit: session.limit)
        let gridOffset = totalOffset * (abs(session.gap) / max(session.limit, 1))
        updateDrawerSwipe(offset: gridOffset)
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
    func drawerSwipeDragEnded(translation: CGSize, predictedEndTranslation: CGSize) {
        guard let session = uiState.drawerSwipe else { return }
        let totalOffset = DrawerPageSwipe.offset(translation: translation.width, limit: session.limit)
        let totalPredicted = DrawerPageSwipe.offset(translation: predictedEndTranslation.width, limit: session.limit)
        let gridOffset = totalOffset * (abs(session.gap) / max(session.limit, 1))
        endDrawerSwipe(
            commit: DrawerPageSwipe.shouldCommit(
                offset: totalOffset,
                limit: session.limit,
                predictedOffset: totalPredicted
            ),
            offset: gridOffset
        )
    }

    /// 开始一次滑动会话（**仅在无会话时创建**）。条带方向一旦建立，中途反手
    /// 绝不整会话替换——那是旧实现的病根（反手被重算成"激活页的另一侧邻居"、
    /// 尺寸起点被中间插值污染、再反手时方向相等守卫挡住换回）。反手换绑由
    /// `updateDrawerSwipe` 按条带位移穿越原点统一驱动，这里只负责首次建房；
    /// 落位拍进行中会话仍在，任何新方向都会被这一行拦下（"本次手势整个忽略"，
    /// 且绝不会清掉正在滑入的会话层）。目标页的只读预览副本（`isPreview` =
    /// true）只在首次进入时构建并缓存进会话（换绑时重建一次）——每帧重建
    /// 会让插件视图反复出现消失，编辑器与选区状态首帧就废。
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
            elements: buildDrawerElements(page: target, isPreview: true),
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
    /// 目标页/预览层/gap/位移上限随之更换，唯独原点锚两尺寸保持不动——
    /// 换绑只发生在 |s| ≈ 死区，旧预览层整层在视口外、新预览层整层还没
    /// 进视口，这一帧的层替换不可见（与落位交接同一条"像素重合"原理）。
    /// 起点尺寸若跟着换绑重冻结，回退到 0 的终点就变成中间值，抽屉尺寸
    /// 卡死（旧实现的次生缺陷）。无该侧邻居（首/末页硬边界）时条带硬停
    /// 在原点：没有可揭示的页，条带不得滑过起点。
    func updateDrawerSwipe(offset: CGFloat) {
        guard var swipe = uiState.drawerSwipe, !swipe.isLanding else { return }
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
                    elements: buildDrawerElements(page: target, isPreview: true),
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
    /// 尺寸随同一进度回退到起点，回弹动画结束后再撤层。提交：**分两拍**——
    /// 先把两层刚性滑到位（预览层落到 x=0 全覆盖、面板尺寸在同一条 spring
    /// 里插值到目标页）才换页。
    /// 绝不能在松手那一帧就撤层 + `selectDrawerPage`：那会把撤层、位移归零与
    /// 换页全挤进同一条 spring，真机上表现为目标页原地淡出、新页再反向滑一遍。
    ///
    /// **收尾拍必须另挂兜底时钟**：触控板通路经 `NSPanel.sendEvent`（AppKit
    /// 上下文）进来，`withAnimation(completion:)` 的 completion 实测不保证在
    /// 动画结束时触发——会被推迟到之后某次 SwiftUI 更新才冲刷，期间无人
    /// 再动这些状态就**永不触发**，会话以 `isLanding` 卡死：胶囊点击被视图层
    /// `isSwipeActive` 丢弃、滑动被 `canSwipeDrawerPage` 拦截，两条输入同时
    /// 失效（真机复现）。spring 的逻辑收敛远早于限时，completion 正常到达时
    /// 兜底空跑（`landDrawerSwipe` 与清除守卫幂等）；回弹分支的兜底逐项复核
    /// "仍是那一次回弹"才清。
    func endDrawerSwipe(commit: Bool, offset: CGFloat) {
        guard let swipe = uiState.drawerSwipe, !swipe.isLanding else { return }
        guard commit && DrawerPageSwipe.side(forOffset: offset) == swipe.side else {
            withAnimation(DrawerAnimation.spring, completionCriteria: .logicallyComplete) {
                // p → 0：插值尺寸同步回落到起点（往回滑立即恢复原大小）。
                updateDrawerSwipe(offset: 0)
            } completion: { [weak self] in
                // 期间可能已经开始下一次手势或整层被重建清掉——只清属于本次会话、
                // 且位移确实已归零的那份（否则会把刚被重新推开的滑动凭空撤掉）。
                guard self?.uiState.drawerSwipe?.targetPage == swipe.targetPage,
                      self?.uiState.drawerSwipe?.offset == 0 else { return }
                self?.uiState.drawerSwipe = nil
            }
            scheduleDrawerSwipeSettle(swipe, isLanding: false)
            return
        }
        var landing = swipe
        landing.isLanding = true
        withAnimation(DrawerAnimation.spring, completionCriteria: .logicallyComplete) {
            // 位移与尺寸同一条 spring 滑向终点：线性弹簧的中间帧对两个终点
            // 是同一仿射解，落位动画全程"尺寸进度 ≡ 位移进度"。
            landing.offset = DrawerPageSwipe.arrivalOffset(gap: swipe.gap)
            uiState.drawerWindowSize = swipe.targetWindowSize
            uiState.drawerContentSize = swipe.contentSize
            self.uiState.drawerSwipe = landing
        } completion: { [weak self] in
            self?.landDrawerSwipe(landing)
        }
        scheduleDrawerSwipeSettle(landing, isLanding: true)
    }

    /// 落位/回弹收尾的宽限期：必须晚于 spring 的逻辑收敛（completion 正常
    /// 时第二拍已由它做完），又不能拖太久（宽限期内新滑动被 `isLanding`
    /// 挡住）。spring(0.3 / 0.86) 视觉收敛约 0.5s，取 0.75s 留余量。
    private static let drawerSwipeSettleGrace: TimeInterval = 0.75

    /// 收尾兜底时钟（见 `endDrawerSwipe` 顶部说明）：到期时逐项复核"仍是
    /// 当初那一次收尾"——目标页、条带方向、landing/回弹身份都未变，且期间
    /// 没有换绑/重建清场/新手势改写会话——才补上同一拍；否则空跑。
    private func scheduleDrawerSwipeSettle(
        _ session: PanelUIState.DrawerSwipe,
        isLanding: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drawerSwipeSettleGrace) { [weak self] in
            guard let self,
                  let current = self.uiState.drawerSwipe,
                  current.targetPage == session.targetPage,
                  current.side == session.side,
                  current.isLanding == isLanding else { return }
            if isLanding {
                self.landDrawerSwipe(session)
            } else if current.offset == 0 {
                self.uiState.drawerSwipe = nil
            }
        }
    }

    /// 落位第二拍：换页与撤层**都不加动画**，靠像素重合藏住交接（网格已是目标页
    /// 真实例，预览层恰好落在 x=0，窗口尺寸也已在第一拍的 spring 里到目标值——
    /// 这一帧不动任何尺寸，整帧保持非动画帧）。视图侧据此在会话挂载期关掉换页
    /// 淡入（见 `DrawerPanelView.grid`），并按 `isLanded` 就地撤掉预览层。收尾交给
    /// 下一拍 `rebuildContent(animated: true)`（写入与当前相同的尺寸，无可见动画）。
    /// completion 与兜底时钟都可能送达本拍：`isLanded` 守卫保证只执行一次。
    private func landDrawerSwipe(_ session: PanelUIState.DrawerSwipe) {
        guard uiState.drawerSwipe?.isLanding == true,
              uiState.drawerSwipe?.isLanded != true,
              uiState.drawerSwipe?.targetPage == session.targetPage else { return }
        guard session.targetPage != uiState.drawerActivePage else {
            uiState.drawerSwipe = nil
            return
        }
        uiState.drawerActivePage = session.targetPage
        uiState.drawerGridLeftColumn = session.leftColumn
        uiState.drawerElements = buildDrawerElements(page: session.targetPage)
        var landed = session
        landed.offset = 0
        landed.isLanded = true
        uiState.drawerSwipe = landed
        DispatchQueue.main.async { [weak self] in
            // 收尾清会话：预览层已在落位帧撤除，这里的 animated 清理无可见层。
            self?.rebuildContentAfterPageChange()
        }
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
