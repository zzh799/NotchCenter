import SwiftUI

// MARK: - 块种类与尺寸（文档 §4.2）

/// 块所属区域：紧凑区（刘海两侧，槽位数随图标动态伸缩）或抽屉区（展开网格）。
public enum BlockKind: Sendable, Hashable {
    case compact
    case drawer
}

/// 抽屉块尺寸等级（文档 §5.3：单元格固定 150×120，间距 12）。
/// `small` 1×1、`medium` 2×1、`wide` 4×1、`large` 2×2、`extraLarge` 4×2。
public enum BlockSize: String, Codable, Sendable, CaseIterable, Comparable {
    case small
    case medium
    case wide
    case large
    case extraLarge

    public var gridSpan: (columns: Int, rows: Int) {
        switch self {
        case .small: return (1, 1)
        case .medium: return (2, 1)
        case .wide: return (4, 1)
        case .large: return (2, 2)
        case .extraLarge: return (4, 2)
        }
    }

    public static func < (lhs: BlockSize, rhs: BlockSize) -> Bool {
        guard let lhsIndex = BlockSize.allCases.firstIndex(of: lhs),
              let rhsIndex = BlockSize.allCases.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}

/// 紧凑块点击行为（文档 §4.2 / §6.2）：默认点击展开抽屉，`.custom` 由插件自行处理。
public enum BlockInteraction: Sendable, Hashable {
    case expandDrawer
    case custom
}

/// 任意网格跨度（列数 × 行数）：BlockSize 枚举档位之外的自由尺寸声明。
public struct GridSpan: Hashable, Codable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// 块对横向滑动（抽屉切页手势）的消费声明（文档 §5.3）。
///
/// 抽屉的水平轻扫切页与块内容的手势优先级：`.none` 静态卡片不消费横向
/// 增量、其上滑动照常切页（"在不使用滑动的组件上滑动时触发页面滑动"）；
/// `.always` 无条件让路；`.horizontal` 由宿主用 NSView 子树探针核实后让路
/// （见宿主 `DrawerScrollProbe`）——SwiftUI 的视图树对宿主不可内省（ScrollView
/// 不落在 AppKit 命中链上，实测拿不到 `NSScrollView`），但其内部滚动机构是
/// 真实 NSView，可从窗口 `contentView` 向下子树枚举到：块声明 `.horizontal`
/// 后，宿主核实"光标下确有横向溢出的滚动视图"才让路——空/未满的横向
/// `ScrollView`（如文件架）放行切页，塞满溢出时让路。块以非 ScrollView 机制
/// 消费横向输入（自定义拖拽手势等，探针看不见）时声明 `.always`。
/// 未声明的第三方块按 `.horizontal`（探针核实后让路）处理。
public enum BlockScrollUsage: Sendable, Hashable {
    /// 块不消费横向滚动/轻扫：指针落在块上时，抽屉的水平轻扫照常切页
    /// （块自身的纵向滚动不受影响）。
    case none
    /// 块内含横向可滚动区域（ScrollView 机制）：切页让路，横向增量归块自己；
    /// 宿主探针核实内容当前确实横向溢出才让路，空/未满时放行切页。
    case horizontal
    /// 无条件让路：块消费横向输入但宿主探针看不见（自定义拖拽手势等非
    /// ScrollView 机制），指针落在块上时切页永远让位。
    case always
}

/// 插件提供的最小 UI 单元（文档 §4.2）。
@MainActor
public struct NotchBlock: Identifiable {
    /// 插件内唯一块类型 ID（如 `"notes.notebook"`）。
    public let id: String
    /// 用户可见名称。
    public let displayName: String
    /// 块种类：紧凑块或抽屉块。
    public let kind: BlockKind
    /// 支持的可选尺寸等级（仅抽屉块有效，且必须包含 `defaultSize`）。
    public let supportedSizes: Set<BlockSize>
    /// 支持的完整跨度集合：`supportedSizes` 的派生跨度 + `supportedGridSpans`
    /// 额外声明的自由跨度（如 1×3、3×3）。核心的缩放/校验以此为准。
    public let supportedSpans: Set<GridSpan>
    /// 默认尺寸等级（仅抽屉块有效）。
    public let defaultSize: BlockSize?
    /// 紧凑块点击行为（仅紧凑块有意义）。默认 `.expandDrawer`。
    public let interaction: BlockInteraction
    /// 目录条目图标（SF Symbol 名称，可选）。宿主在“添加块”目录里渲染
    /// “图标 + 块名”；未声明时回退纯文本条目（向后兼容第三方插件）。
    public let symbolName: String?
    /// 块对横向滑动（抽屉切页）的消费声明。默认 `.horizontal`（探针核实横向
    /// 溢出后让路），静态卡片块请显式声明 `.none`；自定义横向手势块（非
    /// ScrollView 机制）声明 `.always`。
    public let scrollUsage: BlockScrollUsage
    /// 视图工厂：携带 `BlockContext` 构建块视图。
    public let makeView: @MainActor (BlockContext) -> AnyView
    /// 放置实例级设置界面（可选）。编辑模式块齿轮触发时，宿主优先用它并以
    /// 完整 `BlockContext` 调用（含 placementID / placementStore / 插件级
    /// settingsContext）——同一块类型的多个放置实例可各自单独设置；nil 时
    /// 回退插件级 `NotchCenterPlugin.settingsView`（所有实例共享一份内容）。
    public let instanceSettingsView: (@MainActor (BlockContext) -> AnyView)?

    public init(
        id: String,
        displayName: String,
        kind: BlockKind,
        supportedSizes: Set<BlockSize> = [],
        defaultSize: BlockSize? = nil,
        interaction: BlockInteraction = .expandDrawer,
        symbolName: String? = nil,
        scrollUsage: BlockScrollUsage = .horizontal,
        makeView: @escaping @MainActor (BlockContext) -> AnyView
    ) {
        self.init(
            id: id,
            displayName: displayName,
            kind: kind,
            supportedSizes: supportedSizes,
            defaultSize: defaultSize,
            supportedGridSpans: [],
            interaction: interaction,
            symbolName: symbolName,
            scrollUsage: scrollUsage,
            instanceSettingsView: nil,
            makeView: makeView
        )
    }

    public init(
        id: String,
        displayName: String,
        kind: BlockKind,
        supportedSizes: Set<BlockSize>,
        defaultSize: BlockSize?,
        supportedGridSpans: Set<GridSpan>,
        interaction: BlockInteraction = .expandDrawer,
        symbolName: String? = nil,
        scrollUsage: BlockScrollUsage = .horizontal,
        instanceSettingsView: (@MainActor (BlockContext) -> AnyView)? = nil,
        makeView: @escaping @MainActor (BlockContext) -> AnyView
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.supportedSizes = supportedSizes
        var spans = Set(supportedSizes.map { size in
            GridSpan(columns: size.gridSpan.columns, rows: size.gridSpan.rows)
        })
        spans.formUnion(supportedGridSpans)
        self.supportedSpans = spans
        self.defaultSize = defaultSize
        self.interaction = interaction
        self.symbolName = symbolName
        self.scrollUsage = scrollUsage
        self.instanceSettingsView = instanceSettingsView
        self.makeView = makeView
    }

    /// 校验块声明是否满足架构文档 §4.2 的规则。
    /// - 紧凑块固定 44×44，无需声明尺寸；抽屉块必须声明支持的跨度（supportedSizes
    ///   或 supportedGridSpans 至少其一）且包含 defaultSize。
    public var validationError: String? {
        switch kind {
        case .compact:
            if !supportedSizes.isEmpty || !supportedSpans.isEmpty {
                return "compact block \(id) must not declare supportedSizes"
            }
            if defaultSize != nil {
                return "compact block \(id) must not declare defaultSize"
            }
            return nil
        case .drawer:
            if supportedSpans.isEmpty {
                return "drawer block \(id) must declare supportedSizes"
            }
            if let defaultSize,
               !supportedSpans.contains(GridSpan(columns: defaultSize.gridSpan.columns, rows: defaultSize.gridSpan.rows)) {
                return "drawer block \(id) defaultSize must be included in supportedSizes"
            }
            return nil
        }
    }
}