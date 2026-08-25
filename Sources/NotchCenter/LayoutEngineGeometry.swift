import CoreGraphics
import Foundation

// MARK: - 几何

extension LayoutEngine {
    /// 按 placementID 查紧凑槽位引用（设置浮窗解析锚定块身份用）；不存在返回 nil。
    func compactSlot(withPlacementID placementID: String) -> CompactSlotReference? {
        model.compactSlots.first { $0?.placementID == placementID } ?? nil
    }

    /// 抽屉块在网格内容坐标系（grid 左上角为原点）中的 frame。
    func frame(for placement: PlacedBlock) -> CGRect {
        CGRect(
            x: CGFloat(placement.originColumn) * (NotchGridMetrics.cellWidth + NotchGridMetrics.spacing),
            y: CGFloat(placement.originRow) * (NotchGridMetrics.cellHeight + NotchGridMetrics.spacing),
            width: CGFloat(placement.widthColumns) * NotchGridMetrics.cellWidth
                + CGFloat(max(placement.widthColumns - 1, 0)) * NotchGridMetrics.spacing,
            height: CGFloat(placement.heightRows) * NotchGridMetrics.cellHeight
                + CGFloat(max(placement.heightRows - 1, 0)) * NotchGridMetrics.spacing
        )
    }

    /// 提交布局的占用列区间：(min = 最左占用列，max = 最右占用列的右缘，
    /// exclusive)。列支持左右双向扩大——块被拖出左侧时 originColumn 可为负，
    /// 区间随内容向左/右扩展；空布局返回 (0, 0)。
    func occupiedColumnRange() -> (min: Int, max: Int) {
        var minColumn = Int.max
        var maxColumn = Int.min
        for block in model.drawerBlocks {
            minColumn = min(minColumn, block.originColumn)
            maxColumn = max(maxColumn, block.originColumn + block.widthColumns)
        }
        if minColumn == Int.max { return (0, 0) }
        return (minColumn, maxColumn)
    }

    /// 实际占用的列跨度（右缘 − 左缘，下限 1，封顶容量）：面板绕刘海居中，
    /// 宽度随跨度左右双向自适应；行仅向下增长。换行上限仍由用户设置
    /// （effectiveMaxColumns）决定。
    func occupiedColumns() -> Int {
        let range = occupiedColumnRange()
        return min(max(range.max - range.min, 1), effectiveMaxColumns())
    }

    /// 提交布局的格网最左列（渲染偏移）：左扩为负时内容整体右移，
    /// 使块的原点从面板左缘起算仍保持连续。
    func gridLeftColumn() -> Int {
        occupiedColumnRange().min
    }

    /// 网格内容尺寸（行列都随内容自适应）。
    func drawerContentSize() -> CGSize {
        let rows = max(drawerContentRows(), 1)
        return CGSize(
            width: NotchGridMetrics.contentWidth(columns: occupiedColumns()),
            height: NotchGridMetrics.contentHeight(rows: rows)
        )
    }

    /// 抽屉窗口尺寸：宽度按实际占用列数收缩（换行上限仍受屏幕约束）；
    /// 高度随行数增长。高度 = 顶栏 + 内容行高 + 底部内边距——顶部不再
    /// 预留 padding：`DrawerPanelView` 的内容栈从顶栏直接开始（紧凑带
    /// 与顶栏之间无需空隙），若在此多加一项，这 16pt 不会被渲染，只会
    /// 落到 ScrollView 底部与内容自身 bottom padding 叠加，造成“底部留白
    /// 约为左右两倍”的不一致（截图反馈修复）。
    /// `contentRows` / `contentColumns` 用于拖拽/缩放预览（按预览布局的
    /// 最低行/实际占用列临时调整）。
    func drawerWindowSize(contentRows: Int? = nil, contentColumns: Int? = nil) -> CGSize {
        let rows = max(contentRows ?? drawerContentRows(), 1)
        let columns = max(contentColumns ?? occupiedColumns(), 1)
        return CGSize(
            width: NotchGridMetrics.contentWidth(columns: columns)
                + NotchGridMetrics.contentPadding * 2,
            height: NotchGridMetrics.drawerTopBarHeight
                + NotchGridMetrics.contentHeight(rows: rows)
                + NotchGridMetrics.contentPadding
        )
    }

    /// 预览布局的最低占用行（面板预览期间按需增高的依据；无预览回落到
    /// 提交布局行数）。`resized` 携带被缩放块的新行数——模型里的
    /// heightRows 仍是旧值，且最底层的块长高时不推挤任何块、新行号
    /// 不会经 origins 体现，必须显式计入。`origins` 同时参与列宽计算：
    /// 拖拽/缩放预览中块的临时位置/跨度也计入实际占用列数。
    func previewBottomRow(
        origins: [String: GridOrigin],
        resized: (placementID: String, heightRows: Int)? = nil
    ) -> Int {
        let committed = drawerContentRows()
        let preview = model.drawerBlocks
            .map { block -> Int in
                let row = origins[block.placementID]?.row ?? block.originRow
                let height = block.placementID == resized?.placementID
                    ? resized!.heightRows
                    : block.heightRows
                return row + height
            }
            .max() ?? committed
        return max(committed, preview, 1)
    }

    private func drawerContentRows() -> Int {
        let occupiedRows = model.drawerBlocks.map { $0.originRow + $0.heightRows }.max() ?? 0
        return max(occupiedRows, 1)
    }

    /// 预览布局的列区间（min/max 同 `occupiedColumnRange`）：提交布局与
    /// 预览 origins 的并集，`resized` 携带被缩放块的新列数（模型里
    /// widthColumns 还是旧值）。被移动块的落点同样含在 origins 中——
    /// 向左拖出时的负列由此计入区间。
    func previewColumnRange(
        origins: [String: GridOrigin],
        resized: (placementID: String, widthColumns: Int)? = nil
    ) -> (min: Int, max: Int) {
        var minColumn = Int.max
        var maxColumn = Int.min
        for block in model.drawerBlocks {
            let column = origins[block.placementID]?.column ?? block.originColumn
            let width = block.placementID == resized?.placementID
                ? resized!.widthColumns
                : block.widthColumns
            minColumn = min(minColumn, column)
            maxColumn = max(maxColumn, column + width)
        }
        if minColumn == Int.max { return (0, 0) }
        return (minColumn, maxColumn)
    }

    /// 预览布局的列跨度（右缘 − 左缘，封顶容量）：提交布局与预览 origins
    /// 取并集后按跨度计——向左扩大同样增加跨度，面板随之左右对称增宽。
    func previewOccupiedColumns(
        origins: [String: GridOrigin],
        resized: (placementID: String, widthColumns: Int)? = nil
    ) -> Int {
        let range = previewColumnRange(origins: origins, resized: resized)
        return min(max(range.max - range.min, 1), effectiveMaxColumns())
    }
}
