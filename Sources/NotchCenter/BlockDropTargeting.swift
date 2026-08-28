import AppKit
import SwiftUI

// MARK: - 设置面板拖拽落点（文档 §6.4：从设置面板拖组件到抽屉 / 快速区）

extension NotchPanelController {
    /// 屏幕坐标 → 落点。未展开、落在面板之外或种类不匹配时返回 nil
    /// （拖拽浮窗显示无效样式）。
    ///
    /// 判定顺序：先快速区（岛顶紧凑带），再抽屉网格——抽屉展开时两者在屏幕
    /// 上上下相邻、互不重叠（紧凑带位于可见面板顶部），先判上层的紧凑带。
    func dropZone(
        at point: NSPoint,
        for payload: BlockDragCoordinator.Payload
    ) -> BlockDragCoordinator.DropZone? {
        guard isExpanded, let pair = activePair else { return nil }

        let visible = visibleDrawerFrame(for: pair)
        guard visible.contains(point) else { return nil }

        // 快速区（岛顶紧凑带）：命中区取**整个可见面板顶部的紧凑带高度**，
        // 而不是 `pair.hotFrame`——后者宽度只够绕刘海的紧凑带本体（无图标时
        // 约等于刘海宽），而用户看到的“快捷按钮区域”是抽屉岛顶整条黑带
        // （宽度 = 可见面板宽）。用窄矩形判定会让拖到岛顶两侧的落点被判成
        // 网格区，快捷按钮因此“放不进快速区”。
        if point.y >= visible.maxY - pair.layout.compactHeight {
            guard payload.isCompact else { return nil }
            return .compact(index: compactScreenInsertionIndex(atX: point.x, pair: pair))
        }

        // 快捷按钮（紧凑块）拖到抽屉区域：宽松处理为追加到快速区末尾
        // （紧凑块无法放进抽屉网格，但“往面板上放”的意图应当被接住）。
        if payload.isCompact {
            return .compact(index: layoutEngine.compactSlots.count)
        }
        return drawerDropZone(at: point, pair: pair, visible: visible, payload: payload)
    }

    /// 抽屉网格落点：把屏幕坐标换算成格子坐标。
    /// 列基准为格网最左列（`gridLeftColumn`，左扩时可为负），行自网格
    /// 内容顶缘向下（顶缘 = 紧凑带 + 顶栏）。
    private func drawerDropZone(
        at point: NSPoint,
        pair: ScreenPanelPair,
        visible: NSRect,
        payload: BlockDragCoordinator.Payload
    ) -> BlockDragCoordinator.DropZone? {
        let stepWidth = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing
        let stepHeight = NotchGridMetrics.cellHeight + NotchGridMetrics.spacing
        guard stepWidth > 0, stepHeight > 0 else { return nil }

        let topInset = pair.layout.compactHeight
            + NotchGridMetrics.drawerTopBarHeight
        // 屏幕坐标 y 轴向上；转成自面板顶缘向下的距离。
        let offsetFromTop = visible.maxY - point.y
        guard offsetFromTop >= topInset else { return nil }

        let row = max(Int(floor((offsetFromTop - topInset) / stepHeight)), 0)
        let leftColumn = layoutEngine.gridLeftColumn()
        let rawColumn = Int(floor((point.x - visible.minX - NotchGridMetrics.contentPadding) / stepWidth)) + leftColumn
        // 跨度不得超出容量：列上限按“左缘 + 容量 − 跨度”收紧。
        let upperColumn = leftColumn + layoutEngine.effectiveMaxColumns() - payload.span.columns
        let column = min(max(rawColumn, leftColumn), max(upperColumn, leftColumn))

        return .drawer(
            column: column,
            row: row,
            columns: payload.span.columns,
            rows: payload.span.rows
        )
    }

    /// 快速区落点：屏幕坐标先转成紧凑带内容坐标（各屏的槽位布局一致），
    /// 再取**屏幕插入位置**（0...count）。
    private func compactScreenInsertionIndex(atX x: CGFloat, pair: ScreenPanelPair) -> Int {
        compactStrip(for: pair).screenInsertionIndex(atContentX: x - pair.hotFrame.minX)
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
            return
        }
        var pointerX: CGFloat?
        if case .compact = zone, let pointer, let pair = activePair {
            pointerX = pointer.x - pair.hotFrame.minX
        }
        uiState.dropPreview = PanelUIState.DropPreview(
            zone: zone,
            isCompact: payload.isCompact,
            title: payload.displayName,
            compactPointerX: pointerX
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
    func performBlockDrop(
        _ payload: BlockDragCoordinator.Payload,
        to zone: BlockDragCoordinator.DropZone
    ) {
        switch zone {
        case let .compact(index):
            guard layoutEngine.insertCompactBlock(
                pluginID: payload.pluginID,
                blockID: payload.blockID,
                atScreenPosition: index
            ) else { return }
            refreshCompactGeometry()
            refreshAfterEdit()
        case let .drawer(column, row, _, _):
            guard layoutEngine.placeDrawerBlock(
                pluginID: payload.pluginID,
                blockID: payload.blockID,
                column: column,
                row: row
            ) != nil else { return }
            refreshAfterEdit()
        }
    }
}
