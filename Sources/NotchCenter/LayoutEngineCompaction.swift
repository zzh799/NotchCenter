import Foundation

// MARK: - 空洞压实（编辑模式契约：不留空行、仅压负列）

extension LayoutEngine {
    /// 垂直压实纯函数（编辑模式契约：不留空行）：自上而下找到首个完全空置
    /// 的行，把其下所有块整体上移一行，重复直到没有空行。行内的部分留白保留
    /// （只消整行空洞）；下方块整体上移、相对位置不变，不产生新重叠。
    /// 不读写 `model`——修改路径经实例转发调用，预览路径在临时副本上调用
    /// （离线压实，与提交同一算法）。加载净化不经过这里（无重叠布局的留白
    /// 受 `sanitized` 保护）。
    /// （模块内私有：拆分后供修改路径跨文件调用，勿对外使用。）
    static func compactEmptyRows(_ blocks: [PlacedBlock]) -> (blocks: [PlacedBlock], changed: Bool) {
        var blocks = blocks
        var changed = false
        while true {
            let maxRow = blocks.map { $0.originRow + $0.heightRows }.max() ?? 0
            guard maxRow > 0 else { break }
            var occupiedRows = Set<Int>()
            for block in blocks {
                for row in block.originRow..<block.originRow + block.heightRows {
                    occupiedRows.insert(row)
                }
            }
            // 空行必在其上有块（maxRow 内）且其下有块（否则推不出 maxRow），
            // 上移后该行被填充，每轮严格减少总行数——必然终止。
            guard let emptyRow = (0..<maxRow).first(where: { !occupiedRows.contains($0) }) else { break }
            for index in blocks.indices where blocks[index].originRow > emptyRow {
                blocks[index].originRow -= 1
            }
            changed = true
        }
        return (blocks, changed)
    }

    /// 水平压实纯函数（编辑模式：仅闭合负列空洞，向 0 收拢）：在占用列区间
    /// [min, max) 内自左向右找到首个完全空置的**负**列（< 0），左侧块整体右移
    /// 一列——双向中的负向分支，与 compactEmptyRows 对称。**正列（≥ 0）的空洞
    /// 保留**：两个组件间允许留空列（用户可拖出有意留白），压实不再把右侧块
    /// 左移闭合；只有左扩区域（originColumn < 0）内的空洞会向 0 收拢，避免负向
    /// 布局无限外扩。列内的部分留白保留（只消整列空洞）。
    /// 不读写 `model`——修改路径经实例转发调用，预览路径在临时副本上调用
    /// （离线压实，与提交同一算法）。与 compactEmptyRows 对称，加载净化不经
    /// 过这里（无重叠布局的留白受 sanitized 保护）。
    /// （模块内私有：拆分后供修改路径跨文件调用，勿对外使用。）
    static func compactEmptyColumns(_ blocks: [PlacedBlock]) -> (blocks: [PlacedBlock], changed: Bool) {
        var blocks = blocks
        var changed = false
        while true {
            let minColumn = blocks.map(\.originColumn).min() ?? 0
            let maxColumn = blocks.map { $0.originColumn + $0.widthColumns }.max() ?? 0
            guard maxColumn > minColumn else { break }
            var occupiedColumns = Set<Int>()
            for block in blocks {
                for col in block.originColumn..<block.originColumn + block.widthColumns {
                    occupiedColumns.insert(col)
                }
            }
            // 仅闭合负列空洞：正列 ≥ 0 的空洞是有意留白，保留不压。
            // 空列必在其左有块（minColumn 内）且其右有块（否则推不出 maxColumn），
            // 找到首个负空列后左侧块向 0 右移一列，每轮严格减少负向跨度——必然终止。
            guard let emptyColumn = (minColumn..<maxColumn)
                .first(where: { $0 < 0 && !occupiedColumns.contains($0) }) else { break }
            for index in blocks.indices where blocks[index].originColumn < emptyColumn {
                blocks[index].originColumn += 1
            }
            changed = true
        }
        return (blocks, changed)
    }

    /// 垂直压实（实例转发）：按页分组闭合行空洞并写回。
    @discardableResult
    func compactEmptyRows() -> Bool {
        let result = Self.perPage(model.drawerBlocks) { Self.compactEmptyRows($0) }
        model.drawerBlocks = result.blocks
        return result.changed
    }

    /// 水平压实（实例转发）：按页分组闭合列空洞并写回。
    @discardableResult
    func compactEmptyColumns() -> Bool {
        let result = Self.perPage(model.drawerBlocks, Self.compactEmptyColumns(_:))
        model.drawerBlocks = result.blocks
        return result.changed
    }

    /// 按页分组套用纯函数（页内隔离的共用机制），结果按原数组位置写回——
    /// 数组顺序影响视图 ForEach 稳定性，不得重排。
    static func perPage(
        _ blocks: [PlacedBlock],
        _ transform: ([PlacedBlock]) -> (blocks: [PlacedBlock], changed: Bool)
    ) -> (blocks: [PlacedBlock], changed: Bool) {
        var result = blocks
        var changed = false
        for page in Set(blocks.map(\.page)) {
            let indices = blocks.indices.filter { blocks[$0].page == page }
            let pageResult = transform(indices.map { blocks[$0] })
            changed = changed || pageResult.changed
            for (offset, index) in indices.enumerated() {
                result[index] = pageResult.blocks[offset]
            }
        }
        return (result, changed)
    }
}
