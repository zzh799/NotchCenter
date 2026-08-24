import Foundation

// MARK: - 空洞压实（编辑模式契约：不留空行/空列）

extension LayoutEngine {
    /// 垂直压实（编辑模式契约：不留空行）：自上而下找到首个完全空置的行，
    /// 把其下所有块整体上移一行，重复直到没有空行。行内的部分留白保留
    /// （只消整行空洞）；下方块整体上移、相对位置不变，不产生新重叠。
    /// 仅由变更路径调用（移动/移除/缩放/提交后），加载净化不经过这里
    /// （无重叠布局的留白受 `sanitized` 保护）。
    /// （模块内私有：拆分后供修改路径跨文件调用，勿对外使用。）
    @discardableResult
    func compactEmptyRows() -> Bool {
        var changed = false
        while true {
            let maxRow = model.drawerBlocks.map { $0.originRow + $0.heightRows }.max() ?? 0
            guard maxRow > 0 else { break }
            var occupiedRows = Set<Int>()
            for block in model.drawerBlocks {
                for row in block.originRow..<block.originRow + block.heightRows {
                    occupiedRows.insert(row)
                }
            }
            // 空行必在其上有块（maxRow 内）且其下有块（否则推不出 maxRow），
            // 上移后该行被填充，每轮严格减少总行数——必然终止。
            guard let emptyRow = (0..<maxRow).first(where: { !occupiedRows.contains($0) }) else { break }
            for index in model.drawerBlocks.indices where model.drawerBlocks[index].originRow > emptyRow {
                model.drawerBlocks[index].originRow -= 1
            }
            changed = true
        }
        return changed
    }

    /// 水平压实（编辑模式契约：不留空列）：在占用列区间 [min, max) 内自左
    /// 向右找到首个完全空置的列，右侧块整体左移一列（空列 ≥ 0 时）；若空列
    /// 为负（左扩区域内的空洞），左侧块整体右移一列——双向都朝 0 收拢，
    /// 不产生新重叠。重复直到没有空列。列内的部分留白保留（只消整列空洞）。
    /// 与 compactEmptyRows 对称，仅由变更路径调用（移动/移除/缩放/提交后），
    /// 加载净化不经过这里（无重叠布局的留白受 sanitized 保护）。
    /// （模块内私有：拆分后供修改路径跨文件调用，勿对外使用。）
    @discardableResult
    func compactEmptyColumns() -> Bool {
        var changed = false
        while true {
            let minColumn = model.drawerBlocks.map(\.originColumn).min() ?? 0
            let maxColumn = model.drawerBlocks.map { $0.originColumn + $0.widthColumns }.max() ?? 0
            guard maxColumn > minColumn else { break }
            var occupiedColumns = Set<Int>()
            for block in model.drawerBlocks {
                for col in block.originColumn..<block.originColumn + block.widthColumns {
                    occupiedColumns.insert(col)
                }
            }
            // 空列必在其左有块（minColumn 内）且其右有块（否则推不出 maxColumn），
            // 向 0 方向收拢一列，每轮严格减少总跨度——必然终止。
            guard let emptyColumn = (minColumn..<maxColumn)
                .first(where: { !occupiedColumns.contains($0) }) else { break }
            if emptyColumn >= 0 {
                for index in model.drawerBlocks.indices where model.drawerBlocks[index].originColumn > emptyColumn {
                    model.drawerBlocks[index].originColumn -= 1
                }
            } else {
                for index in model.drawerBlocks.indices where model.drawerBlocks[index].originColumn < emptyColumn {
                    model.drawerBlocks[index].originColumn += 1
                }
            }
            changed = true
        }
        return changed
    }
}
