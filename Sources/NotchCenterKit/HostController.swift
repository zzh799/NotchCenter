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
    /// 展示或更新活动岛（同 id 覆盖）。插件进入活动状态时调用（文档 §4.10）。
    ///
    /// 必须保持为协议**要求**（extension 只提供默认实现）：宿主与插件经存在类型
    /// 分发，纯 extension 成员会被静态分发遮蔽（见 NotchCenterPluginServices
    /// 的同族历史坑）。
    func showActivityIsland(_ content: ActivityIslandContent)
    /// 收回指定活动岛；id 不存在时无副作用。
    func removeActivityIsland(id: String)
}

extension HostController {
    /// 默认不支持活动岛（忽略提交）。
    public func showActivityIsland(_ content: ActivityIslandContent) {}

    /// 默认不支持活动岛（无副作用）。
    public func removeActivityIsland(id: String) {}
}