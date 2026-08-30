import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 设置面板拖拽落点（文档 §6.4：从设置面板拖组件到抽屉 / 快速区）

extension NotchPanelController {
    /// 屏幕坐标 → 落点。未展开、落在面板之外或种类不匹配时返回 nil
    /// （拖拽浮窗显示无效样式）。
    ///
    /// 判定顺序：先快速区（岛顶紧凑带），再抽屉网格——抽屉展开时两者在屏幕
    /// 上上下相邻、互不重叠（紧凑带位于可见面板顶部），先判上层的紧凑带。
    /// 区域判定见 `DrawerDropPolicy`，网格换算见 `DrawerScreenMapper`。
    func dropZone(
        at point: NSPoint,
        for payload: BlockDragCoordinator.Payload
    ) -> BlockDragCoordinator.DropZone? {
        guard isExpanded, let pair = activePair else { return nil }
        let mapper = drawerScreenMapper(for: pair)
        let policy = DrawerDropPolicy(mapper: mapper, compactHeight: pair.layout.compactHeight)

        switch policy.region(of: point) {
        case .outside, .topBar:
            return nil
        case .compact:
            // 只有紧凑块能进快速区。
            guard payload.isCompact else { return nil }
            return .compact(index: compactScreenInsertionIndex(atX: point.x, pair: pair))
        case .grid:
            // 快捷按钮（紧凑块）拖到抽屉区域：宽松处理为追加到快速区末尾
            // （紧凑块无法放进抽屉网格，但“往面板上放”的意图应当被接住）。
            if payload.isCompact {
                return .compact(index: layoutEngine.compactSlots.count)
            }
            guard let cell = mapper.cell(atScreen: point, span: payload.span) else { return nil }
            return .drawer(
                column: cell.column,
                row: cell.row,
                columns: cell.columnSpan,
                rows: cell.rowSpan
            )
        }
    }

    /// 快速区落点：屏幕坐标先转成紧凑带内容坐标（各屏的槽位布局一致），
    /// 再取**屏幕插入位置**（0...count）。
    private func compactScreenInsertionIndex(atX x: CGFloat, pair: ScreenPanelPair) -> Int {
        compactStrip(for: pair).screenInsertionIndex(atContentX: compactContentX(x, pair: pair))
    }

    // MARK: 快捷按钮重排（编辑模式）

    /// 编辑模式下拖动快捷按钮换位：`from` 为被拖图标的数组下标，`to` 为
    /// **屏幕插入位置**（与拖拽落点同一语义）。重排按屏幕顺序运算，
    /// 其余图标在屏幕上保持相对顺序。
    func moveCompactBlock(from: Int, toScreenPosition to: Int) {
        layoutEngine.moveCompactSlot(from: from, toScreenPosition: to)
        // 图标数不变：无需同步条带几何，按新顺序（带让位动画）重建内容。
        rebuildContent(animated: true)
    }

    /// 编辑模式拖动中的让位预览：被拖图标的数组下标 + 屏幕插入位置 +
    /// 光标横坐标（紧凑带内容坐标）。三者任一为 nil 表示清空。
    ///
    /// 视图据此把每个图标画在**预览后的槽位**上，于是拖动过程中其余图标
    /// 会平滑让位；只有落点/被拖项变化时才写状态，避免每帧重启动画。
    func updateCompactReorderPreview(
        draggingSlot: Int?,
        screenPosition: Int?,
        pointerX: CGFloat?
    ) {
        guard let draggingSlot, let screenPosition else {
            if uiState.dropPreview != nil {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    uiState.dropPreview = nil
                }
            }
            return
        }
        let preview = PanelUIState.DropPreview(
            zone: .compact(index: screenPosition),
            isCompact: true,
            title: "",
            compactPointerX: pointerX,
            draggingSlotIndex: draggingSlot
        )
        // 光标横坐标每次都在变，只按“目标”比较，否则动画会被每帧重启。
        if let current = uiState.dropPreview, current.matchesTarget(of: preview) {
            uiState.dropPreview = preview
            return
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            uiState.dropPreview = preview
        }
    }

    // MARK: 落点预览

    /// 把当前落点写进 `uiState`（抽屉网格的虚线占位 / 快速区的插入指示）。
    /// 传 nil 清空（拖拽取消或提交后）。`pointer` 为光标屏幕坐标，用于让
    /// 插入指示线跟随光标。
    func updateDropPreview(
        payload: BlockDragCoordinator.Payload?,
        zone: BlockDragCoordinator.DropZone?,
        pointer: NSPoint? = nil
    ) {
        guard let payload, let zone else {
            if uiState.dropPreview != nil {
                uiState.dropPreview = nil
            }
            applyDropPreviewWindowSize(nil)
            return
        }
        var pointerX: CGFloat?
        if case .compact = zone, let pointer, let pair = activePair {
            pointerX = compactContentX(pointer.x, pair: pair)
        }
        uiState.dropPreview = PanelUIState.DropPreview(
            zone: zone,
            isCompact: payload.isCompact,
            title: payload.displayName,
            compactPointerX: pointerX
        )
        // 落点在新行/新列时同步撑开面板：否则占位框被 ScrollView 裁掉。
        applyDropPreviewWindowSize(zone)
    }

    /// 抽屉内重排的落点预览：**只写虚线占位框，不写面板尺寸与左列**——
    /// 窗口尺寸与 `drawerGridLeftColumn`（含左扩）由 `onPreviewMove` 回调
    /// 内的 `applyPreviewWindowSize` 按同一份压实 origins 同帧写入（推挤、
    /// 增宽与全体块横移共用同一 spring）。本方法只负责占位框本身。
    ///
    /// `origin` / `span` 任一为 nil 表示清空（拖动结束或取消）；
    /// nil 分支保留 `applyDropPreviewWindowSize(nil)` 作松手复位兜底
    /// （提交后 `rebuildContent` 会再写正确值）。
    /// `origin` 取压实预览（`previewCommittedArrangement`）后**被拖块**的
    /// 最终原点，保证占位框与松手后的真实落点一致（所见即所得）。
    func updateDrawerReorderPreview(
        _ origin: LayoutEngine.GridOrigin?,
        span: GridSpan?
    ) {
        guard let origin, let span else {
            if uiState.dropPreview != nil {
                withAnimation(DrawerAnimation.spring) {
                    uiState.dropPreview = nil
                }
            }
            applyDropPreviewWindowSize(nil)
            return
        }
        let zone = BlockDragCoordinator.DropZone.drawer(
            column: origin.column,
            row: origin.row,
            columns: span.columns,
            rows: span.rows
        )
        let preview = PanelUIState.DropPreview(
            zone: zone,
            isCompact: false,
            title: "",
            isDrawerReorder: true
        )
        // 只按「目标」比较：否则每帧都会重启 spring（面板尺寸抖动）。
        if let current = uiState.dropPreview, current.matchesTarget(of: preview) {
            return
        }
        uiState.dropPreview = preview
    }

    /// 抽屉内重排的拖动目标 → 合法落点：列夹紧到引擎的合法区间
    /// （`dropTargetColumnBounds`，下界可为负——左扩内建），拖到左边界外
    /// 时格网实时向左扩展（`drawerGridLeftColumn` 由 `applyPreviewWindowSize`
    /// 同帧写入，全体块横移 + 面板重居中，代价已确认接受）。行只向下增长
    /// （网格不支持负行）。
    ///
    /// 预览（`onPreviewMove`）与提交（`onCommitDrag`）必须共用它，
    /// 否则占位框预示的落点会和真正落到的位置不一致。
    func clampedDropTarget(
        placementID: String,
        column: Int,
        row: Int
    ) -> (column: Int, row: Int) {
        let bounds = layoutEngine.dropTargetColumnBounds(placementID: placementID)
        return (
            min(max(column, bounds.lower), bounds.upper),
            max(row, 0)
        )
    }

    /// 「组件」页卡片上的 + 按钮：不拖拽时的快捷添加路径——紧凑块追加到
    /// 快速区末尾，抽屉块自动放置到首个空位（与编辑模式目录条同一语义）。
    func addBlock(pluginID: String, blockID: String) {
        guard let block = pluginManager.block(pluginID: pluginID, blockID: blockID) else { return }
        if block.kind == .compact {
            _ = layoutEngine.addCompactBlock(pluginID: pluginID, blockID: blockID)
            refreshCompactGeometry()
        } else {
            _ = layoutEngine.autoPlaceDrawerBlock(pluginID: pluginID, blockID: blockID)
        }
        refreshAfterEdit()
    }

    // MARK: 落位

    /// 提交拖拽结果：快速区插入（随后同步条带几何与热区窗口），
    /// 或抽屉网格落位（随后按编辑刷新重建内容）。
    ///
    /// `beforeRefresh` 拿到新块的 placementID，**早于** `refreshAfterEdit()`
    /// 调用——调用方借此在内容重建前把该块标记为落位飞行中
    /// （`uiState.landingPlacementID`，渲染为 `opacity(0)`），让跟手浮窗
    /// 独占飞行期间的画面。默认 nil，自动化探针因此完全不受影响。
    func performBlockDrop(
        _ payload: BlockDragCoordinator.Payload,
        to zone: BlockDragCoordinator.DropZone,
        beforeRefresh: ((String) -> Void)? = nil
    ) {
        switch zone {
        case let .compact(index):
            guard layoutEngine.insertCompactBlock(
                pluginID: payload.pluginID,
                blockID: payload.blockID,
                atScreenPosition: index
            ) else { return }
            // 快速区不做落位飞行：把大块缩成 28×28 图标飞过去观感很怪，
            // 沿用现有的插入动画。不回调 beforeRefresh 即走该分支。
            refreshCompactGeometry()
            refreshAfterEdit()
        case let .drawer(column, row, _, _):
            guard let placed = layoutEngine.placeDrawerBlock(
                pluginID: payload.pluginID,
                blockID: payload.blockID,
                column: column,
                row: row
            ) else { return }
            beforeRefresh?(placed.placementID)
            refreshAfterEdit()
        }
    }
}
