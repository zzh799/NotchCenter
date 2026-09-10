import CoreGraphics
import XCTest
@testable import NotchCenter

// MARK: - 网格容量纯计算（屏幕尺寸 + 格尺寸）
//
// 容量是行列数可选档位与生效上限的共同来源，且是**纯函数**——本套件不建引擎、
// 不碰 `GridMetricsStore` 单例，直接喂 `GridMetrics` 快照（抽取该类型的初衷）。

final class GridCapacityTests: XCTestCase {
    /// 出厂默认格：150×120、间隔 12、内边距 16、顶栏 36。
    private let metrics = GridMetrics(
        cellWidth: 150,
        cellHeight: 120,
        spacing: 12,
        contentPadding: 16,
        topBarHeight: 36
    )

    func testColumnsFitWidthBudget() {
        // floor((1440 − 16×2 + 12) / (150 + 12)) = floor(1420 / 162) = 8
        XCTAssertEqual(GridCapacity.columns(availableWidth: 1440, metrics: metrics), 8)
        // floor((700 − 32 + 12) / 162) = floor(680 / 162) = 4
        XCTAssertEqual(GridCapacity.columns(availableWidth: 700, metrics: metrics), 4)
    }

    func testColumnsNeverDropBelowOne() {
        XCTAssertEqual(GridCapacity.columns(availableWidth: 0, metrics: metrics), 1)
        XCTAssertEqual(GridCapacity.columns(availableWidth: -100, metrics: metrics), 1)
    }

    func testRowsDeductTopBarAndBottomPadding() {
        // floor((900 − 36 − 16 + 12) / (120 + 12)) = floor(860 / 132) = 6
        XCTAssertEqual(GridCapacity.rows(availableHeight: 900, metrics: metrics), 6)
        // 恰好一行的高度预算：topBar 36 + cellHeight 120 + padding 16 = 172
        XCTAssertEqual(GridCapacity.rows(availableHeight: 172, metrics: metrics), 1)
        XCTAssertEqual(GridCapacity.rows(availableHeight: 171, metrics: metrics), 1, "放不下也不退化为 0")
    }

    func testRowsFollowCellHeight() {
        let tall = GridMetrics(
            cellWidth: 150,
            cellHeight: 240,
            spacing: 12,
            contentPadding: 16,
            topBarHeight: 36
        )
        // floor((900 − 36 − 16 + 12) / 252) = floor(860 / 252) = 3
        XCTAssertEqual(GridCapacity.rows(availableHeight: 900, metrics: tall), 3)
    }

    /// 步长为 0 的退化指标不得触发除零：恒返回 1。
    func testDegenerateStepFallsBackToOne() {
        let zero = GridMetrics(
            cellWidth: 0,
            cellHeight: 0,
            spacing: 0,
            contentPadding: 0,
            topBarHeight: 0
        )
        XCTAssertEqual(GridCapacity.columns(availableWidth: 1440, metrics: zero), 1)
        XCTAssertEqual(GridCapacity.rows(availableHeight: 900, metrics: zero), 1)
    }

    // MARK: 多屏合并（文档 §7.1 / §7.2：按最小屏算）

    func testMinimumAvailabilityTakesComponentWiseMinimum() {
        let merged = GridCapacity.minimumAvailability([
            CGSize(width: 2560, height: 1400),
            CGSize(width: 1512, height: 936)
        ])
        XCTAssertEqual(merged, CGSize(width: 1512, height: 936), "单屏被另一块全面压制")
    }

    /// 宽、高分别来自不同屏时取**分量**最小——那个"在每块屏上都放得下"的矩形下界。
    func testMinimumAvailabilityMixesDimensionsAcrossScreens() {
        let merged = GridCapacity.minimumAvailability([
            CGSize(width: 1200, height: 1600),
            CGSize(width: 2000, height: 900)
        ])
        XCTAssertEqual(merged, CGSize(width: 1200, height: 900))
    }

    func testMinimumAvailabilitySingleScreenIsIdentity() {
        let only = CGSize(width: 1512, height: 936)
        XCTAssertEqual(GridCapacity.minimumAvailability([only]), only)
    }

    /// 空序列无参考屏：返回 nil，由调用方决定兜底（引擎侧不写任何值）。
    func testMinimumAvailabilityEmptyReturnsNil() {
        XCTAssertNil(GridCapacity.minimumAvailability([]))
    }
}
