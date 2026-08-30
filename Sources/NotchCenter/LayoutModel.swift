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

    var schemaVersion: Int
    var maxColumns: Int
    /// 紧凑块引用数组：**长度即当前紧凑图标数**（宽度随其动态伸缩，文档 §5.2）。
    /// 元素始终非空（移除即删除元素、闭合空隙）；旧版固定 3 槽文件里的
    /// `null` 在加载时被 `normalizedCompactSlots` 剥除。
    var compactSlots: [CompactSlotReference?]
    var drawerBlocks: [PlacedBlock]
    var enabledPluginIDs: [String]

    init(
        schemaVersion: Int = LayoutModel.currentSchemaVersion,
        maxColumns: Int = 4,
        compactSlots: [CompactSlotReference?] = [],
        drawerBlocks: [PlacedBlock] = [],
        enabledPluginIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.maxColumns = min(max(maxColumns, 2), 8)
        self.compactSlots = Self.normalizedCompactSlots(compactSlots)
        self.drawerBlocks = drawerBlocks
        self.enabledPluginIDs = enabledPluginIDs
    }

    /// 紧凑槽位归一化：剥除旧版遗留的空槽 `null`（闭合空隙），长度即图标数，
    /// 不再补齐/截断到固定值。
    static func normalizedCompactSlots(_ slots: [CompactSlotReference?]) -> [CompactSlotReference?] {
        slots.filter { $0 != nil }
    }
}

extension PlacedBlock {
    var maxRow: Int {
        originRow + heightRows
    }
}
