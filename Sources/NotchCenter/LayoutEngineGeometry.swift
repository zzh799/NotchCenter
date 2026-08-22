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

    /// 网格内容尺寸（行数随内容增长，文档 §5.3）。
    func drawerContentSize() -> CGSize {
        let rows = max(drawerContentRows(), 1)
        return CGSize(
            width: NotchGridMetrics.contentWidth(columns: effectiveMaxColumns()),
            height: NotchGridMetrics.contentHeight(rows: rows)
        )
    }

    /// 抽屉窗口尺寸：列数受屏幕约束；高度随行数增长。
    /// `contentRows` 用于拖拽/缩放预览（按预览布局的最低行临时增高）。
    func drawerWindowSize(contentRows: Int? = nil) -> CGSize {
        let rows = max(contentRows ?? drawerContentRows(), 1)
        return CGSize(
            width: NotchGridMetrics.contentWidth(columns: effectiveMaxColumns())
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
    /// 不会经 origins 体现，必须显式计入。
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
}
