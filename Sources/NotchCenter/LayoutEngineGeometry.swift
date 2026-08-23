import CoreGraphics
import Foundation

// MARK: - 几何

extension LayoutEngine {
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

    /// 实际占用的最大列数（行自适应的列对应物）：所有块右缘的最大列数，
    /// clamp 到网格上限、下限 1。抽屉宽度据此随内容收缩，换行上限仍由
    /// 用户设置（effectiveMaxColumns）决定。
    func occupiedColumns() -> Int {
        let maxColumn = model.drawerBlocks
            .map { $0.originColumn + $0.widthColumns }
            .max() ?? 1
        return min(max(maxColumn, 1), effectiveMaxColumns())
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
    /// 高度随行数增长。
    /// `contentRows` / `contentColumns` 用于拖拽/缩放预览（按预览布局的
    /// 最低行/实际占用列临时调整）。
    func drawerWindowSize(contentRows: Int? = nil, contentColumns: Int? = nil) -> CGSize {
        let rows = max(contentRows ?? drawerContentRows(), 1)
        let columns = max(contentColumns ?? occupiedColumns(), 1)
        return CGSize(
            width: NotchGridMetrics.contentWidth(columns: columns)
                + NotchGridMetrics.contentPadding * 2,
            height: NotchGridMetrics.contentPadding
                + NotchGridMetrics.drawerTopBarHeight
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

    /// 预览布局的实际占用列数：提交布局的右缘与预览 origins 的右缘取大。
    /// `resized` 携带被缩放块的新列数（模型里 widthColumns 还是旧值）。
    func previewOccupiedColumns(
        origins: [String: GridOrigin],
        resized: (placementID: String, widthColumns: Int)? = nil
    ) -> Int {
        let committed = model.drawerBlocks
            .map { block -> Int in
                if block.placementID == resized?.placementID {
                    return block.originColumn + resized!.widthColumns
                }
                return block.originColumn + block.widthColumns
            }
            .max() ?? 1
        let preview = model.drawerBlocks
            .map { block -> Int in
                let column = origins[block.placementID]?.column ?? block.originColumn
                let width = block.placementID == resized?.placementID
                    ? resized!.widthColumns
                    : block.widthColumns
                return column + width
            }
            .max() ?? committed
        return min(max(committed, preview, 1), effectiveMaxColumns())
    }
}
