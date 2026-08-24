import Foundation
import NotchCenterKit

// MARK: - 推挤与预览算法

extension LayoutEngine {
    /// 格子坐标（编辑模式拖拽/边缘缩放用）。
    struct GridOrigin: Equatable {
        var column: Int
        var row: Int
    }

    /// 拖拽实时预览（不落盘，文档 §5.5）：把 `placementID` 放到目标格子，
    /// 被占用的块向下推挤（自动重排），返回全体块的新位置，key 为 placementID。
    /// 列支持左右双向：目标列可为负（向左拖出时格网随内容向左扩大），
    /// 但合并后的总跨度不得超过容量（屏幕约束）。
    func previewArrangement(moving placementID: String, toColumn: Int, toRow: Int) -> [String: GridOrigin] {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return [:]
        }
        var changed = model.drawerBlocks[index]
        let bounds = validColumnRange(
            others: model.drawerBlocks.filter { $0.placementID != placementID },
            width: changed.widthColumns
        )
        changed.originColumn = min(max(toColumn, bounds.lower), bounds.upper)
        changed.originRow = max(toRow, 0)
        return pushDownOrigins(changed: changed)
    }

    /// 缩放实时预览（不落盘）：把 `placementID` 视为已改到目标跨度（原点不动，
    /// 仅按列跨度 clamp 到容量内），其余块推挤下移——上方块扩大时下方整块下移、
    /// 面板随之增高的实时依据。跨度不在 supportedSpans 内返回空。
    func previewArrangement(resizing placementID: String, toColumns: Int, toRows: Int) -> [String: GridOrigin] {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return [:]
        }
        var changed = model.drawerBlocks[index]
        guard let definition = blockResolver(changed.pluginID, changed.blockID),
              definition.supportedSpans.contains(GridSpan(columns: toColumns, rows: toRows)) else {
            return [:]
        }
        let bounds = validColumnRange(
            others: model.drawerBlocks.filter { $0.placementID != placementID },
            width: toColumns
        )
        changed.widthColumns = toColumns
        changed.heightRows = toRows
        changed.originColumn = min(max(changed.originColumn, bounds.lower), bounds.upper)
        changed.originRow = max(changed.originRow, 0)
        return pushDownOrigins(changed: changed)
    }

    /// 移动/缩放目标列的合法区间：把目标块（跨度 width）并入其他块的占用区
    /// 后，整体列跨度不得超过容量。左扩时区间下限可为负（格网向左扩展），
    /// 右扩时上限按容量收紧；其他块为空时以 0 为基线。
    /// 推导：finalMin = min(othersMin, col)，finalMax = max(othersMax, col + width)，
    /// 要求 finalMax − finalMin ≤ capacity ⟺ col ∈ [othersMax − capacity,
    /// othersMin + capacity − width]。
    /// （模块内私有：拆分后供修改路径与预览算法跨文件协作，勿对外使用。）
    func validColumnRange(others: [PlacedBlock], width: Int) -> (lower: Int, upper: Int) {
        let othersMin = others.map(\.originColumn).min() ?? 0
        let othersMax = others.map { $0.originColumn + $0.widthColumns }.max() ?? 0
        let capacity = effectiveMaxColumns()
        return (othersMax - capacity, othersMin + capacity - width)
    }

    /// 推挤重排核心（逐块安放）：把 `changed`（已改到目标原点/跨度的块）
    /// 作为初始固定集合，其余块按（行,列,placementID）阅读顺序依次下移到
    /// 与所有已固定块都不重叠的首个位置后立即固定；未受影响的块零次移动，
    /// 保持原位（最小扰动）。
    ///
    /// 不能改为「每一轮让所有重叠块同步 +1 行」：重叠块同步移动时相对位置
    /// 不变、永不分离，循环只能靠次数上限退出，会把残留重叠写回布局；
    /// 粘连块对随后每次拖拽提交又被整体再推若干行，行号失控增长（历史 bug）。
    ///
    /// （模块内私有：拆分后供修改路径与预览算法跨文件协作，勿对外使用；
    /// 上方语义说明受 AGENTS.md 保护，改动推挤逻辑前先读 DragReorderReproTests。）
    func pushDownOrigins(changed: PlacedBlock) -> [String: GridOrigin] {
        var fixed = [changed]
        let orderedOthers = model.drawerBlocks
            .filter { $0.placementID != changed.placementID }
            .sorted { lhs, rhs in
                if lhs.originRow != rhs.originRow { return lhs.originRow < rhs.originRow }
                if lhs.originColumn != rhs.originColumn { return lhs.originColumn < rhs.originColumn }
                return lhs.placementID < rhs.placementID
            }

        for var block in orderedOthers {
            // 终止性：每次迭代 originRow 严格递增，超过当前最深占用行后
            // 不可能再与任何已固定块重叠，必然退出。
            while fixed.contains(where: { Self.rectsOverlap(block, $0) }) {
                block.originRow += 1
            }
            fixed.append(block)
        }

        var result: [String: GridOrigin] = [:]
        for placement in fixed {
            result[placement.placementID] = GridOrigin(column: placement.originColumn, row: placement.originRow)
        }
        return result
    }

    /// 把推挤结果写回模型（逐个按合法列区间 clamp，左侧可为负——左扩）。
    /// （模块内私有：拆分后供修改路径与提交路径跨文件协作，勿对外使用。）
    func applyOrigins(_ origins: [String: GridOrigin]) {
        for index in model.drawerBlocks.indices {
            let block = model.drawerBlocks[index]
            guard let target = origins[block.placementID] else { continue }
            let bounds = validColumnRange(
                others: model.drawerBlocks.filter { $0.placementID != block.placementID },
                width: block.widthColumns
            )
            model.drawerBlocks[index].originColumn = min(max(target.column, bounds.lower), bounds.upper)
            model.drawerBlocks[index].originRow = max(target.row, 0)
        }
    }
}
