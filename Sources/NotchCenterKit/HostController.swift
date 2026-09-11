import Foundation

// MARK: - 宿主服务（文档 §4.5）

/// 供插件调用的宿主能力。由核心（`NotchPanelController`）实现。
@MainActor
public protocol HostController: AnyObject {
    /// 展开抽屉。
    func expandDrawer()
    /// 收起抽屉。
    func collapseDrawer()
    /// 进入布局编辑模式。
    func enterEditMode()
    /// 退出布局编辑模式。
    func exitEditMode()
    /// 请求刷新紧凑区显示（如插件状态变化后）。
    func refreshCompactDisplay()
    /// 展示或更新活动摘要（同 id 覆盖更新，不改变新旧次序）。插件进入活动状态时
    /// 调用（文档 §4.10；决策见 Agent Note 2026-09-03-compact-area-activity-summary）。
    ///
    /// 必须保持为协议**要求**（extension 只提供默认实现）：宿主与插件经存在类型
    /// 分发，纯 extension 成员会被静态分发遮蔽（见 NotchCenterPluginServices
    /// 的同族历史坑）。
    func showActivitySummary(_ summary: ActivitySummary)
    /// 收回指定活动摘要；id 不存在时无副作用。
    func removeActivitySummary(id: String)
    /// 当前已注册的全部快捷动作（文档 §4.11）。宿主维护注册表：插件启用即入册、
    /// 禁用即注销。返回的实例可直接观察（`ObservableObject`）并执行。编辑模式
    /// 的「快捷动作」目录与快捷按钮盒均经此取数。
    ///
    /// 必须保持为协议**要求**（extension 只提供默认实现）：宿主与插件经存在类型
    /// 分发，纯 extension 成员会被静态分发遮蔽（同 showActivitySummary 纪律）。
    func quickActions() -> [QuickAction]
    /// 按 ID 取快捷动作；不存在（插件禁用/未知 ID）返回 nil。
    func quickAction(id: String) -> QuickAction?
    /// 查询某项系统权限的当前状态（**同步、无副作用、不弹任何窗**）。权限缺失时
    /// 插件据此渲染降级态（引导文案 + 「去系统设置」按钮），页面本身仍须可用。
    ///
    /// 必须保持为协议**要求**（extension 只提供默认实现）：宿主与插件经存在类型
    /// 分发，纯 extension 成员会被静态分发遮蔽（同 showActivitySummary 纪律）。
    func permissionStatus(of permission: SystemPermission) -> PermissionStatus
    /// 请求宿主弹出「权限管理」弹窗，逐条列出需要的权限并给出跳转按钮。
    /// 由插件在**运行时真的发现某权限缺失**时调用（不要在启动时无条件弹，
    /// 那是骚扰）；设置页的「权限管理」入口走同一个终点。
    /// - Parameter focus: 需要用户优先关注的权限；空数组 = 展示完整清单。
    ///
    /// 同上必须保持为协议要求。
    func presentPermissions(_ focus: [SystemPermission])
}

extension HostController {
    /// 默认不展示活动摘要（忽略提交）。
    public func showActivitySummary(_ summary: ActivitySummary) {}

    /// 默认不展示活动摘要（无副作用）。
    public func removeActivitySummary(id: String) {}

    /// 默认无快捷动作。
    public func quickActions() -> [QuickAction] { [] }

    /// 默认查不到任何快捷动作。
    public func quickAction(id: String) -> QuickAction? { nil }

    /// 默认按「未请求」处理：宿主未实现权限查询时插件走引导态而不是当成已授权。
    public func permissionStatus(of permission: SystemPermission) -> PermissionStatus { .notDetermined }

    /// 默认不弹窗（宿主未实现权限弹窗通道时静默忽略）。
    public func presentPermissions(_ focus: [SystemPermission]) {}
}

// MARK: - 快捷动作落位接收方（文档 §4.11）

/// 可选能力：抽屉块实例是否接受「快捷动作」从编辑目录拖入落位。
///
/// 宿主在编辑模式下把动作拖到某抽屉块上方时，向该 placement 所属插件询问；
/// 非盒类插件不遵守本协议即默认拒绝，宿主零块 ID 硬编码，第三方插件可自建容器。
@MainActor
public protocol NotchCenterQuickActionSink: AnyObject {
    /// 询问该放置实例是否接受一次快捷动作落位。接受方负责校验容量并**自行持久化**
    /// （经 placementStore），随后可触发宿主刷新展示。
    /// - Parameters:
    ///   - actionID: 动作 ID（宿主注册表内）。
    ///   - placementID: 目标放置实例。
    ///   - span: 该实例当前的网格跨度（决定内部容量）。
    /// - Returns: 接受并已持久化返回 `true`；拒绝（已满/未知动作/非法状态）返回 `false`，
    ///   宿主据此给用户提示。
    func acceptQuickAction(_ actionID: String, placementID: String, span: GridSpan) -> Bool
}