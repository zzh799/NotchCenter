import Combine
import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 布局引擎

/// 添加抽屉块的结果。`.noPageCapacity` 与 `.unavailable` 分开，是因为前者需要
/// 向用户解释"抽屉页已满"（可行动），后者只是块声明有问题（内部错误）。
enum DrawerAddOutcome: Equatable {
    case placed(placementID: String, page: Int)
    /// 页数已达上限且没有空页——调用方提示用户，宿主不自动清理任何页。
    case noPageCapacity
    /// 块查不到、不是抽屉块，或声明非法。
    case unavailable
}

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

    /// 放置项是否仍指向"真实存在"的组件（三态判据见
    /// `NotchPanelController.placementAvailability`）。引擎没有插件发现清单与快捷
    /// 动作注册表，故由宿主注入；`nil` = 退回"块解析器能查到即有效"（测试与未接
    /// 宿主的路径）。**插件只是被停用（已发现但未加载）时必须为 true**——停用可逆，
    /// 删掉用户的摆放不可逆；而 `blockResolver` 在插件停用时恰好返回 nil（实例已释放），
    /// 所以两者不能互相替代。见 Agent Note 2026-09-11-invalid-component-visibility。
    ///
    /// 注意别把这条判据与"停用会连带移除摆放"混为一谈：后者是插件管理里用户
    /// **确认过的显式动作**（走 `removePlacements(forPluginID:)`），不是本判据
    /// 推出的结论；从文件/外部改回来的"停用但仍被摆放"依旧算有效、不自动清理。
    /// 见 Agent Note 2026-09-25-plugin-in-use-placement-criterion。
    let placementLiveness: (@MainActor (String, String) -> Bool)?

    private let fileURL: URL
    private let fileManager: FileManager

    /// 当前可用屏幕宽度（由面板控制器随屏幕变化更新，文档 §7.2）。
    /// （模块内私有：拆分后供修改路径的容量计算读取。）
    ///
    /// `@Published`：列/行容量既进滑条轨道端点（设置页），也随展开换屏变化；
    /// 不发通知的话设置页拿到的是换屏前的档位。
    @Published var availableScreenWidth: CGFloat = 1440

    /// 当前屏幕可用的**抽屉高度**（屏高 − 顶部留白 − 紧凑带高，见控制器
    /// `maxDrawerHeight(for:)`）。`nil` = 未约束——测试与尚未接入屏幕的路径
    /// 保持原行为（行侧不设容量上限），与 `DrawerLayoutMetricsResolver` 的
    /// `maxHeight: CGFloat?` 同款约定。
    ///
    /// 有意**不**接收含设置面板让位的 `drawerMaxVisibleHeight`：那个值随设置
    /// 面板开合瞬变，会让行列档位在面板打开时突然缩水。
    @Published var availableScreenHeight: CGFloat?

    init(
        fileURL: URL = CorePaths.layoutFileURL,
        blockResolver: @escaping @MainActor (String, String) -> NotchBlock?,
        placementLiveness: (@MainActor (String, String) -> Bool)? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.blockResolver = blockResolver
        self.placementLiveness = placementLiveness
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

    /// 布局里"正在使用中"的插件：至少有一条**可用**的摆放（抽屉块或刘海快捷
    /// 按钮）。插件管理列表据此标「使用中」。
    ///
    /// "可用"复用 `isLivePlacement`——与 `invalidPlacementCount()` /
    /// `purgeInvalidPlacements()` **同源**：失效摆放渲染成「组件已失效」占位，
    /// 把它算作"使用中"是自相矛盾。判据与呈现的来龙去脉见 Agent Note
    /// 2026-09-25-plugin-in-use-placement-criterion。
    var inUsePluginIDs: Set<String> {
        let drawer = model.drawerBlocks
            .filter { isLivePlacement(pluginID: $0.pluginID, blockID: $0.blockID) }
            .map(\.pluginID)
        let compact = model.compactSlots
            .compactMap { $0 }
            .filter { isLivePlacement(pluginID: $0.pluginID, blockID: $0.blockID) }
            .map(\.pluginID)
        return Set(drawer + compact)
    }

    var compactSlots: [CompactSlotReference?] {
        model.compactSlots
    }

    /// 某插件在布局里的全部摆放。`blockID` 供调用方解析显示名与回调插件，
    /// `placementID` 供补 `NotchCenterPluginServices.placementWasRemoved`
    /// （引擎只负责删，通知插件清实例数据是调用方的义务——与
    /// `removeDrawerPage` 同款约定）。抽屉块在前、紧凑槽在后。
    func placements(ofPluginID pluginID: String) -> [(blockID: String, placementID: String)] {
        let drawer = model.drawerBlocks
            .filter { $0.pluginID == pluginID }
            .map { (blockID: $0.blockID, placementID: $0.placementID) }
        let compact = model.compactSlots
            .compactMap { $0 }
            .filter { $0.pluginID == pluginID }
            .map { (blockID: $0.blockID, placementID: $0.placementID) }
        return drawer + compact
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

    var drawerPageIcons: [String: String] {
        model.drawerPageIcons
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

    /// 编码器与上次写盘内容缓存：JSONEncoder 每次构造有固定开销，且部分
    /// 修改路径在值未变时也会走到保存——内容与上次写盘逐字节一致时直接跳过
    /// （磁盘上已是同一份内容，跳写不改变任何可见语义）。
    private let encoder = JSONEncoder()
    private var lastWrittenData: Data?

    func saveToDisk() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(model)
            guard data != lastWrittenData else { return }
            try data.write(to: fileURL, options: .atomic)
            lastWrittenData = data
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
