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
    ///
    /// 安放顺序按 `orderedPlacementsForMove` 插入：**向下拖跨过下方相邻块
    /// 顶缘后可交换**（旧语义里被拖块恒占阅读序首位，下移后压实拉回原状、
    /// 永远无法交换）；上移/水平逐位保持旧语义。
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
        let ordered = orderedPlacementsForMove(changed, sourceRow: model.drawerBlocks[index].originRow)
        return Self.placeInOrder(ordered)
    }

    /// moving 拖拽的安放顺序（阅读顺序重排）：
    /// - **下移**（clamp 后目标行 > 原行）：`originRow <= 目标行` 的其余块
    ///   先安放（其顶缘已被跨过，保位优先），被拖块随后，其余块殿后——
    ///   跨过下方块顶缘即交换，未跨顶缘则压实拉回原状（零反馈即「未跨越」）。
    /// - **上移/水平**：被拖块首位（抢占语义，与旧 `pushDownOrigins(changed:)`
    ///   逐位一致——上移交换与水平交换手感不变）。
    private func orderedPlacementsForMove(
        _ changed: PlacedBlock, sourceRow: Int
    ) -> [PlacedBlock] {
        let others = model.drawerBlocks
            .filter { $0.placementID != changed.placementID }
            .sorted(by: Self.inReadingOrder)
        guard changed.originRow > sourceRow else {
            return [changed] + others
        }
        let before = others.filter { $0.originRow <= changed.originRow }
        let after = others.filter { $0.originRow > changed.originRow }
        return before + [changed] + after
    }

    /// 拖动预览组合 API（不落盘）：推挤 + 离线压实一次返回，保证**预览 ==
    /// 提交**——`previewArrangement(moving:)` 得到推挤 origins 后，在
    /// `model.drawerBlocks` 的临时副本上按提交侧同序（先空行后空列）跑
    /// 纯函数压实。严禁走 `applyOrigins`（它写实时布局模型）。
    /// 占位框与实时推挤都以此为准：松手 `commitArrangement` 收到压实过的
    /// origins，其末尾压实为幂等兜底（零操作），不再产生二次位移。
    func previewCommittedArrangement(
        moving placementID: String, toColumn: Int, toRow: Int
    ) -> [String: GridOrigin] {
        let origins = previewArrangement(moving: placementID, toColumn: toColumn, toRow: toRow)
        guard !origins.isEmpty else { return origins }
        var blocks = model.drawerBlocks
        for index in blocks.indices {
            guard let target = origins[blocks[index].placementID] else { continue }
            blocks[index].originColumn = target.column
            blocks[index].originRow = target.row
        }
        blocks = Self.compactEmptyRows(blocks).blocks
        blocks = Self.compactEmptyColumns(blocks).blocks
        var compacted: [String: GridOrigin] = [:]
        for block in blocks {
            compacted[block.placementID] = GridOrigin(column: block.originColumn, row: block.originRow)
        }
        return compacted
    }

    /// 拖动目标列的合法区间（`validColumnRange` 的对外门面）：下界可为负
    /// ——左扩内建（向左拖出时格网随内容向左扩大），容量约束内建。供
    /// 控制器层在预览与提交前夹紧目标列，两条路径共用（所见即所得）。
    func dropTargetColumnBounds(placementID: String) -> (lower: Int, upper: Int) {
        guard let block = model.drawerBlocks.first(where: { $0.placementID == placementID }) else {
            return (0, 0)
        }
        return validColumnRange(
            others: model.drawerBlocks.filter { $0.placementID != placementID },
            width: block.widthColumns
        )
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
        let orderedOthers = model.drawerBlocks
            .filter { $0.placementID != changed.placementID }
            .sorted(by: Self.inReadingOrder)
        return Self.placeInOrder([changed] + orderedOthers)
    }

    /// 阅读顺序比较器（行,列,placementID）：安放顺序的唯一权威定义。
    static func inReadingOrder(_ lhs: PlacedBlock, _ rhs: PlacedBlock) -> Bool {
        if lhs.originRow != rhs.originRow { return lhs.originRow < rhs.originRow }
        if lhs.originColumn != rhs.originColumn { return lhs.originColumn < rhs.originColumn }
        return lhs.placementID < rhs.placementID
    }

    /// 按给定顺序逐块安放（推挤核心，纯函数）：每块从其当前位置起向下移到
    /// 与所有已固定块都不重叠的首个位置后立即固定；未受影响的块零次移动，
    /// 保持原位（最小扰动）。安放顺序由调用方决定（`pushDownOrigins` 用
    /// 「changed 首位 + 其余阅读序」，moving 拖拽预览用插入序，见
    /// `orderedPlacementsForMove`）。
    ///
    /// 不能改为「每一轮让所有重叠块同步 +1 行」：重叠块同步移动时相对位置
    /// 不变、永不分离，循环只能靠次数上限退出，会把残留重叠写回布局；
    /// 粘连块对随后每次拖拽提交又被整体再推若干行，行号失控增长（历史 bug）。
    /// （本约束受 AGENTS.md 保护，改动前先读 DragReorderReproTests。）
    static func placeInOrder(_ ordered: [PlacedBlock]) -> [String: GridOrigin] {
        var fixed: [PlacedBlock] = []
        for var block in ordered {
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
