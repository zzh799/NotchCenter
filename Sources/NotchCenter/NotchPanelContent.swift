import AppKit
import NotchCenterKit
import SwiftUI

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
            pair.islandHostingView?.needsDisplay = true
        }

        // 设置面板贴挂在抽屉底缘：抽屉高度变化（增删块、网格指标调整、
        // 进入编辑模式）后面板必须跟着重新对齐。
        if isSettingsPresented {
            positionSettingsWindow()
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

        if pair.islandHostingView == nil {
            let host = IslandHostingView(
                rootView: ActivityIslandPanelView(
                    ui: uiState,
                    onVisibleSizeChange: { [weak self] size in
                        self?.uiState.islandVisibleSize = size
                    }
                )
            )
            host.visibleSizeProvider = { [weak self] in
                self?.uiState.islandVisibleSize ?? .zero
            }
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            pair.islandPanel.contentView = host
            pair.islandHostingView = host
        }
    }

    private func buildCompactElements(layout: NotchLayout) -> [CompactElement] {
        (0..<compactIconCount).map { index in
            let frame = compactSlotFrame(index: index, layout: layout, slotCount: compactIconCount)
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
                    frame: frame,
                    hasSettings: false
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
                frame: frame,
                hasSettings: block.instanceSettingsView != nil
                    || entry.instance?.settingsView != nil
            )
        }
    }

    /// 构建某页的抽屉块元素；`isPreview` 原样透传给插件（契约见 `BlockLayoutInfo.isPreview`）。
    private func buildDrawerElements(
        page: Int? = nil,
        isPreview: Bool = false
    ) -> [DrawerElement] {
        let targetPage = page ?? uiState.drawerActivePage
        return layoutEngine.drawerBlocks(onPage: targetPage).compactMap { placement in
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
                    isEditing: isEditing,
                    isPreview: isPreview
                )
            )
            return DrawerElement(
                placement: placement,
                view: block.makeView(context),
                supportedSpans: block.supportedSpans.sorted { lhs, rhs in
                    lhs.columns == rhs.columns ? lhs.rows < rhs.rows : lhs.columns < rhs.columns
                },
                currentSpan: currentSpan,
                hasSettings: block.instanceSettingsView != nil
                    || entry.instance?.settingsView != nil
            )
        }
    }

    /// 槽位矩形（窗口内容坐标，左上原点）；与视图共享同一 strip 布局。
    /// 宽度随当前紧凑图标数动态伸缩。
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
                self.isPinned.toggle()
                // 立即重建：顶部按钮（钉住图标）与实际状态保持一致。
                self.rebuildContent()
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
            },
            onReorderBlocks: { [weak self] in
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
            onRenamePage: { [weak self] page, title in
                self?.renameDrawerPage(page, title: title)
            },
            onRemovePage: { [weak self] page in
                self?.removeDrawerPage(page)
            },
            onSwipeDrag: { [weak self] translation in
                self?.drawerSwipeDrag(translation: translation)
            },
            onSwipeDragEnded: { [weak self] translation in
                self?.drawerSwipeDragEnded(translation: translation)
            }
        )
    }

    // MARK: 抽屉页面

    /// 切页是否安全（分页胶囊与左右滑动共用）：切页会整屏换掉抽屉内容，
    /// 而落位飞行、跨窗口拖拽与设置面板的落点预览都按**当前页**计算，
    /// 中途换页会让它们把结果写到错的页上。
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
        rebuildContent(animated: true)
    }

    /// 滑动切页是否可用：`canSwitchDrawerPage` 之外再排除编辑模式（块的
    /// 拖拽/缩放预览按激活页计算，中途切页会把预览提交到错的页上，编辑期
    /// 仍以分页胶囊切页）与落位拍（滑到位动画只有唯一一个 offset 可写）。
    private var canSwipeDrawerPage: Bool {
        !uiState.isEditing && canSwitchDrawerPage && uiState.drawerSwipe?.isLanding != true
    }

    /// 位移上限 = 当前页宽（滑到刚好覆盖整页）。
    private var drawerSwipeLimit: CGFloat { max(uiState.drawerContentSize.width, 1) }

    func handleDrawerScroll(_ event: NSEvent) {
        let phase = event.phase
        // 过滤：非精确增量是鼠标滚轮（只有纵向）；惯性尾巴足以再翻一页；
        // `.mayBegin` 试探事件不喂（随后的 `.began` 会重置，喂了能一次翻两页）。
        // 坑：`momentumPhase.isEmpty` 不能写成 `== .none`——`NSEvent.MomentumPhase`
        // 没有 `none` 成员，`.none` 会被解析成 `Optional.none` 再隐式提升比较，
        // 恒为 false（真机上表现为横向轻扫全部失效）。
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              !phase.contains(.mayBegin), canSwipeDrawerPage else { return }

        let limit = drawerSwipeLimit
        // 光标落在块上时让路：横向增量属于块自己（文件架横向滚动、编辑器选字）。
        // 判据走格网几何——实测 SwiftUI 的 ScrollView 在 AppKit 命中链上拿不到
        // `NSScrollView`，"文档视图宽于视口"那条例外从未命中。
        if let window = event.window,
           isPointOverDrawerBlock(window.convertPoint(toScreen: event.locationInWindow)) {
            drawerScrollTracker.reset()
            endDrawerSwipe(commit: false)
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
            updateDrawerSwipe(offset: frame.offset)
            if frame.commits { endDrawerSwipe(commit: true) }
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            endDrawerSwipe(commit: drawerScrollTracker.finish(at: event.timestamp, limit: limit) != nil)
        }
    }

    /// 拖拽通路（视图侧背景手势）的跟手帧。
    func drawerSwipeDrag(translation: CGSize) {
        guard let side = DrawerPageSwipe.side(
            for: translation,
            threshold: DrawerPageSwipe.dragMinDistance
        ) else { return }
        beginDrawerSwipe(side)
        updateDrawerSwipe(offset: DrawerPageSwipe.offset(
            translation: translation.width,
            limit: drawerSwipeLimit
        ))
    }

    /// 拖拽通路：松手定夺（过阈值落位，否则弹回）。
    func drawerSwipeDragEnded(translation: CGSize) {
        let offset = DrawerPageSwipe.offset(translation: translation.width, limit: drawerSwipeLimit)
        endDrawerSwipe(commit: DrawerPageSwipe.shouldCommit(offset: offset, limit: drawerSwipeLimit))
    }

    /// 开始／维持一次滑动会话。目标页的只读预览副本（`isPreview` = true）只在
    /// 首次进入时构建并缓存进会话——每帧重建会让插件视图反复出现消失，
    /// 编辑器与选区状态首帧就废。
    func beginDrawerSwipe(_ side: DrawerPageSide) {
        guard uiState.drawerSwipe?.side != side else { return }
        // 上一次提交的滑到位动画还在跑：本次手势整个忽略（不能走下面的
        // else 分支，那会把正在滑入的会话层清掉，表现为半路凭空消失）。
        guard uiState.drawerSwipe?.isLanding != true else { return }
        guard canSwipeDrawerPage,
              let target = LayoutModel.neighborPage(
                  in: uiState.drawerPages,
                  active: uiState.drawerActivePage,
                  side: side
              ) else {
            uiState.drawerSwipe = nil
            return
        }
        let targetSize = layoutEngine.drawerContentSize(page: target)
        uiState.drawerSwipe = PanelUIState.DrawerSwipe(
            side: side,
            targetPage: target,
            elements: buildDrawerElements(page: target, isPreview: true),
            contentSize: targetSize,
            leftColumn: layoutEngine.gridLeftColumn(page: target),
            gap: DrawerPageSwipe.gap(
                side: side,
                gridWidth: uiState.drawerContentSize.width,
                targetWidth: targetSize.width
            ),
            offset: 0
        )
    }

    /// 跟手位移（**不加动画**：加了就变成"追赶手指"）。
    func updateDrawerSwipe(offset: CGFloat) {
        guard var swipe = uiState.drawerSwipe, !swipe.isLanding, swipe.offset != offset else { return }
        swipe.offset = offset
        uiState.drawerSwipe = swipe
    }

    /// 结束会话。不提交：位移弹回，回弹动画结束后再撤层。
    /// 提交：**分两拍**——先把两层刚性滑到位（预览层落到 x=0 全覆盖）才换页。
    /// 绝不能在松手那一帧就撤层 + `selectDrawerPage`：那会把撤层、位移归零与
    /// 换页全挤进同一条 spring，真机上表现为目标页原地淡出、新页再反向滑一遍。
    func endDrawerSwipe(commit: Bool) {
        guard let swipe = uiState.drawerSwipe, !swipe.isLanding else { return }
        guard commit else {
            withAnimation(DrawerAnimation.spring, completionCriteria: .logicallyComplete) {
                updateDrawerSwipe(offset: 0)
            } completion: { [weak self] in
                // 期间可能已经开始下一次手势或整层被重建清掉——只清属于本次会话、
                // 且位移确实已归零的那份（否则会把刚被重新推开的滑动凭空撤掉）。
                guard self?.uiState.drawerSwipe?.targetPage == swipe.targetPage,
                      self?.uiState.drawerSwipe?.offset == 0 else { return }
                self?.uiState.drawerSwipe = nil
            }
            return
        }
        var landing = swipe
        landing.isLanding = true
        withAnimation(DrawerAnimation.spring, completionCriteria: .logicallyComplete) {
            landing.offset = DrawerPageSwipe.arrivalOffset(gap: swipe.gap)
            self.uiState.drawerSwipe = landing
        } completion: { [weak self] in
            self?.landDrawerSwipe(landing)
        }
    }

    /// 落位第二拍：换页与撤层**都不加动画**，靠像素重合藏住交接（网格已是目标页
    /// 真实例，预览层恰好落在 x=0）。视图侧据此在会话挂载期关掉换页淡入（见
    /// `DrawerPanelView.grid`）。尺寸必须留到下一拍：这一帧动它会把整帧变成动画帧。
    private func landDrawerSwipe(_ session: PanelUIState.DrawerSwipe) {
        guard uiState.drawerSwipe?.isLanding == true,
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
        uiState.drawerSwipe = landed
        DispatchQueue.main.async { [weak self] in
            // 尺寸换成新页（同一条 spring）并撤掉预览层——此时它已在屏外，撤层不可见。
            self?.rebuildContent(animated: true)
        }
    }

    /// 新增页面并切换过去（胶囊行首/行尾的加号）。
    func addDrawerPage(_ side: DrawerPageSide) {
        guard layoutEngine.canAddDrawerPage() else { return }
        let page = layoutEngine.addDrawerPage(side)
        uiState.drawerActivePage = page
        rebuildContent(animated: true)
    }

    /// 拖动排序：把页面移到显示序列的目标槽位。只改次序，块上的 `page` 不动。
    func moveDrawerPage(from page: Int, to targetIndex: Int) {
        guard layoutEngine.moveDrawerPage(from: page, to: targetIndex) else { return }
        rebuildContent(animated: true)
    }

    /// 重命名页面（空串 = 清除自定义名，回落为序号）。
    func renameDrawerPage(_ page: Int, title: String) {
        layoutEngine.setDrawerPageTitle(page: page, title: title)
        rebuildContent()
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
