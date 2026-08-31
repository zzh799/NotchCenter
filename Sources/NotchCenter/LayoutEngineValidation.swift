import Foundation
import NotchCenterKit

// MARK: - 校验（文档 §5.4：检测重叠；核心可据校验结果提示修复）

extension LayoutEngine {
    func validate() -> [LayoutIssue] {
        var issues: [LayoutIssue] = []

        if model.schemaVersion != LayoutModel.currentSchemaVersion {
            issues.append(.schemaVersionMismatch(model.schemaVersion))
        }

        // 重叠与越界只按同页块判定。
        let gridMinColumnByPage = Dictionary(
            grouping: model.drawerBlocks, by: \.page
        ).mapValues { $0.map(\.originColumn).min() ?? 0 }
        for (index, block) in model.drawerBlocks.enumerated() {
            for other in model.drawerBlocks.dropFirst(index + 1)
            where other.page == block.page && Self.rectsOverlap(block, other) {
                issues.append(.overlap(first: block.placementID, second: other.placementID))
            }
            let columns = effectiveMaxColumns()
            let gridMinColumn = gridMinColumnByPage[block.page] ?? 0
            // 列双向扩大：originColumn 可以为负（左侧拖出自动左扩），
            // 越界只看合并后的列跨度是否超过容量；行仍仅向下（非负）。
            if block.originRow < 0
                || (block.originColumn - gridMinColumn) + block.widthColumns > columns {
                issues.append(.outOfBounds(placementID: block.placementID))
            }
            switch blockResolver(block.pluginID, block.blockID)?.kind {
            case .compact:
                issues.append(.drawerBlockKindMismatch(placementID: block.placementID))
            case .drawer, .none:
                break
            }
            if blockResolver(block.pluginID, block.blockID) == nil {
                issues.append(.unknownBlock(pluginID: block.pluginID, blockID: block.blockID))
            }
            if let definition = blockResolver(block.pluginID, block.blockID),
               case .drawer = definition.kind {
                let declared = definition.supportedSpans.contains(
                    GridSpan(columns: block.widthColumns, rows: block.heightRows)
                )
                if !declared {
                    issues.append(.sizeNotSupported(placementID: block.placementID))
                }
            }
        }

        for slot in model.compactSlots {
            guard let slot else { continue }
            if blockResolver(slot.pluginID, slot.blockID)?.kind == .drawer {
                issues.append(.compactBlockKindMismatch(placementID: slot.placementID))
            }
            if blockResolver(slot.pluginID, slot.blockID) == nil {
                issues.append(.unknownBlock(pluginID: slot.pluginID, blockID: slot.blockID))
            }
        }

        return issues
    }
}
