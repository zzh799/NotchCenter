import Combine
import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 网格指标（文档 §5.3）

/// 抽屉网格固定指标：单元格 150×120，间距 12，内容内边距 16。
enum NotchGridMetrics {
    static let cellWidth: CGFloat = 150
    static let cellHeight: CGFloat = 120
    static let spacing: CGFloat = 12
    static let contentPadding: CGFloat = 16
    /// 抽屉窗口顶部栏（钉住 / 编辑等按钮）高度。
    static let drawerTopBarHeight: CGFloat = 36

    static func contentWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * spacing
    }

    static func contentHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * spacing
    }
}

// MARK: - 布局数据模型（文档 §5.4）

/// 紧凑槽位引用（长度 3 数组的元素，可为 null 或块引用）。
struct CompactSlotReference: Codable, Equatable, Identifiable {
    let pluginID: String
    let blockID: String
    let placementID: String

    var id: String { placementID }
}

/// 抽屉网格中一个已放置块的描述。
struct PlacedBlock: Codable, Equatable, Identifiable {
    let pluginID: String
    let blockID: String
    let placementID: String
    var originColumn: Int
    var originRow: Int
    var widthColumns: Int
    var heightRows: Int

    var id: String { placementID }
}

/// 布局持久化模型（layout.json，文档 §5.4）。
struct LayoutModel: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let compactSlotCount = 3

    var schemaVersion: Int
    var maxColumns: Int
    var compactSlots: [CompactSlotReference?]
    var drawerBlocks: [PlacedBlock]
    var enabledPluginIDs: [String]

    init(
        schemaVersion: Int = LayoutModel.currentSchemaVersion,
        maxColumns: Int = 4,
        compactSlots: [CompactSlotReference?] = [nil, nil, nil],
        drawerBlocks: [PlacedBlock] = [],
        enabledPluginIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.maxColumns = min(max(maxColumns, 2), 8)
        self.compactSlots = Self.normalizedCompactSlots(compactSlots)
        self.drawerBlocks = drawerBlocks
        self.enabledPluginIDs = enabledPluginIDs
    }

    /// 槽位数固定为 3（不足补齐，超出截断）。
    static func normalizedCompactSlots(_ slots: [CompactSlotReference?]) -> [CompactSlotReference?] {
        var result = slots
        while result.count < compactSlotCount {
            result.append(nil)
        }
        if result.count > compactSlotCount {
            result = Array(result.prefix(compactSlotCount))
        }
        return result
    }
}

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
            model = decoded
            didLoadFromDisk = true
        } else {
            model = LayoutModel()
            didLoadFromDisk = false
        }
        saveToDisk()
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
        saveToDisk()
        return true
    }

    /// 在支持的尺寸等级间切换块尺寸（编辑模式，文档 §5.5）。重叠或越界时回退。
    @discardableResult
    func resizeDrawerBlock(placementID: String, to size: BlockSize) -> Bool {
        resizeDrawerBlock(
            placementID: placementID,
            toColumns: size.gridSpan.columns,
            toRows: size.gridSpan.rows
        )
    }

    /// 缩放块到任意声明的跨度（编辑模式）：跨度必须在块的 supportedSpans 内，
    /// 重叠时回退。左上角原点保持不变（仅越界列数时向左收紧）。
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
        resized.originColumn = min(resized.originColumn, max(0, columns - resized.widthColumns))
        resized.originRow = max(resized.originRow, 0)

        guard !overlaps(resized, with: occupiedRects(excluding: placementID)) else {
            return false
        }
        model.drawerBlocks[index] = resized
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
        var placements = model.drawerBlocks
        guard let index = placements.firstIndex(where: { $0.placementID == placementID }) else {
            return [:]
        }

        let columns = effectiveMaxColumns()
        placements[index].originColumn = min(max(toColumn, 0), max(0, columns - placements[index].widthColumns))
        placements[index].originRow = max(toRow, 0)

        // 推挤：重复扫描，让所有重叠块依次下移一行，直到稳定（有界，防止异常输入死循环）。
        var remainingIterations = 64
        var hasOverlap = true
        while hasOverlap, remainingIterations > 0 {
            hasOverlap = false
            let order = placements.indices.sorted { lhs, rhs in
                let a = placements[lhs], b = placements[rhs]
                return a.originRow == b.originRow
                    ? a.originColumn < b.originColumn
                    : a.originRow < b.originRow
            }
            for i in order {
                let placement = placements[i]
                let key = rectKey(placement)
                let intersects = placements.enumerated().contains { j, other in
                    guard i != j else { return false }
                    let otherKey = rectKey(other)
                    return key.minColumn < otherKey.maxColumn && otherKey.minColumn < key.maxColumn
                        && key.minRow < otherKey.maxRow && otherKey.minRow < key.maxRow
                }
                if intersects {
                    placements[i].originRow += 1
                    hasOverlap = true
                }
            }
            remainingIterations -= 1
        }

        var result: [String: GridOrigin] = [:]
        for placement in placements {
            result[placement.placementID] = GridOrigin(column: placement.originColumn, row: placement.originRow)
        }
        return result
    }

    /// 提交拖拽预览结果（与 previewArrangement 同一算法，保证所见即所得）。
    @discardableResult
    func commitArrangement(_ origins: [String: GridOrigin]) -> Bool {
        guard !origins.isEmpty else { return false }
        let columns = effectiveMaxColumns()
        var changed = false

        for index in model.drawerBlocks.indices {
            let block = model.drawerBlocks[index]
            guard let target = origins[block.placementID] else { continue }
            let clampedColumn = min(max(target.column, 0), max(0, columns - block.widthColumns))
            let clampedRow = max(target.row, 0)
            if block.originColumn != clampedColumn || block.originRow != clampedRow {
                model.drawerBlocks[index].originColumn = clampedColumn
                model.drawerBlocks[index].originRow = clampedRow
                changed = true
            }
        }

        if changed {
            saveToDisk()
        }
        return changed
    }

    // MARK: - 几何

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
    func drawerWindowSize() -> CGSize {
        let content = drawerContentSize()
        return CGSize(
            width: content.width + NotchGridMetrics.contentPadding * 2,
            height: NotchGridMetrics.contentPadding
                + NotchGridMetrics.drawerTopBarHeight
                + content.height
                + NotchGridMetrics.contentPadding
        )
    }

    private func drawerContentRows() -> Int {
        let occupiedRows = model.drawerBlocks.map { $0.originRow + $0.heightRows }.max() ?? 0
        return max(occupiedRows, 1)
    }

    // MARK: - 校验（文档 §5.4：检测重叠；核心可据校验结果提示修复）

    func validate() -> [LayoutIssue] {
        var issues: [LayoutIssue] = []

        if model.schemaVersion != LayoutModel.currentSchemaVersion {
            issues.append(.schemaVersionMismatch(model.schemaVersion))
        }
        if model.compactSlots.count != LayoutModel.compactSlotCount {
            issues.append(.compactSlotCountMismatch)
        }

        for (index, block) in model.drawerBlocks.enumerated() {
            for other in model.drawerBlocks.dropFirst(index + 1) where rectsOverlap(block, other) {
                issues.append(.overlap(first: block.placementID, second: other.placementID))
            }
            let columns = effectiveMaxColumns()
            if block.originColumn < 0 || block.originRow < 0
                || block.originColumn + block.widthColumns > columns {
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

    private func rectsOverlap(_ a: PlacedBlock, _ b: PlacedBlock) -> Bool {
        overlaps(a, with: [rectKey(b)])
    }
}

private extension PlacedBlock {
    var maxRow: Int {
        originRow + heightRows
    }

    var maxColumn: Int {
        originColumn + widthColumns
    }
}