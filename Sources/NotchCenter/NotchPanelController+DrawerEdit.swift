import AppKit
import NotchCenterKit

// MARK: - 抽屉内拖拽 / 缩放的唯一出口

enum DrawerEditPhase {
    /// 拖动/缩放进行中：只算预览、只撑面板，不落盘。
    case preview
    /// 松手：提交布局并重建内容。
    case commit
}

extension NotchPanelController {
    /// 抽屉内拖拽的唯一出口：预览与提交共用同一夹紧目标、同一 origins、
    /// 同一次尺寸写入。
    ///
    /// 契约（`DragUnificationTests` 严格锁定）：`previewCommittedArrangement`
    /// 的结果**就是**最终布局，提交侧的压实只是幂等兜底。所以两条路径必须
    /// 同源——此前 `onPreviewMove` 与 `onCommitDrag` 是两份 90% 逐字重复的
    /// 实现，改一处漏一处就会出现"占位框预示的落点 ≠ 松手后真正落到的位置"。
    @discardableResult
    func applyDrawerDrag(
        placementID: String,
        column: Int,
        row: Int,
        phase: DrawerEditPhase
    ) -> [String: LayoutEngine.GridOrigin] {
        let target = clampedDropTarget(placementID: placementID, column: column, row: row)
        let origins = layoutEngine.previewCommittedArrangement(
            moving: placementID,
            toColumn: target.column,
            toRow: target.row
        )
        applyPreviewWindowSize(origins, resized: nil)
        guard phase == .commit else { return origins }
        _ = layoutEngine.commitArrangement(origins)
        refreshAfterEdit()
        return origins
    }

    /// 缩放的唯一出口（与拖拽对称）。
    ///
    /// 预览与提交的算法差只在"压实"：`previewArrangement(resizing:)` 是
    /// `pushDownOrigins(changed:)`，`resizeDrawerBlock` 在同样的推挤之上
    /// 多做了 `applyOrigins`、空洞压实与落盘。
    @discardableResult
    func applyDrawerResize(
        placementID: String,
        columns: Int,
        rows: Int,
        phase: DrawerEditPhase
    ) -> [String: LayoutEngine.GridOrigin] {
        let origins = layoutEngine.previewArrangement(
            resizing: placementID,
            toColumns: columns,
            toRows: rows
        )
        // 底层块长高/加宽不推挤任何人：新跨度必须显式传入才会增高/增宽面板。
        applyPreviewWindowSize(origins, resized: (placementID, rows, columns))
        guard phase == .commit else { return origins }
        layoutEngine.resizeDrawerBlock(placementID: placementID, toColumns: columns, toRows: rows)
        refreshAfterEdit()
        return origins
    }
}
