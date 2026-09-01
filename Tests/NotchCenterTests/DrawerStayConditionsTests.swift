import XCTest
@testable import NotchCenter

/// 收起守卫回归：`handleMouseLocation` 与 `scheduleCollapse` 到期回调此前
/// 各自维护条件清单，到期回调漏判 `isEditEntryPending` 与
/// `isSettingsPresented`。收进 `DrawerStayConditions` 后，这里逐字段钉住
/// "任一条件成立即保持展开"。
final class DrawerStayConditionsTests: XCTestCase {
    private var none: DrawerStayConditions {
        DrawerStayConditions(
            isMenuTracking: false,
            isSettingsPresented: false,
            isEditing: false,
            isEditEntryPending: false,
            isPinned: false,
            isClickTriggered: false
        )
    }

    func testNoConditionMeansCollapsible() {
        XCTAssertFalse(none.shouldKeepExpanded)
    }

    func testEveryConditionAloneKeepsExpanded() {
        var conditions = none
        conditions.isMenuTracking = true
        XCTAssertTrue(conditions.shouldKeepExpanded, "菜单追踪挂起期间不得收起")

        conditions = none
        conditions.isSettingsPresented = true
        XCTAssertTrue(conditions.shouldKeepExpanded, "设置面板打开期间抽屉常驻")

        conditions = none
        conditions.isEditing = true
        XCTAssertTrue(conditions.shouldKeepExpanded)

        conditions = none
        conditions.isPinned = true
        XCTAssertTrue(conditions.shouldKeepExpanded)

        conditions = none
        conditions.isClickTriggered = true
        XCTAssertTrue(conditions.shouldKeepExpanded, "点击模式不参与悬停收起")
    }

    /// 回归：`scheduleCollapse` 到期回调此前漏判等待期——收起态点编辑按钮
    /// 后（0.38s 等待期）把鼠标移出停留区，揭示会在中途被收起。
    func testEditEntryPendingIsHonored() {
        var conditions = none
        conditions.isEditEntryPending = true
        XCTAssertTrue(conditions.shouldKeepExpanded)
    }

    /// 滑动切页后的「待重入」驻留期：鼠标在抽屉外也不自动收起；重入停留区
    /// 由 `handleMouseLocation` 清除标志后才恢复正常悬停收起。
    func testAwaitingDrawerReentryKeepsExpanded() {
        var conditions = none
        conditions.isAwaitingDrawerReentry = true
        XCTAssertTrue(conditions.shouldKeepExpanded, "滑动后鼠标在抽屉外期间不得自动收起")

        // 与其他保持条件互不影响：各自独立成立即保持。
        conditions = none
        conditions.isAwaitingDrawerReentry = true
        conditions.isPinned = true
        XCTAssertTrue(conditions.shouldKeepExpanded)
        conditions = none
        conditions.isAwaitingDrawerReentry = true
        conditions.isMenuTracking = true
        XCTAssertTrue(conditions.shouldKeepExpanded)
    }
}
