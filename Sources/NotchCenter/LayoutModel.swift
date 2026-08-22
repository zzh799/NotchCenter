import CoreGraphics
import Foundation

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

extension PlacedBlock {
    var maxRow: Int {
        originRow + heightRows
    }
}
