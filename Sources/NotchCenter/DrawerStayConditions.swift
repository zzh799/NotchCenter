import Foundation

// MARK: - 抽屉收起守卫

/// 展开态的保持条件快照。
///
/// 从控制器各处收集成一 个纯值，判定是一个纯函数——这样"什么情况下不许
/// 收起"可以被逐字段测试，而不是埋在 30Hz 轮询回调里。
struct DrawerStayConditions: Equatable, Sendable {
    /// 菜单正在追踪（状态栏菜单 / 弹出菜单挂起）。
    var isMenuTracking: Bool
    /// 设置面板打开期间抽屉常驻：收起会让面板悬空（文档 §6.1 扩展）。
    var isSettingsPresented: Bool
    /// 编辑模式。
    var isEditing: Bool
    /// 收起态进入编辑的等待期（揭示 → 编辑两段式之间）。
    var isEditEntryPending: Bool
    /// 用户钉住。
    var isPinned: Bool
    /// 点击触发模式：抽屉只随点击开合，悬停不参与收起。
    var isClickTriggered: Bool
    /// 滑动切页后的「待重入」驻留期：鼠标在抽屉外也不自动收起，等鼠标
    /// 重新进入停留区（`handleMouseLocation` 在停留区内清除本标志）再移出
    /// 后才正常收起；期间点另一块屏的刘海热区会把抽屉搬过去（`expand`
    /// 清除）。
    var isAwaitingDrawerReentry = false

    /// 任一条件成立即应保持展开。
    var shouldKeepExpanded: Bool {
        isMenuTracking || isSettingsPresented || isEditing
            || isEditEntryPending || isPinned || isClickTriggered
            || isAwaitingDrawerReentry
    }
}
