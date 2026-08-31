import Combine
import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 布局引擎

/// 布局引擎：紧凑槽位 + 抽屉网格的放置、移动、缩放、重叠检测与原子持久化
/// （文档 §5 / §7）。
/// 本文件只保留类声明、存储属性、加载、查询与持久化；其余职责按只读/协作
/// extension 拆分：加载净化（LayoutEngineSanitization）、布局修改 API
/// （LayoutEngineMutation）、推挤与预览算法（LayoutEngineArrangement）、
/// 空洞压实（LayoutEngineCompaction）、几何与校验（Geometry / Validation）。
@MainActor
final class LayoutEngine: ObservableObject {
    enum LayoutIssue: Equatable {
        case schemaVersionMismatch(Int)
        case overlap(first: String, second: String)
        case outOfBounds(placementID: String)
        case unknownBlock(pluginID: String, blockID: String)
        case compactBlockKindMismatch(placementID: String)
        case drawerBlockKindMismatch(placementID: String)
        case sizeNotSupported(placementID: String)
    }

    /// 布局模型真源。setter 为模块内可见（原为 `private(set)`，拆分到独立
    /// 文件的修改路径需要写入）；模块外写入仍走 `modelForTesting`（含落盘）。
    @Published var model: LayoutModel

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
    /// （模块内私有：拆分后供修改路径的容量计算读取。）
    var availableScreenWidth: CGFloat = 1440

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
            var loaded = Self.sanitized(decoded)
            // 旧版固定 3 槽文件可能含 null 占位（解码不经自定义 init，
            // 归一化只在这里兜底）：剥除空槽、闭合空隙——数组长度即
            // 图标数，宽度随其伸缩。
            loaded.compactSlots = LayoutModel.normalizedCompactSlots(loaded.compactSlots)
            // 页面集合兜底：收编块引用的散页（手改 JSON）。
            loaded.drawerPages = LayoutModel.normalizedPages(
                loaded.drawerPages,
                blockPages: loaded.drawerBlocks.map(\.page)
            )
            model = loaded
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

    func drawerBlocks(onPage page: Int) -> [PlacedBlock] {
        model.drawerBlocks.filter { $0.page == page }
    }

    /// 抽屉页面显示序列（顺序即顶栏胶囊次序，见 `LayoutModel.drawerPages`）。
    var drawerPages: [Int] {
        model.drawerPages
    }

    var drawerPageTitles: [String: String] {
        model.drawerPageTitles
    }

    func page(ofPlacementID placementID: String) -> Int? {
        model.drawerBlocks.first { $0.placementID == placementID }?.page
    }

    /// 页内隔离的统一取法：`page` 页内、排除 `placementID` 的其余块。
    func siblings(onPage page: Int, excluding placementID: String?) -> [PlacedBlock] {
        model.drawerBlocks.filter { $0.page == page && $0.placementID != placementID }
    }

    func siblings(of block: PlacedBlock) -> [PlacedBlock] {
        siblings(onPage: block.page, excluding: block.placementID)
    }

    var userMaxColumns: Int {
        model.maxColumns
    }

    var userMinRows: Int {
        model.minRows
    }

    var userMinColumns: Int {
        model.minColumns
    }

    func compactSlot(at index: Int) -> CompactSlotReference? {
        guard model.compactSlots.indices.contains(index) else { return nil }
        return model.compactSlots[index]
    }

    func drawerBlock(placementID: String) -> PlacedBlock? {
        model.drawerBlocks.first { $0.placementID == placementID }
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

    // MARK: - 重叠几何辅助（模块内私有：拆分后供净化与各修改路径共用，勿对外使用）

    struct RectKey: Equatable {
        let minColumn: Int
        let minRow: Int
        let maxColumn: Int
        let maxRow: Int
    }

    func occupiedRects(page: Int, excluding placementID: String?) -> [RectKey] {
        siblings(onPage: page, excluding: placementID).map(rectKey)
    }

    func rectKey(_ block: PlacedBlock) -> RectKey {
        RectKey(
            minColumn: block.originColumn,
            minRow: block.originRow,
            maxColumn: block.originColumn + block.widthColumns,
            maxRow: block.originRow + block.heightRows
        )
    }

    func overlaps(_ block: PlacedBlock, with others: [RectKey]) -> Bool {
        let key = rectKey(block)
        return others.contains { other in
            key.minColumn < other.maxColumn && other.minColumn < key.maxColumn
                && key.minRow < other.maxRow && other.minRow < key.maxRow
        }
    }

    /// 两块是否重叠（模块内私有：加载净化、推挤与校验共用）。
    static func rectsOverlap(_ a: PlacedBlock, _ b: PlacedBlock) -> Bool {
        a.originColumn < b.originColumn + b.widthColumns
            && b.originColumn < a.originColumn + a.widthColumns
            && a.originRow < b.originRow + b.heightRows
            && b.originRow < a.originRow + a.heightRows
    }
}
