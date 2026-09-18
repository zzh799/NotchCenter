@testable import NotchCenterKit
import XCTest

/// 服务卡启停反馈的纯值回归：按压反馈档位判定与白 alpha 阶梯（见 Agent Note
/// 2026-09-18-service-block-startstop-feedback）。
final class ServiceBlockFeedbackTests: XCTestCase {

    // MARK: 按压反馈档位

    func testCompactOnCardPicksDimmedPressFeedback() {
        // 紧凑开启态整块是白底（onBackgroundOpacity），白叠加零对比 → 必须压暗。
        XCTAssertEqual(ServiceBlockView.pressFeedback(isCompact: true, isOn: true), .dimmed)
    }

    func testDarkBackgroundsPickEmphasizedPressFeedback() {
        // 紧凑关闭态与完整排布（深底卡片）走加强增亮档。
        XCTAssertEqual(ServiceBlockView.pressFeedback(isCompact: true, isOn: false), .emphasized)
        XCTAssertEqual(ServiceBlockView.pressFeedback(isCompact: false, isOn: false), .emphasized)
        XCTAssertEqual(ServiceBlockView.pressFeedback(isCompact: false, isOn: true), .emphasized)
    }

    // MARK: 按压叠加强度阶梯

    func testPressOverlayLadderIsStrongerThanHighlight() {
        // standard 档与强调态同级：常态填充 0.025 + 0.03 = 0.055 精确对齐，
        // 描边 0.09 + 0.12 = 0.21 落在 0.20 档（spec 记作 ≈）。
        XCTAssertEqual(
            BlockCardMetrics.standardPressFillOpacity + 0.025,
            0.055,
            accuracy: 0.001)
        XCTAssertEqual(
            BlockCardMetrics.standardPressStrokeOpacity + 0.09,
            0.20,
            accuracy: 0.02)
        // emphasized 档必须在强调态之上：按下 > 强调（0.055 / 0.20）> 悬停（0.04）。
        XCTAssertGreaterThan(
            BlockCardMetrics.emphasizedPressFillOpacity + 0.025,
            0.055)
        XCTAssertGreaterThan(
            BlockCardMetrics.emphasizedPressStrokeOpacity + 0.09,
            0.20)
        // 浅底档：黑叠加压暗，不叠描边。
        XCTAssertGreaterThan(BlockCardMetrics.dimmedPressFillOpacity, 0)
    }

    // MARK: 紧凑排布几何

    func testBusyRingFitsIconSlot() {
        // 图标位槽高须容得下旋转指示，busy 切换不撑高（否则名称会被顶动）。
        XCTAssertGreaterThanOrEqual(
            ServiceBlockCompactMetrics.iconSlotHeight,
            ServiceBlockCompactMetrics.busyRingDiameter)
        XCTAssertGreaterThan(ServiceBlockCompactMetrics.busyRingLineWidth, 0)
    }
}
