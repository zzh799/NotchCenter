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
    /// 抽屉块当前占用跨度（列×行）；紧凑块为 nil。宿主始终按真实跨度下发
    /// （存量超盒布局照传实际跨度，不做钳制）；组件目录等无落位上下文处为 nil，
    /// 插件应回退自己的推荐形态。
    public let size: GridSpan?
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
    /// 本实例是否只是**只读预览副本**（宿主为滑动切页等过渡临时渲染的非激活页视图）。
    ///
    /// 契约：为真时插件**不得**认领任何跨实例共享的交互状态或生命周期副作用——
    /// 不绑定 textView / 不抢第一响应者 / 不写共享注册表 / 不发"我消失了"的清理
    /// 通知。预览副本随时会整层消失，而它引用的对象可能正被屏上另一个实例使用。
    /// 只读展示与纯本地 `@State` 不受此约束。
    public let isPreview: Bool

    public init(
        region: BlockRegion,
        placementID: String,
        frame: CGRect,
        size: GridSpan? = nil,
        originColumn: Int? = nil,
        originRow: Int? = nil,
        widthColumns: Int? = nil,
        heightRows: Int? = nil,
        isEditing: Bool = false,
        compactSlotIndex: Int? = nil,
        isPreview: Bool = false
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
        self.isPreview = isPreview
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

    /// 该放置实例的私有存储（`<pluginData>/placements/<placementID>/`）：
    /// 每块单独设置/状态持久化在这里，与插件级共享 `stateStore` 互不干扰。
    /// placementID 非法（损坏布局数据）时为 nil，视图应回退只读默认值。
    public var placementStore: StateStore? {
        stateStore.placementScope(placementID: placementID)
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