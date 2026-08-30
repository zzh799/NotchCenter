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
        SettingsSwitchProbe.measure("applyEditMode") {
            // 编辑模式视觉（顶栏按钮切换、提示标签、块编辑 chrome）全部由
            // `ui.isEditing` 驱动，且没有任何块视图读取 layoutInfo.isEditing，
            // 这里只翻转状态、不做全量块视图重建（编辑期的增删/移动/缩放各自
            // 已走 refreshAfterEdit 全量路径；进出编辑本身不改变任何布局数据
            // 与窗口尺寸）。全量重建是设置面板切页卡顿的来源之一。
            withAnimation(DrawerAnimation.spring) {
                isEditing = true
            }
        }
    }

    /// 由 HostController.exitEditMode / 视图动作调用。
    /// 高度收缩由内容 spring + 窗口逐帧跟随完成（syncDrawerFrame）。
    func stopEditMode() {
        SettingsSwitchProbe.measure("stopEditMode") {
            guard isEditing else { return }
            // 退出编辑时锚定块可能消失/移位，设置浮窗先随编辑态一起收场。
            SettingPopover.shared.dismiss()
            // 只翻转状态（同 applyEditMode：视觉全由 ui.isEditing 驱动，
            // 不做全量块视图重建）。
            withAnimation(DrawerAnimation.spring) {
                isEditing = false
            }
        }
        if !isPinned {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    /// 设置面板切到 / 离开「组件」页：组件页期间抽屉进入编辑模式——从页内
    /// 拖进来的组件落位后即可继续拖动、缩放、删除，无需再点一次编辑按钮。
    /// 离开该页（或关闭面板）时退出编辑模式。
    func setComponentsPageActive(_ active: Bool) {
        SettingsSwitchProbe.log(
            "setComponentsPageActive(\(active)) current=\(isEditingForComponentsPage)"
        )
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
        SettingsSwitchProbe.measure("rebuildContent total (animated=\(animated))") {
            // 紧凑元素的上下文 frame 以主屏几何近似（槽位尺寸跨屏一致，
            // 视觉几何由各面板的 layout 参数精确持有）。
            let contextLayout = primaryLayout()

            let apply = {
                self.uiState.showsClickModeHint = self.settingsStore.triggerMode == .click
                self.uiState.compactElements = self.buildCompactElements(layout: contextLayout)

                self.uiState.drawerContentSize = self.layoutEngine.drawerContentSize()
                self.uiState.drawerGridLeftColumn = self.layoutEngine.gridLeftColumn()
                self.uiState.drawerWindowSize = self.drawerWindowSize(for: self.activePair ?? self.pairs.first)
                self.uiState.drawerElements = self.buildDrawerElements()
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
                    actions: drawerActions()
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
        SettingsSwitchProbe.measure("buildCompactElements count=\(compactIconCount)") {
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
                    view: SettingsSwitchProbe.measure(
                        "makeView compact \(reference.pluginID).\(reference.blockID)"
                    ) { block.makeView(context) },
                    frame: frame,
                    hasSettings: block.instanceSettingsView != nil
                        || entry.instance?.settingsView != nil
                )
            }
        }
    }

    private func buildDrawerElements() -> [DrawerElement] {
        SettingsSwitchProbe.measure("buildDrawerElements count=\(layoutEngine.drawerBlocks.count)") {
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
                    view: SettingsSwitchProbe.measure(
                        "makeView drawer \(placement.pluginID).\(placement.blockID)"
                    ) { block.makeView(context) },
                    supportedSpans: block.supportedSpans.sorted { lhs, rhs in
                        lhs.columns == rhs.columns ? lhs.rows < rhs.rows : lhs.columns < rhs.columns
                    },
                    currentSpan: currentSpan,
                    hasSettings: block.instanceSettingsView != nil
                        || entry.instance?.settingsView != nil
                )
            }
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
                self?.showSettings()
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
            onToggleEdit: { [weak self] in
                guard let self else { return }
                if self.isEditing {
                    // 手动退出编辑时同步清掉“组件页联动”标志，避免之后
                    // 切页时两个来源对编辑态的判断打架。
                    self.isEditingForComponentsPage = false
                    self.stopEditMode()
                } else {
                    self.startEditMode()
                }
            },
            onCollapse: { [weak self] in
                guard let self else { return }
                // 设置面板开着时，关闭按钮先收面板（面板与抽屉是同一组
                // 常驻 UI），再收抽屉——避免面板孤零零挂在屏中央。
                if self.isSettingsPresented {
                    self.closeSettings()
                    return
                }
                self.collapse(animated: true)
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
            onMoveBlock: { [weak self] placementID, column, row in
                self?.layoutEngine.moveDrawerBlock(placementID: placementID, toColumn: column, toRow: row)
                self?.refreshAfterEdit()
            },
            onResizeBlock: { [weak self] placementID, columns, rows in
                self?.layoutEngine.resizeDrawerBlock(placementID: placementID, toColumns: columns, toRows: rows)
                self?.refreshAfterEdit()
            },
            onReorderBlocks: { [weak self] in
                self?.layoutEngine.reorderDrawerBlocks()
                self?.refreshAfterEdit()
            },
            onPreviewMove: { [weak self] placementID, column, row in
                guard let self else { return [:] }
                let target = self.clampedDropTarget(
                    placementID: placementID,
                    column: column,
                    row: row
                )
                // 推挤 + 离线压实一次返回（预览 == 提交）：全体块的新位置
                // 写回 previewPositions，拖动期间实时推挤。
                let origins = self.layoutEngine.previewCommittedArrangement(
                    moving: placementID,
                    toColumn: target.column,
                    toRow: target.row
                )
                // 左扩/增宽/增高与推挤同帧（写 drawerGridLeftColumn + 尺寸，
                // 与推挤共用同一 spring）；左扩 = 全体块横移 + 面板重居中。
                self.applyPreviewWindowSize(origins, resized: nil)
                return origins
            },
            onUpdateReorderPreview: { [weak self] origin, span in
                self?.updateDrawerReorderPreview(origin, span: span)
            },
            onPreviewResize: { [weak self] placementID, columns, rows in
                guard let self else { return [:] }
                let origins = self.layoutEngine.previewArrangement(
                    resizing: placementID,
                    toColumns: columns,
                    toRows: rows
                )
                // 底层块长高/加宽不推挤任何人：新跨度必须显式传入才会
                // 增高/增宽面板。
                self.applyPreviewWindowSize(
                    origins,
                    resized: (placementID, rows, columns)
                )
                return origins
            },
            onCommitDrag: { [weak self] placementID, column, row in
                guard let self else { return }
                // 与 onPreviewMove 共用同一夹紧目标 + 同一组合 API（推挤 +
                // 离线压实）：占位框预示的落点 == 松手后真正提交的位置
                // （所见即所得，且提交侧压实为幂等兜底、零二次位移）。
                let target = self.clampedDropTarget(
                    placementID: placementID,
                    column: column,
                    row: row
                )
                let origins = self.layoutEngine.previewCommittedArrangement(
                    moving: placementID,
                    toColumn: target.column,
                    toRow: target.row
                )
                _ = self.layoutEngine.commitArrangement(origins)
                self.refreshAfterEdit()
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
