import Combine
import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 布局引擎

/// 布局引擎：紧凑槽位 + 抽屉网格的放置、移动、缩放、重叠检测与原子持久化
/// （文档 §5 / §7）。
@MainActor
final class LayoutEngine: ObservableObject {
    enum LayoutIssue: Equatable {
        case schemaVersionMismatch(Int)
        case compactSlotCountMismatch
        case overlap(first: String, second: String)
        case outOfBounds(placementID: String)
        case unknownBlock(pluginID: String, blockID: String)
        case compactBlockKindMismatch(placementID: String)
        case drawerBlockKindMismatch(placementID: String)
        case sizeNotSupported(placementID: String)
    }

    @Published private(set) var model: LayoutModel

    /// 供校验/测试与未来迁移使用的内部写入入口；核心公开行为通过下方操作 API 完成。
    var modelForTesting: LayoutModel {
        get { model }
        set {
            model = newValue
            saveToDisk()
        }
    }

    /// 首次创建（磁盘无文件）时为 true，用于首启默认启用内置插件。
    let didLoadFromDisk: Bool

    /// 块解析器：由核心注入，用于尺寸/种类校验。
    let blockResolver: @MainActor (String, String) -> NotchBlock?

    private let fileURL: URL
    private let fileManager: FileManager

    /// 当前可用屏幕宽度（由面板控制器随屏幕变化更新，文档 §7.2）。
    private var availableScreenWidth: CGFloat = 1440

    init(
        fileURL: URL = CorePaths.layoutFileURL,
        blockResolver: @escaping @MainActor (String, String) -> NotchBlock?,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.blockResolver = blockResolver
        self.fileManager = fileManager

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LayoutModel.self, from: data),
           decoded.schemaVersion <= LayoutModel.currentSchemaVersion {
            model = Self.sanitized(decoded)
            didLoadFromDisk = true
        } else {
            model = LayoutModel()
            didLoadFromDisk = false
        }
        saveToDisk()
    }

    /// 加载时净化历史损坏布局：旧版推挤算法（同步 +1 行）会把粘连块对连同
    /// 残留重叠一起写盘，行号随之失控增长。持久重叠只可能来自该 bug，
    /// 因此仅在检测到重叠时触发一次「去重叠 + 向上压实」；正常布局
    /// （含用户刻意留白）不受影响。块顺序与列位置保持不变。
    private static func sanitized(_ model: LayoutModel) -> LayoutModel {
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

    // MARK: - 查询

    var enabledPluginIDs: Set<String> {
        Set(model.enabledPluginIDs)
    }

    var compactSlots: [CompactSlotReference?] {
        model.compactSlots
    }

    var drawerBlocks: [PlacedBlock] {
        model.drawerBlocks
    }

    var userMaxColumns: Int {
        model.maxColumns
    }

    func compactSlot(at index: Int) -> CompactSlotReference? {
        guard model.compactSlots.indices.contains(index) else { return nil }
        return model.compactSlots[index]
    }

    func drawerBlock(placementID: String) -> PlacedBlock? {
        model.drawerBlocks.first { $0.placementID == placementID }
    }

    // MARK: - 布局修改

    func setUserMaxColumns(_ columns: Int) {
        let clamped = min(max(columns, 2), 8)
        guard model.maxColumns != clamped else { return }
        model.maxColumns = clamped
        saveToDisk()
    }

    /// 屏幕宽度约束（文档 §7.2）：实际列数 = min(用户配置, 屏幕能容纳的列数)。
    func updateScreenConstraint(width: CGFloat) {
        availableScreenWidth = width
    }

    func effectiveMaxColumns() -> Int {
        let capacity = max(
            1,
            Int(
                (availableScreenWidth - NotchGridMetrics.contentPadding * 2
                    + NotchGridMetrics.spacing)
                    / (NotchGridMetrics.cellWidth + NotchGridMetrics.spacing)
            )
        )
        return min(model.maxColumns, capacity)
    }

    /// 同步启用插件列表（文档 §5.4：enabledPluginIDs 存于 layout.json）。
    func syncEnabledPluginIDs(_ ids: Set<String>) {
        let sorted = ids.sorted()
        guard Set(model.enabledPluginIDs) != ids else { return }
        model.enabledPluginIDs = sorted
        saveToDisk()
    }

    /// 首启默认启用内置插件（文档未强制，但官方插件应在首次启动时可用）。
    func seedEnabledBuiltIns(_ ids: Set<String>) {
        guard !didLoadFromDisk else { return }
        model.enabledPluginIDs = Array(ids).sorted()
        saveToDisk()
    }

    // MARK: 紧凑槽位（文档 §5.2）

    func setCompactSlot(_ index: Int, to ref: CompactSlotReference?) {
        guard model.compactSlots.indices.contains(index) else { return }
        model.compactSlots[index] = ref
        saveToDisk()
    }

    func swapCompactSlots(_ first: Int, _ second: Int) {
        guard model.compactSlots.indices.contains(first),
              model.compactSlots.indices.contains(second) else { return }
        model.compactSlots.swapAt(first, second)
        saveToDisk()
    }

    /// 添加紧凑块到第一个空槽位；无空槽返回 false。
    @discardableResult
    func addCompactBlock(pluginID: String, blockID: String) -> Bool {
        guard let block = blockResolver(pluginID, blockID), block.kind == .compact else {
            return false
        }
        guard let emptyIndex = model.compactSlots.firstIndex(where: { $0 == nil }) else {
            return false
        }
        model.compactSlots[emptyIndex] = CompactSlotReference(
            pluginID: pluginID,
            blockID: blockID,
            placementID: UUID().uuidString
        )
        saveToDisk()
        return true
    }

    // MARK: 抽屉网格（文档 §5.3）

    /// 自动放置到第一个可用位置；超出最大列数后自动换行。
    @discardableResult
    func autoPlaceDrawerBlock(pluginID: String, blockID: String) -> PlacedBlock? {
        guard let block = blockResolver(pluginID, blockID), block.kind == .drawer else {
            return nil
        }
        let span = (block.defaultSize ?? .small).gridSpan
        let columns = effectiveMaxColumns()
        let occupied = occupiedRects(excluding: nil)

        // 在既有行内寻找首个可用位置。
        let maxRow = occupied.map(\.maxRow).max() ?? -1
        for row in 0...max(0, maxRow) {
            for col in 0...max(0, columns - span.columns) {
                let candidate = PlacedBlock(
                    pluginID: pluginID,
                    blockID: blockID,
                    placementID: UUID().uuidString,
                    originColumn: col,
                    originRow: row,
                    widthColumns: span.columns,
                    heightRows: span.rows
                )
                if !overlaps(candidate, with: occupied) {
                    model.drawerBlocks.append(candidate)
                    saveToDisk()
                    return candidate
                }
            }
        }

        // 无可用位置：新起一行（文档 §5.3：超出后自动换行；高度随内容增长，超高则滚动）。
        let placed = PlacedBlock(
            pluginID: pluginID,
            blockID: blockID,
            placementID: UUID().uuidString,
            originColumn: 0,
            originRow: maxRow + 1,
            widthColumns: span.columns,
            heightRows: span.rows
        )
        model.drawerBlocks.append(placed)
        saveToDisk()
        return placed
    }

    func removeDrawerBlock(placementID: String) {
        model.drawerBlocks.removeAll { $0.placementID == placementID }
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
    }

    /// 一键重排（编辑模式）：按“从上到下、从左到右”的阅读顺序紧密排布所有抽屉块。
    /// 以当前布局的阅读顺序为优先级，逐块放到首个不重叠位置（行优先扫描），
    /// 消除移动/缩放留下的空洞；块身份与跨度保持不变，仅调整原点。
    func reorderDrawerBlocks() {
        guard !model.drawerBlocks.isEmpty else { return }
        let columns = effectiveMaxColumns()

        // 阅读顺序即优先级：先看行再看列（元组比较）。
        let ordered = model.drawerBlocks.sorted {
            ($0.originRow, $0.originColumn) < ($1.originRow, $1.originColumn)
        }

        var occupied: [RectKey] = []
        var result: [PlacedBlock] = []
        result.reserveCapacity(ordered.count)

        for block in ordered {
            // 行优先扫描首个可用位置；扫描上界为已占最底行 + 1
            // （新起一行时必然无冲突，无需继续向下找）。
            var candidate = block
            let maxRow = occupied.map(\.maxRow).max() ?? -1
            scan: for row in 0...max(0, maxRow + 1) {
                for col in 0...max(0, columns - block.widthColumns) {
                    candidate.originColumn = col
                    candidate.originRow = row
                    if !overlaps(candidate, with: occupied) {
                        break scan
                    }
                }
            }
            occupied.append(rectKey(candidate))
            result.append(candidate)
        }

        model.drawerBlocks = result
        saveToDisk()
    }

    /// 移动抽屉块到目标位置；目标被占用时移动到最近可用位置。失败（无处可放或块不存在）返回 false。
    @discardableResult
    func moveDrawerBlock(placementID: String, toColumn: Int, toRow: Int) -> Bool {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return false
        }
        let block = model.drawerBlocks[index]
        let columns = effectiveMaxColumns()
        var bestTarget: PlacedBlock?

        // 优先目标位置（clamp 到网格内）。
        let clampedColumn = min(max(toColumn, 0), max(0, columns - block.widthColumns))
        let clampedRow = max(toRow, 0)
        var candidate = block
        candidate.originColumn = clampedColumn
        candidate.originRow = clampedRow
        if !overlaps(candidate, with: occupiedRects(excluding: placementID)) {
            bestTarget = candidate
        }

        // 否则按行优先扫描最近可用位置。
        if bestTarget == nil {
            let maxRow = max(model.drawerBlocks.map(\.maxRow).max() ?? 0, clampedRow)
            scan: for row in 0...maxRow + 1 {
                for col in 0...max(0, columns - block.widthColumns) {
                    var probe = block
                    probe.originColumn = col
                    probe.originRow = row
                    if !overlaps(probe, with: occupiedRects(excluding: placementID)) {
                        bestTarget = probe
                        break scan
                    }
                }
            }
        }

        guard var target = bestTarget else { return false }
        target.originColumn = min(max(target.originColumn, 0), max(0, columns - target.widthColumns))
        target.originRow = max(target.originRow, 0)
        model.drawerBlocks[index] = target
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
        return true
    }

    /// 在支持的尺寸等级间切换块尺寸（编辑模式，文档 §5.5）。
    @discardableResult
    func resizeDrawerBlock(placementID: String, to size: BlockSize) -> Bool {
        resizeDrawerBlock(
            placementID: placementID,
            toColumns: size.gridSpan.columns,
            toRows: size.gridSpan.rows
        )
    }

    /// 缩放块到任意声明的跨度（编辑模式）：跨度必须在块的 supportedSpans 内。
    /// 扩大与下方块重叠时不再回退，而是按阅读顺序推挤下移（与拖拽同一
    /// 逐块安放语义）；缩小留下的空行随后压实。左上角原点保持不变
    /// （仅越界列数时向左收紧）。
    @discardableResult
    func resizeDrawerBlock(placementID: String, toColumns: Int, toRows: Int) -> Bool {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return false
        }
        let block = model.drawerBlocks[index]
        guard let definition = blockResolver(block.pluginID, block.blockID),
              definition.supportedSpans.contains(GridSpan(columns: toColumns, rows: toRows)) else {
            return false
        }

        var resized = block
        resized.widthColumns = toColumns
        resized.heightRows = toRows

        let columns = effectiveMaxColumns()
        resized.originColumn = min(max(resized.originColumn, 0), max(0, columns - resized.widthColumns))
        resized.originRow = max(resized.originRow, 0)

        model.drawerBlocks[index] = resized
        applyOrigins(pushDownOrigins(changed: resized))
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
        return true
    }

    /// 格子坐标（编辑模式拖拽/边缘缩放用）。
    struct GridOrigin: Equatable {
        var column: Int
        var row: Int
    }

    /// 拖拽实时预览（不落盘，文档 §5.5）：把 `placementID` 放到目标格子，
    /// 被占用的块向下推挤（自动重排），返回全体块的新位置，key 为 placementID。
    func previewArrangement(moving placementID: String, toColumn: Int, toRow: Int) -> [String: GridOrigin] {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return [:]
        }
        var changed = model.drawerBlocks[index]
        let columns = effectiveMaxColumns()
        changed.originColumn = min(max(toColumn, 0), max(0, columns - changed.widthColumns))
        changed.originRow = max(toRow, 0)
        return pushDownOrigins(changed: changed)
    }

    /// 缩放实时预览（不落盘）：把 `placementID` 视为已改到目标跨度（原点不动，
    /// 仅按列宽 clamp 到网格内），其余块推挤下移——上方块扩大时下方整块下移、
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
        let columns = effectiveMaxColumns()
        changed.widthColumns = toColumns
        changed.heightRows = toRows
        changed.originColumn = min(max(changed.originColumn, 0), max(0, columns - changed.widthColumns))
        changed.originRow = max(changed.originRow, 0)
        return pushDownOrigins(changed: changed)
    }

    /// 推挤重排核心（逐块安放）：把 `changed`（已改到目标原点/跨度的块）
    /// 作为初始固定集合，其余块按（行,列,placementID）阅读顺序依次下移到
    /// 与所有已固定块都不重叠的首个位置后立即固定；未受影响的块零次移动，
    /// 保持原位（最小扰动）。
    ///
    /// 不能改为「每一轮让所有重叠块同步 +1 行」：重叠块同步移动时相对位置
    /// 不变、永不分离，循环只能靠次数上限退出，会把残留重叠写回布局；
    /// 粘连块对随后每次拖拽提交又被整体再推若干行，行号失控增长（历史 bug）。
    private func pushDownOrigins(changed: PlacedBlock) -> [String: GridOrigin] {
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

    /// 把推挤结果写回模型（clamp 到网格内）。
    private func applyOrigins(_ origins: [String: GridOrigin]) {
        let columns = effectiveMaxColumns()
        for index in model.drawerBlocks.indices {
            let block = model.drawerBlocks[index]
            guard let target = origins[block.placementID] else { continue }
            let clampedColumn = min(max(target.column, 0), max(0, columns - block.widthColumns))
            let clampedRow = max(target.row, 0)
            model.drawerBlocks[index].originColumn = clampedColumn
            model.drawerBlocks[index].originRow = clampedRow
        }
    }

    /// 垂直压实（编辑模式契约：不留空行）：自上而下找到首个完全空置的行，
    /// 把其下所有块整体上移一行，重复直到没有空行。行内的部分留白保留
    /// （只消整行空洞）；下方块整体上移、相对位置不变，不产生新重叠。
    /// 仅由变更路径调用（移动/移除/缩放/提交后），加载净化不经过这里
    /// （无重叠布局的留白受 `sanitized` 保护）。
    @discardableResult
    private func compactEmptyRows() -> Bool {
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

    /// 水平压实（编辑模式契约：不留空列）：自左向右找到首个完全空置的列，
    /// 把其右所有块整体左移一列，重复直到没有空列。列内的部分留白保留
    /// （只消整列空洞）；右侧块整体左移、相对位置不变，不产生新重叠。
    /// 与 compactEmptyRows 对称，仅由变更路径调用（移动/移除/缩放/提交后），
    /// 加载净化不经过这里（无重叠布局的留白受 sanitized 保护）。
    @discardableResult
    private func compactEmptyColumns() -> Bool {
        var changed = false
        while true {
            let maxColumn = model.drawerBlocks.map { $0.originColumn + $0.widthColumns }.max() ?? 0
            guard maxColumn > 0 else { break }
            var occupiedColumns = Set<Int>()
            for block in model.drawerBlocks {
                for col in block.originColumn..<block.originColumn + block.widthColumns {
                    occupiedColumns.insert(col)
                }
            }
            // 空列必在其左有块（maxColumn 内）且其右有块（否则推不出 maxColumn），
            // 左移后该列被填充，每轮严格减少总列数——必然终止。
            guard let emptyColumn = (0..<maxColumn).first(where: { !occupiedColumns.contains($0) }) else { break }
            for index in model.drawerBlocks.indices where model.drawerBlocks[index].originColumn > emptyColumn {
                model.drawerBlocks[index].originColumn -= 1
            }
            changed = true
        }
        return changed
    }

    /// 提交拖拽预览结果（与 previewArrangement 同一算法，保证所见即所得），
    /// 随后压实空行与空列（拖走后遗留的整行/整列空洞由下方/右侧块上移/左移闭合）。
    @discardableResult
    func commitArrangement(_ origins: [String: GridOrigin]) -> Bool {
        guard !origins.isEmpty else { return false }
        let before = model.drawerBlocks.map { "\($0.placementID):\($0.originColumn),\($0.originRow)" }
        applyOrigins(origins)
        compactEmptyRows()
        compactEmptyColumns()
        let after = model.drawerBlocks.map { "\($0.placementID):\($0.originColumn),\($0.originRow)" }
        let changed = before != after
        if changed {
            saveToDisk()
        }
        return changed
    }

    // MARK: - 持久化（文档 §5.4：单一版本化 JSON，原子写入）

    func saveToDisk() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 布局持久化失败不影响内存中的编辑。
            NSLog("LayoutEngine: failed to persist layout: \(error)")
        }
    }

    // MARK: - 内部

    private struct RectKey: Equatable {
        let minColumn: Int
        let minRow: Int
        let maxColumn: Int
        let maxRow: Int
    }

    private func occupiedRects(excluding placementID: String?) -> [RectKey] {
        model.drawerBlocks
            .filter { $0.placementID != placementID }
            .map(rectKey)
    }

    private func rectKey(_ block: PlacedBlock) -> RectKey {
        RectKey(
            minColumn: block.originColumn,
            minRow: block.originRow,
            maxColumn: block.originColumn + block.widthColumns,
            maxRow: block.originRow + block.heightRows
        )
    }

    private func overlaps(_ block: PlacedBlock, with others: [RectKey]) -> Bool {
        let key = rectKey(block)
        return others.contains { other in
            key.minColumn < other.maxColumn && other.minColumn < key.maxColumn
                && key.minRow < other.maxRow && other.minRow < key.maxRow
        }
    }

    static func rectsOverlap(_ a: PlacedBlock, _ b: PlacedBlock) -> Bool {
        a.originColumn < b.originColumn + b.widthColumns
            && b.originColumn < a.originColumn + a.widthColumns
            && a.originRow < b.originRow + b.heightRows
            && b.originRow < a.originRow + a.heightRows
    }
}