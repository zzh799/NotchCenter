import Combine
import Foundation

// MARK: - 快捷动作 QuickAction（文档 §4.11 快捷动作与快捷按钮盒）

/// 快捷动作的类别。
public enum QuickActionKind: Sendable, Hashable {
    /// 开关类：当前状态可读（`isActive`），点击在开/关之间切换。
    case toggle
    /// 一次性触发类：无持续状态，点击执行一次。
    case action
}

/// 插件声明的一个可被「快捷按钮盒」收纳的一键动作。
///
/// 想被收进盒的插件把自己的动作建模为 `QuickAction`，并在插件实例上**缓存同一
/// 实例**（identity 必须稳定——宿主在启用/attach 时收集一次，之后靠实例身份做
/// 订阅与去重；每次 getter 新建对象会破坏观察与状态同步）。
///
/// - 宿主在插件启用时收集 `NotchCenterPlugin.quickActions`，禁用/卸载时整体注销
///   （文档 §4.11）。`execute` 与 `isActive` 只驻留注册表内存、**不持久化**。
/// - 盒内按钮经 `HostController.quickAction(id:)` 解析到实例后，用
///   `@ObservedObject` 观察 `isActive` 获得实时开关态；点击调 `execute()`。
/// - `requiresConfirmation = true` 的重动作（如服务启停）由点击方先征求确认。
/// - `sourceBlockID`：可选标注「该动作与本插件某块（`NotchBlock.id`）的点击
///   语义完全同义」——宿主组件目录据此把块卡与该动作合一成一张卡（拖到快速区
///   /抽屉摆块、拖到快捷按钮盒则装填此动作），避免同一入口在目录里出现两份。
///   只在动作点击 ≡ 块点击时标注，不要标「代表操作」这类近似语义（如 drawer
///   服务卡与其内部开关并不等价）。
@MainActor
public final class QuickAction: Identifiable, ObservableObject {
    /// 动作 ID（建议 `<plugin>.<action>` 形式，如 `"caffeinate.toggle"`）。
    public let id: String
    /// 用户可见名称。
    public let displayName: String
    /// SF Symbol 名称（未声明时为空，渲染方回退为通用图标）。
    public let systemImage: String
    /// 类别：开关 / 一次性。
    public let kind: QuickActionKind
    /// 是否为重动作：为 `true` 时点击方须先征求用户确认再执行。
    public let requiresConfirmation: Bool
    /// 开关类动作的当前状态（action 类忽略）。插件在自身状态变化处同步赋值。
    @Published public var isActive: Bool
    /// 执行动作（主线程；插件自行负责状态更新与副作用）。
    public let execute: @MainActor () -> Void
    /// 与本插件某块（`NotchBlock.id`）点击同义的来源块；`nil` 表示该动作
    /// 无块可合一（目录中作为独立「盒用动作」卡片展示）。
    public let sourceBlockID: String?
    /// 是否应进入**首启默认布局的快速区**（代替已被动作化的官方紧凑块，
    /// 保持「首次启动刘海带即有常用按钮」的默认体验）。仅宿主种子布局读取。
    public let defaultInStrip: Bool

    public init(
        id: String,
        displayName: String,
        systemImage: String,
        kind: QuickActionKind,
        requiresConfirmation: Bool = false,
        isActive: Bool = false,
        sourceBlockID: String? = nil,
        defaultInStrip: Bool = false,
        execute: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.displayName = displayName
        self.systemImage = systemImage
        self.kind = kind
        self.requiresConfirmation = requiresConfirmation
        self.isActive = isActive
        self.sourceBlockID = sourceBlockID
        self.defaultInStrip = defaultInStrip
        self.execute = execute
    }
}
