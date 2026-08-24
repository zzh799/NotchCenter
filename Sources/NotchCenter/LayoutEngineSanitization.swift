import Foundation
import NotchCenterKit

// MARK: - 加载净化（损坏布局自愈）

extension LayoutEngine {
    /// 加载时净化历史损坏布局：旧版推挤算法（同步 +1 行）会把粘连块对连同
    /// 残留重叠一起写盘，行号随之失控增长。持久重叠只可能来自该 bug，
    /// 因此仅在检测到重叠时触发一次「去重叠 + 向上压实」；正常布局
    /// （含用户刻意留白）不受影响。块顺序与列位置保持不变。
    /// （原为类内 `private static`，拆分后供 init 跨文件调用，模块内可见。）
    static func sanitized(_ model: LayoutModel) -> LayoutModel {
        var blocks = model.drawerBlocks
        let hasOverlap = blocks.indices.contains { i in
            blocks[(i + 1)...].contains { rectsOverlap(blocks[i], $0) }
        }
        guard hasOverlap else { return model }

        // 去重叠：按（行,列）顺序逐块安放，重叠则下移（与拖拽推挤同语义）。
        // 附 placementID 决胜保证同格粘连对的相对顺序跨启动稳定。
        func ordered(_ list: [PlacedBlock]) -> [PlacedBlock] {
            list.sorted { lhs, rhs in
                if lhs.originRow != rhs.originRow { return lhs.originRow < rhs.originRow }
                if lhs.originColumn != rhs.originColumn { return lhs.originColumn < rhs.originColumn }
                return lhs.placementID < rhs.placementID
            }
        }

        var placed: [PlacedBlock] = []
        for var block in ordered(blocks) {
            while placed.contains(where: { rectsOverlap(block, $0) }) {
                block.originRow += 1
            }
            placed.append(block)
        }

        // 向上压实：仍按（行,列）顺序，把每块上移到列不变且不与已放置块重叠的
        // 最高位置，消除历史失控行号造成的巨大空洞。
        var settled: [PlacedBlock] = []
        for block in ordered(placed) {
            var candidate = block
            while candidate.originRow > 0 {
                var probe = candidate
                probe.originRow -= 1
                if settled.contains(where: { rectsOverlap(probe, $0) }) { break }
                candidate = probe
            }
            settled.append(candidate)
        }

        // 恢复原始数组顺序（placementID 不变，仅修正坐标）。
        let originByID = Dictionary(uniqueKeysWithValues: settled.map { ($0.placementID, $0) })
        var result = model
        result.drawerBlocks = blocks.map { originByID[$0.placementID] ?? $0 }
        return result
    }
}
