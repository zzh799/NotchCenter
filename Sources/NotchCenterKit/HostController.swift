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
}