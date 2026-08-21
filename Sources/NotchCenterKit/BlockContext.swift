import CoreGraphics

// MARK: - 块上下文（文档 §4.5）

/// 块所在区域。
public enum BlockRegion: Sendable, Hashable {
    case compact
    case drawer
}

/// `BlockContext.layoutInfo`：当前块在布局中的只读信息。
@MainActor
public struct BlockLayoutInfo {
    /// 所在区域（紧凑 / 抽屉）。
    public let region: BlockRegion
    /// 放置实例唯一标识（文档 §4.3）。
    public let placementID: String
    /// 块的当前 frame（面板本地坐标；紧凑区为槽位矩形，抽屉区为网格矩形）。
    public let frame: CGRect
    /// 抽屉块当前尺寸等级；紧凑块为 nil。
    public let size: BlockSize?
    /// 抽屉网格位置（格子单元坐标）；紧凑块为 nil。
    public let originColumn: Int?
    /// 抽屉网格位置（格子单元坐标）；紧凑块为 nil。
    public let originRow: Int?
    /// 占用格宽（√格子数）；紧凑块为 nil。
    public let widthColumns: Int?
    /// 占用格高（格子数）；紧凑块为 nil。
    public let heightRows: Int?
    /// 是否处于布局编辑模式。
    public let isEditing: Bool
    /// 紧凑槽位下标（0/1/2）；非紧凑块为 nil。
    public let compactSlotIndex: Int?

    public init(
        region: BlockRegion,
        placementID: String,
        frame: CGRect,
        size: BlockSize? = nil,
        originColumn: Int? = nil,
        originRow: Int? = nil,
        widthColumns: Int? = nil,
        heightRows: Int? = nil,
        isEditing: Bool = false,
        compactSlotIndex: Int? = nil
    ) {
        self.region = region
        self.placementID = placementID
        self.frame = frame
        self.size = size
        self.originColumn = originColumn
        self.originRow = originRow
        self.widthColumns = widthColumns
        self.heightRows = heightRows
        self.isEditing = isEditing
        self.compactSlotIndex = compactSlotIndex
    }
}

/// 块视图创建时获得的上下文（文档 §4.5）：身份、作用域状态存储、宿主服务与布局信息。
@MainActor
public struct BlockContext {
    public let pluginID: String
    public let blockID: String
    public let placementID: String
    public let stateStore: StateStore
    public let hostController: any HostController
    public let layoutInfo: BlockLayoutInfo

    public init(
        pluginID: String,
        blockID: String,
        placementID: String,
        stateStore: StateStore,
        hostController: any HostController,
        layoutInfo: BlockLayoutInfo
    ) {
        self.pluginID = pluginID
        self.blockID = blockID
        self.placementID = placementID
        self.stateStore = stateStore
        self.hostController = hostController
        self.layoutInfo = layoutInfo
    }

    /// 插件设置界面上下文（文档 §4.7）。
    public var settingsContext: PluginSettingsContext {
        PluginSettingsContext(
            pluginID: pluginID,
            stateStore: stateStore,
            hostController: hostController
        )
    }
}

// MARK: - 插件设置上下文（文档 §4.7）

@MainActor
public struct PluginSettingsContext {
    public let pluginID: String
    public let stateStore: StateStore
    public let hostController: any HostController

    public init(
        pluginID: String,
        stateStore: StateStore,
        hostController: any HostController
    ) {
        self.pluginID = pluginID
        self.stateStore = stateStore
        self.hostController = hostController
    }
}