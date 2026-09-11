import Foundation
import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

/// 抽屉内容温存状态机回归（Agent Note 2026-09-11-drawer-content-warmth）：
/// 收起不立即卸载、窗口内再展开不回收、到期回收、从未展开不凭空挂载。
final class DrawerContentWarmthTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testColdBeforeAnyExpand() {
        XCTAssertFalse(DrawerContentWarmth().keepsContentMounted)
    }

    func testCollapseBeforeExpandStaysCold() {
        var warmth = DrawerContentWarmth()
        warmth.collapsed(now: t0)
        XCTAssertFalse(warmth.keepsContentMounted, "从未展开过就不该有内容可温存")
        XCTAssertFalse(warmth.prune(now: t0.addingTimeInterval(10_000)))
    }

    func testExpandKeepsMountedWithoutDeadline() {
        var warmth = DrawerContentWarmth()
        warmth.expanded()
        XCTAssertTrue(warmth.keepsContentMounted)
        // 展开中没有回收期限：再久也不 prune（不能把还在屏上的内容卸掉）。
        XCTAssertFalse(warmth.prune(now: t0.addingTimeInterval(10_000)))
        XCTAssertTrue(warmth.keepsContentMounted)
    }

    func testCollapseKeepsMountedWithinWindow() {
        var warmth = DrawerContentWarmth()
        warmth.expanded()
        warmth.collapsed(now: t0)
        XCTAssertTrue(warmth.keepsContentMounted)
        let justBefore = t0.addingTimeInterval(DrawerContentWarmth.window - 0.001)
        XCTAssertFalse(warmth.prune(now: justBefore), "窗口内不应回收")
        XCTAssertTrue(warmth.keepsContentMounted)
    }

    func testPruneDropsExactlyAtWindowEnd() {
        var warmth = DrawerContentWarmth()
        warmth.expanded()
        warmth.collapsed(now: t0)
        XCTAssertTrue(warmth.prune(now: t0.addingTimeInterval(DrawerContentWarmth.window)))
        XCTAssertFalse(warmth.keepsContentMounted)
    }

    func testReExpandWithinWindowCancelsDeadline() {
        var warmth = DrawerContentWarmth()
        warmth.expanded()
        warmth.collapsed(now: t0)
        warmth.expanded()
        XCTAssertFalse(warmth.prune(now: t0.addingTimeInterval(DrawerContentWarmth.window * 10)))
        XCTAssertTrue(warmth.keepsContentMounted)
    }

    func testPruneReportsOnlyOnce() {
        var warmth = DrawerContentWarmth()
        warmth.expanded()
        warmth.collapsed(now: t0)
        let at = t0.addingTimeInterval(DrawerContentWarmth.window)
        XCTAssertTrue(warmth.prune(now: at))
        XCTAssertFalse(warmth.prune(now: at.addingTimeInterval(1)), "已回收不该重复报告")
    }

    /// 窗口可覆盖：诊断经 `NOTCHCENTER_DRAWER_WARM_SECONDS` 注入，`0` 即"收起就卸载"，
    /// 是同一份二进制里做温存开/关 A/B 的基准侧。
    func testWindowOverrideBoundsExpiry() {
        var warmth = DrawerContentWarmth()
        warmth.expanded()
        warmth.collapsed(now: t0, window: 10)
        XCTAssertFalse(warmth.prune(now: t0.addingTimeInterval(9)))
        XCTAssertTrue(warmth.prune(now: t0.addingTimeInterval(10)))
    }

    func testZeroWindowExpiresImmediately() {
        var warmth = DrawerContentWarmth()
        warmth.expanded()
        warmth.collapsed(now: t0, window: 0)
        XCTAssertTrue(warmth.prune(now: t0), "窗口 0 = 收起即回收")
        XCTAssertFalse(warmth.keepsContentMounted)
    }
}

/// 块可见性信号的环境默认值：未注入本值的场景（设置页预览、Size Lab、
/// 组件目录）必须按"看得到"处理，否则插件会在这些场景里被误判为已收起。
final class DrawerPresentationTests: XCTestCase {
    func testDefaultsToPresentedWhenUninjected() {
        XCTAssertTrue(EnvironmentValues().isDrawerPresented)
    }
}
