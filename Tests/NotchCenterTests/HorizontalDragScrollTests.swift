import XCTest
@testable import NotchCenter

/// 横向拖动滚动的位置钳制：负值归 0、超出上限归上限、
/// 内容窄于视口（上限为负）时固定 0 不可滚动。
final class HorizontalDragScrollTests: XCTestCase {
    func testClampsNegativeToZero() {
        XCTAssertEqual(HorizontalDragScrollMath.clamped(-12, max: 300), 0)
    }

    func testClampsBeyondUpperBound() {
        XCTAssertEqual(HorizontalDragScrollMath.clamped(350, max: 300), 300)
    }

    func testPassesThroughValidRange() {
        XCTAssertEqual(HorizontalDragScrollMath.clamped(0, max: 300), 0)
        XCTAssertEqual(HorizontalDragScrollMath.clamped(150.5, max: 300), 150.5)
        XCTAssertEqual(HorizontalDragScrollMath.clamped(300, max: 300), 300)
    }

    func testContentNarrowerThanViewportLocksAtZero() {
        // 内容窄于视口时上限为负,任何目标都钳到 0。
        XCTAssertEqual(HorizontalDragScrollMath.clamped(0, max: -40), 0)
        XCTAssertEqual(HorizontalDragScrollMath.clamped(80, max: -40), 0)
    }
}
