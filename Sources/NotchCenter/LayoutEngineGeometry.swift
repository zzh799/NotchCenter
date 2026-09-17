import CoreGraphics
import Foundation

// MARK: - 几何

extension LayoutEngine {
    /// 按 placementID 查紧凑槽位引用（设置浮窗解析锚定块身份用）；不存在返回 nil。
    func compactSlot(withPlacementID placementID: String) -> CompactSlotReference? {
        model.compactSlots.first { $0?.placementID == placementID } ?? nil
    }

    /// 抽屉块在网格内容坐标系（grid 左上角为原点）中的 frame。
    ///
    /// ⚠️ 这是**绝对列**坐标系（`originColumn × step`，不减渲染左列），
    /// 与 `DrawerGridGeometry`（渲染用，`(column − leftColumn) × step`）
    /// 不是同一个坐标系。本 frame 喂给插件的 `layoutInfo.frame`，插件只读
    /// `.size`，所以两套并存是安全的——不要"顺手统一"。
    func frame(for placement: PlacedBlock) -> CGRect {
        let metrics = GridMetrics.current
        return CGRect(
            x: CGFloat(placement.originColumn) * metrics.stepWidth,
            y: CGFloat(placement.originRow) * metrics.stepHeight,
            width: metrics.width(columns: placement.widthColumns),
            height: metrics.height(rows: placement.heightRows)
        )
    }

    /// 提交布局的占用列区间：(min = 最左占用列，max = 最右占用列的右缘，
    /// exclusive)。列支持左右双向扩大——块被拖出左侧时 originColumn 可为负，
    /// 区间随内容向左/右扩展；空布局返回 (0, 0)。
    func occupiedColumnRange(page: Int = 0) -> (min: Int, max: Int) {
        var minColumn = Int.max
        var maxColumn = Int.min
        for block in model.drawerBlocks where block.page == page {
            minColumn = min(minColumn, block.originColumn)
            maxColumn = max(maxColumn, block.originColumn + block.widthColumns)
        }
        if minColumn == Int.max { return (0, 0) }
        return (minColumn, maxColumn)
    }

    /// 实际占用的列跨度（右缘 − 左缘，下限见 `minimumColumnCount()`，封顶容量）：
    /// 面板绕刘海居中，宽度随跨度左右双向自适应；行仅向下增长。换行上限仍由用户
    /// 设置（effectiveMaxColumns）决定。
    func occupiedColumns(page: Int = 0) -> Int {
        let range = occupiedColumnRange(page: page)
        return min(
            max(range.max - range.min, minimumColumnCount()),
            effectiveMaxColumns()
        )
    }

    /// 提交布局的格网最左列（渲染偏移）：左扩为负时内容整体右移，
    /// 使块的原点从面板左缘起算仍保持连续。
    func gridLeftColumn(page: Int = 0) -> Int {
        occupiedColumnRange(page: page).min
    }

    /// 网格内容尺寸（行列都随内容自适应）。
    func drawerContentSize(page: Int = 0) -> CGSize {
        let metrics = GridMetrics.current
        let rows = drawerContentRows(page: page)
        return metrics.size(columns: occupiedColumns(page: page), rows: rows)
    }

    /// 抽屉窗口尺寸：宽度按实际占用列数收缩（换行上限仍受屏幕约束）；
    /// 高度随行数增长。高度 = 顶栏 + 内容行高 + 底部内边距——顶部不再
    /// 预留 padding：`DrawerPanelView` 的内容栈从顶栏直接开始（紧凑带
    /// 与顶栏之间无需空隙），若在此多加一项，这 16pt 不会被渲染，只会
    /// 落到 ScrollView 底部与内容自身 bottom padding 叠加，造成“底部留白
    /// 约为左右两倍”的不一致（截图反馈修复）。
    /// `contentRows` / `contentColumns` 用于拖拽/缩放预览（按预览布局的
    /// 最低行/实际占用列临时调整）。
    func drawerWindowSize(contentRows: Int? = nil, contentColumns: Int? = nil, page: Int = 0) -> CGSize {
        let rows = max(contentRows ?? drawerContentRows(page: page), minimumRowCount())
        let columns = min(
            max(contentColumns ?? occupiedColumns(page: page), minimumColumnCount()),
            effectiveMaxColumns()
        )
        let metrics = GridMetrics.current
        return CGSize(
            width: metrics.width(columns: columns) + metrics.contentPadding * 2,
            height: metrics.topBarHeight + metrics.height(rows: rows) + metrics.contentPadding
        )
    }

    /// 预览布局的最低占用行（面板预览期间按需增高的依据；无预览回落到
    /// 提交布局行数）。`resized` 携带被缩放块的新行数——模型里的
    /// heightRows 仍是旧值，且最底层的块长高时不推挤任何块、新行号
    /// 不会经 origins 体现，必须显式计入。`origins` 同时参与列宽计算：
    /// 拖拽/缩放预览中块的临时位置/跨度也计入实际占用列数。
    func previewBottomRow(
        origins: [String: GridOrigin],
        resized: (placementID: String, heightRows: Int)? = nil,
        page: Int = 0
    ) -> Int {
        let committed = drawerContentRows(page: page)
        let preview = drawerBlocks(onPage: page)
            .map { block -> Int in
                let row = origins[block.placementID]?.row ?? block.originRow
                let height = block.placementID == resized?.placementID
                    ? resized!.heightRows
                    : block.heightRows
                return row + height
            }
            .max() ?? committed
        return max(committed, preview)
    }

    /// 提交布局的占用行数（拖入落点预览要据此算「占位框 ∪ 提交布局」的并集
    /// 行数，故放开访问控制）。
    func drawerContentRows(page: Int = 0) -> Int {
        let occupiedRows = drawerBlocks(onPage: page)
            .map { $0.originRow + $0.heightRows }
            .max() ?? 0
        return max(occupiedRows, minimumRowCount())
    }

    /// 预览布局的列区间（min/max 同 `occupiedColumnRange`）：提交布局与
    /// 预览 origins 的并集，`resized` 携带被缩放块的新列数（模型里
    /// widthColumns 还是旧值）。被移动块的落点同样含在 origins 中——
    /// 向左拖出时的负列由此计入区间。
    func previewColumnRange(
        origins: [String: GridOrigin],
        resized: (placementID: String, widthColumns: Int)? = nil,
        page: Int = 0
    ) -> (min: Int, max: Int) {
        var minColumn = Int.max
        var maxColumn = Int.min
        for block in model.drawerBlocks where block.page == page {
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
    /// 下限与 `occupiedColumns` 同一条公式（预览 == 提交）。
    func previewOccupiedColumns(
        origins: [String: GridOrigin],
        resized: (placementID: String, widthColumns: Int)? = nil,
        page: Int = 0
    ) -> Int {
        let range = previewColumnRange(origins: origins, resized: resized, page: page)
        return min(
            max(range.max - range.min, minimumColumnCount()),
            effectiveMaxColumns()
        )
    }
}
