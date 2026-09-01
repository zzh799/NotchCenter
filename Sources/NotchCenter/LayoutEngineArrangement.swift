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
    /// 安放顺序按 `orderedPlacementsForMove` 插入：**向下拖压到下方相邻块
    /// 即交换**（与上移同阈值）；上移/水平为被拖块抢占语义。
    func previewArrangement(moving placementID: String, toColumn: Int, toRow: Int) -> [String: GridOrigin] {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return [:]
        }
        var changed = model.drawerBlocks[index]
        let siblings = siblings(of: changed)
        let bounds = validColumnRange(others: siblings, width: changed.widthColumns)
        changed.originColumn = min(max(toColumn, bounds.lower), bounds.upper)
        changed.originRow = max(toRow, 0)
        let ordered = orderedPlacementsForMove(
            changed,
            sourceRow: model.drawerBlocks[index].originRow,
            others: siblings
        )
        return Self.placeInOrder(ordered)
    }

    /// moving 拖拽的安放顺序（阅读顺序重排）：
    /// - **下移**（clamp 后目标行 > 原行）：与**目标矩形重叠**的其余块先安放
    ///   （保位优先），被拖块随后，其余块殿后——首次压到下方块即交换。
    ///   判据不能是「`originRow <= 目标行`」（跨过下方块顶缘才交换）：行顶边
    ///   锚定 + 空行压实会把被拖块腾出的顶部行闭合，未真正交换的下移一律零反馈，
    ///   大组件要拖到跨过下方块顶缘（紧邻时即自身高度的格数）才交换，而上移 1 格就换——方向偏置。
    /// - **上移/水平**：被拖块首位（抢占语义，与旧 `pushDownOrigins(changed:)`
    ///   逐位一致——上移交换与水平交换手感不变）。
    /// `others` 必须是**被拖块所在页**的其余块。
    private func orderedPlacementsForMove(
        _ changed: PlacedBlock, sourceRow: Int, others: [PlacedBlock]
    ) -> [PlacedBlock] {
        let sorted = others.sorted(by: Self.inReadingOrder)
        guard changed.originRow > sourceRow else {
            return [changed] + sorted
        }
        let before = sorted.filter { Self.rectsOverlap($0, changed) }
        let after = sorted.filter { !Self.rectsOverlap($0, changed) }
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
        // 离线压实只在本页副本上跑，否则会改到其他页块的行号。
        guard let moved = drawerBlock(placementID: placementID) else { return origins }
        var blocks = drawerBlocks(onPage: moved.page)
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
        guard let block = drawerBlock(placementID: placementID) else {
            return (0, 0)
        }
        return validColumnRange(others: siblings(of: block), width: block.widthColumns)
    }

    /// 缩放实时预览（不落盘）：把 `placementID` 视为已改到目标跨度（原点不动，
    /// 仅按列跨度 clamp 到容量内），其余块推挤下移——上方块扩大时下方整块下移、
    /// 面板随之增高的实时依据。跨度不在 supportedSpans 内返回空。
    func previewArrangement(resizing placementID: String, toColumns: Int, toRows: Int) -> [String: GridOrigin] {
        guard var changed = drawerBlock(placementID: placementID),
              let definition = blockResolver(changed.pluginID, changed.blockID),
              definition.supportedSpans.contains(GridSpan(columns: toColumns, rows: toRows)) else {
            return [:]
        }
        let bounds = validColumnRange(others: siblings(of: changed), width: toColumns)
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
        let orderedOthers = siblings(of: changed).sorted(by: Self.inReadingOrder)
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
            let bounds = validColumnRange(others: siblings(of: block), width: block.widthColumns)
            model.drawerBlocks[index].originColumn = min(max(target.column, bounds.lower), bounds.upper)
            model.drawerBlocks[index].originRow = max(target.row, 0)
        }
    }

    /// 容量缩小后的越界重排（纯函数，单页）：渲染可见列窗口 =
    /// `[rangeMin, rangeMin + capacity)`（rangeMin 即该页 gridLeft），合并跨度
    /// 超出容量时右缘块被裁。修复 = 保持左缘锚定不动，越出右缘的块把
    /// `originColumn` 就近夹回窗口（最近合法位置 = 贴窗口右缘），再按
    /// 「窗口内原块（阅读序）先固定、夹回块殿后」走 `placeInOrder`——撞上
    /// 已固定块即下移，行顶边锚定、列不再动；最后按提交侧同序压实空行/空列。
    /// 修完跨度 ≤ 容量，重复调用零操作（幂等，滑条连续拖动每档触发一次）。
    ///
    /// 不能走 `applyOrigins`/`validColumnRange`：越界状态下合法区间退化
    /// （lower > upper），clamp 失效，修复必须整页一次算好。块宽超过容量的
    /// 极端情况无法用列位移修复，夹回窗口左缘、接受部分裁切（与窄屏现状
    /// 一致，不改写块跨度），其余块照常收拢。
    /// （模块内私有：仅 `repairBlocksBeyondCapacity` 实例入口调用。）
    static func repairCapacityOverflow(
        _ pageBlocks: [PlacedBlock],
        capacity: Int
    ) -> (blocks: [PlacedBlock], changed: Bool) {
        guard !pageBlocks.isEmpty, capacity > 0 else { return (pageBlocks, false) }
        let rangeMin = pageBlocks.map(\.originColumn).min() ?? 0
        let rangeMax = pageBlocks.map { $0.originColumn + $0.widthColumns }.max() ?? 0
        guard rangeMax - rangeMin > capacity else { return (pageBlocks, false) }

        var anchored: [PlacedBlock] = []
        var pulledIn: [PlacedBlock] = []
        for var block in pageBlocks {
            let upper = max(rangeMin, rangeMin + capacity - block.widthColumns)
            guard block.originColumn < rangeMin || block.originColumn > upper else {
                anchored.append(block)
                continue
            }
            block.originColumn = min(max(block.originColumn, rangeMin), upper)
            pulledIn.append(block)
        }
        // 跨度超容量必有块越出右缘（rangeMax 的达成块），此分支纯防御。
        guard !pulledIn.isEmpty else { return (pageBlocks, false) }

        let origins = placeInOrder(anchored.sorted(by: inReadingOrder) + pulledIn.sorted(by: inReadingOrder))
        var arranged = pageBlocks
        for index in arranged.indices {
            guard let origin = origins[arranged[index].placementID] else { continue }
            arranged[index].originColumn = origin.column
            arranged[index].originRow = origin.row
        }
        arranged = compactEmptyRows(arranged).blocks
        arranged = compactEmptyColumns(arranged).blocks
        return (arranged, true)
    }
}
