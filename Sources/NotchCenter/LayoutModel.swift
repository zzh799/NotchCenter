import CoreGraphics
import Foundation

// MARK: - 网格指标（文档 §5.3）

/// 抽屉网格指标访问点：**转发** `GridMetricsStore.shared`（设置 → 布局可调，
/// 默认单元格 150×120、间距 12、内容内边距 16）。
///
/// 静态访问点保持不变，是为了让既有的几何计算 / 视图代码继续同步读取，
/// 无需改成实例注入：指标变化由控制器监听 `GridMetricsStore.didChangeNotification`
/// 后重建内容（`rebuildContent`）驱动视图重算，而不是靠 SwiftUI 观察。
/// 注意：这些值会变，不要把它们的快照缓存进跨刷新存活的结构里。
enum NotchGridMetrics {
    static var cellWidth: CGFloat { GridMetricsStore.shared.cellWidth }
    static var cellHeight: CGFloat { GridMetricsStore.shared.cellHeight }
    static var spacing: CGFloat { GridMetricsStore.shared.spacing }
    static var contentPadding: CGFloat { GridMetricsStore.shared.contentPadding }

    /// 出厂默认值（"恢复默认"按钮与对照显示用）。
    static let defaultCellWidth = GridMetricsStore.defaultCellWidth
    static let defaultCellHeight = GridMetricsStore.defaultCellHeight
    static let defaultSpacing = GridMetricsStore.defaultSpacing
    static let defaultContentPadding = GridMetricsStore.defaultContentPadding

    /// 抽屉窗口顶部栏（钉住 / 编辑等按钮）高度。
    static let drawerTopBarHeight: CGFloat = 36

    /// 内容宽度公式转发 `GridMetrics`，保证全项目只有一份定义。
    static func contentWidth(columns: Int) -> CGFloat {
        GridMetrics.current.width(columns: columns)
    }

    static func contentHeight(rows: Int) -> CGFloat {
        GridMetrics.current.height(rows: rows)
    }
}

// MARK: - 布局数据模型（文档 §5.4）

/// 紧凑块引用（`compactSlots` 数组元素：长度即当前图标数，宽度随其动态伸缩）。
struct CompactSlotReference: Codable, Equatable, Identifiable {
    let pluginID: String
    let blockID: String
    let placementID: String

    var id: String { placementID }
}

/// 抽屉页面的"侧"（左 / 右）：加号新增、滑动切页与删页回落共用同一份左右语义。
enum DrawerPageSide {
    case left
    case right
}

/// 抽屉网格中一个已放置块的描述。
struct PlacedBlock: Codable, Equatable, Identifiable {
    let pluginID: String
    let blockID: String
    let placementID: String
    /// 所在抽屉页面（隔离规则见 `LayoutModel.drawerPages`）。
    var page: Int
    var originColumn: Int
    var originRow: Int
    var widthColumns: Int
    var heightRows: Int

    var id: String { placementID }

    init(
        pluginID: String,
        blockID: String,
        placementID: String,
        page: Int = 0,
        originColumn: Int,
        originRow: Int,
        widthColumns: Int,
        heightRows: Int
    ) {
        self.pluginID = pluginID
        self.blockID = blockID
        self.placementID = placementID
        self.page = page
        self.originColumn = originColumn
        self.originRow = originRow
        self.widthColumns = widthColumns
        self.heightRows = heightRows
    }

    // 旧版 layout.json 无 page 键 → 主页 0。
    private enum CodingKeys: String, CodingKey {
        case pluginID, blockID, placementID, page, originColumn, originRow, widthColumns, heightRows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try container.decode(String.self, forKey: .pluginID)
        blockID = try container.decode(String.self, forKey: .blockID)
        placementID = try container.decode(String.self, forKey: .placementID)
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 0
        originColumn = try container.decode(Int.self, forKey: .originColumn)
        originRow = try container.decode(Int.self, forKey: .originRow)
        widthColumns = try container.decode(Int.self, forKey: .widthColumns)
        heightRows = try container.decode(Int.self, forKey: .heightRows)
    }
}

/// 布局持久化模型（layout.json，文档 §5.4）。
struct LayoutModel: Codable, Equatable {
    static let currentSchemaVersion = 1

    /// 抽屉页面上限（防窄屏下分页胶囊无限增长）。
    static let maxDrawerPageCount = 9

    /// 主页索引：永远存在、不可删除（页面显示序列里可以排到任意位置）。
    static let homePage = 0

    static let maxColumnsRange = 2...8
    static let minRowsRange = 1...9
    /// 最小列数可选项范围。存储值**不随最大列数回改**——生效下限由
    /// `LayoutEngine.minimumColumnCount()` 夹容量，所以调小再调回最大列数不会抹掉设置。
    static let minColumnsRange = 3...8
    /// 默认值同时是旧 layout.json 缺这两个键时的回落值：行数保持现状，
    /// 列数至少 3（抽屉不再塌成一列窄条）。
    static let defaultMinRows = 1
    static let defaultMinColumns = 3

    /// 配置写入前的统一夹紧。
    static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    var schemaVersion: Int
    var maxColumns: Int
    var minRows: Int
    var minColumns: Int
    /// 紧凑块引用数组：**长度即当前紧凑图标数**（宽度随其动态伸缩，文档 §5.2）。
    /// 元素始终非空（移除即删除元素、闭合空隙）；旧版固定 3 槽文件里的
    /// `null` 在加载时被 `normalizedCompactSlots` 剥除。
    var compactSlots: [CompactSlotReference?]
    var drawerBlocks: [PlacedBlock]
    var enabledPluginIDs: [String]
    /// 抽屉页面**显示序列**：数组顺序即顶栏胶囊从左到右的次序。索引是块的**身份**
    /// 而非位置——排序只改这里的次序，块上的 `page` 永不重编号；所有网格算法
    /// （重叠/推挤/压实/几何/净化/校验）只作用于同页块。空页面也必须持久化，否则胶囊会丢页。
    var drawerPages: [Int]
    /// 页面自定义标题：键 = 页面索引的十进制字符串（用 `[Int: String]` 会被合成的
    /// `encode(to:)` 写成键值交替数组，与自定义解码不对称）。
    /// 缺失或空串 = 回落到显示序列里的 1-based 序号（见 `pageDisplayName`）。
    var drawerPageTitles: [String: String]
    /// 页面自定义图标（SF Symbol 名）：键与空值语义同 `drawerPageTitles`。
    /// 缺失 = 主页回落 `house.fill`、其余页无图标（见 `pageIcon`）。
    var drawerPageIcons: [String: String]

    init(
        schemaVersion: Int = LayoutModel.currentSchemaVersion,
        maxColumns: Int = 4,
        minRows: Int = LayoutModel.defaultMinRows,
        minColumns: Int = LayoutModel.defaultMinColumns,
        compactSlots: [CompactSlotReference?] = [],
        drawerBlocks: [PlacedBlock] = [],
        enabledPluginIDs: [String] = [],
        drawerPages: [Int] = [0],
        drawerPageTitles: [String: String] = [:],
        drawerPageIcons: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.maxColumns = Self.clamped(maxColumns, to: Self.maxColumnsRange)
        self.minRows = Self.clamped(minRows, to: Self.minRowsRange)
        self.minColumns = Self.clamped(minColumns, to: Self.minColumnsRange)
        self.compactSlots = Self.normalizedCompactSlots(compactSlots)
        self.drawerBlocks = drawerBlocks
        self.enabledPluginIDs = enabledPluginIDs
        self.drawerPages = Self.normalizedPages(drawerPages)
        self.drawerPageTitles = drawerPageTitles
        self.drawerPageIcons = drawerPageIcons
    }

    // 旧版 layout.json 无 drawerPages / minRows / minColumns 键 → 只有主页、下限取默认值。
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, maxColumns, minRows, minColumns, compactSlots, drawerBlocks
        case enabledPluginIDs, drawerPages, drawerPageTitles, drawerPageIcons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // 自定义解码不经过上面的 init，夹紧必须在每个字段各自补一遍。
        maxColumns = Self.clamped(
            try container.decode(Int.self, forKey: .maxColumns),
            to: Self.maxColumnsRange
        )
        minRows = Self.clamped(
            try container.decodeIfPresent(Int.self, forKey: .minRows) ?? Self.defaultMinRows,
            to: Self.minRowsRange
        )
        minColumns = Self.clamped(
            try container.decodeIfPresent(Int.self, forKey: .minColumns) ?? Self.defaultMinColumns,
            to: Self.minColumnsRange
        )
        compactSlots = try container.decode([CompactSlotReference?].self, forKey: .compactSlots)
        drawerBlocks = try container.decode([PlacedBlock].self, forKey: .drawerBlocks)
        enabledPluginIDs = try container.decode([String].self, forKey: .enabledPluginIDs)
        drawerPages = Self.normalizedPages(
            try container.decodeIfPresent([Int].self, forKey: .drawerPages) ?? [0]
        )
        drawerPageTitles = try container.decodeIfPresent(
            [String: String].self, forKey: .drawerPageTitles
        ) ?? [:]
        drawerPageIcons = try container.decodeIfPresent(
            [String: String].self, forKey: .drawerPageIcons
        ) ?? [:]
    }

    /// 紧凑槽位归一化：剥除旧版遗留的空槽 `null`（闭合空隙），长度即图标数，
    /// 不再补齐/截断到固定值。
    static func normalizedCompactSlots(_ slots: [CompactSlotReference?]) -> [CompactSlotReference?] {
        slots.filter { $0 != nil }
    }

    /// 页面归一化：**保序**去重、补齐主页 0（缺失时置于首位），块引用的散页（手改
    /// JSON）按出现顺序追加到末尾。这里绝不排序——数组顺序就是用户的拖动排序结果。
    static func normalizedPages(_ pages: [Int], blockPages: [Int] = []) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for page in pages + blockPages where !seen.contains(page) {
            seen.insert(page)
            result.append(page)
        }
        if !seen.contains(homePage) {
            result.insert(homePage, at: 0)
        }
        return result
    }

    /// 激活页在指定侧的相邻页：按**显示序列的位置**取（拖动排序后索引大小不再
    /// 携带左右信息）。已在最左/最右页时返回 nil——滑动不会自动建页。
    static func neighborPage(
        in pages: [Int],
        active: Int,
        side: DrawerPageSide
    ) -> Int? {
        guard let position = pages.firstIndex(of: active) else { return nil }
        let target = side == .right ? position + 1 : position - 1
        guard pages.indices.contains(target) else { return nil }
        return pages[target]
    }

    /// 页面显示名：自定义标题优先，否则回落到显示序列里的 1-based 序号。
    /// 胶囊与"删除页面"确认框共用这一份解析。
    static func pageDisplayName(
        in pages: [Int],
        page: Int,
        titles: [String: String]
    ) -> String {
        if let title = titles[String(page)], !title.isEmpty {
            return title
        }
        return LF("panel.page.untitled", (pages.firstIndex(of: page) ?? -1) + 1)
    }

    /// 页面图标（SF Symbol 名）：自定义图标优先；否则主页回落房子、其余页无图标
    ///（胶囊退化为纯文本）。胶囊与设置浮窗共用这一份解析。
    static func pageIcon(
        page: Int,
        icons: [String: String]
    ) -> String? {
        if let icon = icons[String(page)], !icon.isEmpty {
            return icon
        }
        return page == homePage ? "house.fill" : nil
    }
}

extension PlacedBlock {
    var maxRow: Int {
        originRow + heightRows
    }
}
