import SwiftUI

// MARK: - 块种类与尺寸（文档 §4.2）

/// 块所属区域：紧凑区（刘海下方 3 槽）或抽屉区（展开网格）。
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
    /// 默认尺寸等级（仅抽屉块有效）。
    public let defaultSize: BlockSize?
    /// 紧凑块点击行为（仅紧凑块有意义）。默认 `.expandDrawer`。
    public let interaction: BlockInteraction
    /// 视图工厂：携带 `BlockContext` 构建块视图。
    public let makeView: @MainActor (BlockContext) -> AnyView

    public init(
        id: String,
        displayName: String,
        kind: BlockKind,
        supportedSizes: Set<BlockSize> = [],
        defaultSize: BlockSize? = nil,
        interaction: BlockInteraction = .expandDrawer,
        makeView: @escaping @MainActor (BlockContext) -> AnyView
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.supportedSizes = supportedSizes
        self.defaultSize = defaultSize
        self.interaction = interaction
        self.makeView = makeView
    }

    /// 校验块声明是否满足架构文档 §4.2 的规则。
    /// - 紧凑块固定 44×44，无需声明尺寸；抽屉块必须声明 supportedSizes 且包含 defaultSize。
    public var validationError: String? {
        switch kind {
        case .compact:
            if !supportedSizes.isEmpty {
                return "compact block \(id) must not declare supportedSizes"
            }
            if defaultSize != nil {
                return "compact block \(id) must not declare defaultSize"
            }
            return nil
        case .drawer:
            if supportedSizes.isEmpty {
                return "drawer block \(id) must declare supportedSizes"
            }
            if let defaultSize, !supportedSizes.contains(defaultSize) {
                return "drawer block \(id) defaultSize must be included in supportedSizes"
            }
            return nil
        }
    }
}