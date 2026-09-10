import CoreGraphics
import XCTest
@testable import NotchCenter

/// 双游标列数滑条的纯数学：值 ↔ 轨道分数、量化、游标选择与标签防撞。
/// （引擎侧 setter 契约——夹紧 / 忽略写入 / 不回改存量值——见
/// `LayoutEngineTests.testMinimumSettersClampAndRespectMaxColumns`。）
final class ColumnRangeSliderTests: XCTestCase {
    /// 纯数学用例钉在 2...8 轨道上：轨道端点由调用方按**屏幕列容量**传入
    /// （`LayoutEngine.selectableMaxColumnsRange`），与静态兜底范围无关。
    private let math = ColumnRangeSliderMath(valueRange: 2...8)

    // MARK: 值 ↔ 轨道分数

    func testFractionMapsEndsAndMidpoint() {
        XCTAssertEqual(math.fraction(for: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(math.fraction(for: 8), 1, accuracy: 1e-9)
        XCTAssertEqual(math.fraction(for: 5), 0.5, accuracy: 1e-9)
    }

    func testFractionIsMonotonic() {
        let fractions = (2...8).map { math.fraction(for: $0) }
        XCTAssertEqual(fractions, fractions.sorted(), "分数必须随列数单调不减")
    }

    // MARK: 量化

    func testQuantizationRoundsToNearestColumn() {
        func value(_ fraction: CGFloat) -> Int {
            math.value(atFraction: fraction, in: math.maxThumbRange)
        }
        XCTAssertEqual(value(0), 2)
        XCTAssertEqual(value(1), 8)
        // 半档之内留在原档、越过半档才换档（同胶囊行半格判据）。
        XCTAssertEqual(value(0.5 / 6 - 0.001), 2)
        XCTAssertEqual(value(0.5 / 6), 3)
        XCTAssertEqual(value(2.5 / 6 - 0.001), 4)
        XCTAssertEqual(value(2.5 / 6), 5)
    }

    func testQuantizationClampsToCandidateRange() {
        // min 游标值域 3...6：按在轨道两端也夹回候选区间。
        XCTAssertEqual(math.value(atFraction: 0, in: 3...6), 3)
        XCTAssertEqual(math.value(atFraction: 1, in: 3...6), 6)
        XCTAssertEqual(math.value(atFraction: 0.99, in: 2...2), 2)
    }

    // MARK: min 游标值域与显示夹取

    func testMinThumbRangeFollowsMaxColumns() {
        XCTAssertEqual(math.minThumbRange(maxValue: 8), 3...8)
        XCTAssertEqual(math.minThumbRange(maxValue: 3), 3...3)
        // maxColumns < 3：退化成单点区间（恒非空、游标钉死），绝不能 trap。
        XCTAssertEqual(math.minThumbRange(maxValue: 2), 2...2)
    }

    func testDisplayedMinClampsToMaxAndPreservesStorage() {
        XCTAssertEqual(math.displayedMin(storedMin: 4, maxValue: 8), 4)
        // max 调低后显示跟随，存储值原样保留（不回改存量值）。
        XCTAssertEqual(math.displayedMin(storedMin: 8, maxValue: 6), 6)
        XCTAssertEqual(math.displayedMin(storedMin: 4, maxValue: 2), 2)
    }

    // MARK: 游标选择

    func testNearestThumbWins() {
        XCTAssertEqual(
            math.thumb(atFraction: 0.1, minThumbFraction: 0, maxThumbFraction: 1, movement: nil),
            .min
        )
        XCTAssertEqual(
            math.thumb(atFraction: 0.9, minThumbFraction: 0, maxThumbFraction: 1, movement: nil),
            .max
        )
    }

    func testTieDefersUntilDirectionalMovement() {
        // 两游标重合（min == max）：等距悬置，未移动不认领、不提交。
        XCTAssertNil(
            math.thumb(atFraction: 0.5, minThumbFraction: 0.5, maxThumbFraction: 0.5, movement: nil)
        )
        XCTAssertNil(
            math.thumb(atFraction: 0.5, minThumbFraction: 0.5, maxThumbFraction: 0.5, movement: 1)
        )
        // 首次位移方向分工：向左交给 min（向下扩范围）、向右交给 max（向上扩）。
        XCTAssertEqual(
            math.thumb(atFraction: 0.5, minThumbFraction: 0.5, maxThumbFraction: 0.5, movement: -5),
            .min
        )
        XCTAssertEqual(
            math.thumb(atFraction: 0.5, minThumbFraction: 0.5, maxThumbFraction: 0.5, movement: 5),
            .max
        )
        // 按在两颗不同游标正中：同样悬置待方向。
        XCTAssertNil(
            math.thumb(atFraction: 0.5, minThumbFraction: 0.25, maxThumbFraction: 0.75, movement: nil)
        )
        XCTAssertEqual(
            math.thumb(atFraction: 0.5, minThumbFraction: 0.25, maxThumbFraction: 0.75, movement: -5),
            .min
        )
        XCTAssertEqual(
            math.thumb(atFraction: 0.5, minThumbFraction: 0.25, maxThumbFraction: 0.75, movement: 5),
            .max
        )
    }

    // MARK: 标签排布

    func testLabelsCenterOnThumbsWhenRoomy() {
        let origins = math.labelOrigins(
            minThumbCenter: 100, minLabelWidth: 40,
            maxThumbCenter: 300, maxLabelWidth: 40,
            trackWidth: 480
        )
        XCTAssertEqual(origins.min, 80, accuracy: 1e-9)
        XCTAssertEqual(origins.max, 280, accuracy: 1e-9)
    }

    func testLabelsClampInsideTrack() {
        let origins = math.labelOrigins(
            minThumbCenter: 0, minLabelWidth: 40,
            maxThumbCenter: 480, maxLabelWidth: 40,
            trackWidth: 480
        )
        XCTAssertEqual(origins.min, 0, accuracy: 1e-9)
        XCTAssertEqual(origins.max, 440, accuracy: 1e-9)
    }

    func testOverlappingLabelsPushApartSymmetrically() {
        // 无推挤时 min 标签右缘 220+6=226 已越过 max 标签左缘 190：重叠 36，
        // 对称推开各 18，推开后仍留 minimumGap。
        let origins = math.labelOrigins(
            minThumbCenter: 200, minLabelWidth: 40,
            maxThumbCenter: 210, maxLabelWidth: 40,
            trackWidth: 480
        )
        XCTAssertEqual(origins.min, 162, accuracy: 1e-9)
        XCTAssertEqual(origins.max, 208, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(origins.max - (origins.min + 40), 6 - 1e-9)
    }
}
