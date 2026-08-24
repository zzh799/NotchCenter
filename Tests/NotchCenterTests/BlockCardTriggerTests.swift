import XCTest
@testable import NotchCenterKit

// MARK: - blockPopoverTrigger 按压分类（BlockTapClassifier 纯函数回归）

/// 「点击开网页」失效的根因是旧实现里 `TapGesture` 与 simultaneous 失败长按
/// 并存时不触发（真机复现，合成 HID 点击对照实验见提交记录）。新实现由单个
/// `DragGesture(minimumDistance: 0)` 驱动，分类决策收敛到 `BlockTapClassifier`，
/// 这里覆盖全部边界。
final class BlockCardTriggerTests: XCTestCase {
    private let tap = CGSize.zero

    func testQuickStationaryReleaseIsTap() {
        // 快速松手（远短于 0.2s）且未移动 → 点击开网页。
        XCTAssertTrue(BlockTapClassifier.isTap(heldDuration: 0.05, translation: tap, longPressFired: false))
        XCTAssertTrue(BlockTapClassifier.isTap(heldDuration: 0.15, translation: tap, longPressFired: false))
    }

    func testHoldPastLongPressDurationIsNotTap() {
        // 按满 0.2s 浮窗已弹（或临界），松手不得再开网页。
        XCTAssertFalse(BlockTapClassifier.isTap(heldDuration: BlockTapClassifier.longPressDuration, translation: tap, longPressFired: false))
        XCTAssertFalse(BlockTapClassifier.isTap(heldDuration: 1.0, translation: tap, longPressFired: false))
    }

    func testReleaseAfterLongPressFiredIsNotTap() {
        // 长按浮窗已弹出后的松手必须被抑制（防误开网页）。
        XCTAssertFalse(BlockTapClassifier.isTap(heldDuration: 0.5, translation: tap, longPressFired: true))
    }

    func testMovementBeyondToleranceIsNotTap() {
        // 拖动滚动意图：位移超出容忍即不是点击；容忍范围内仍算。
        XCTAssertFalse(BlockTapClassifier.isTap(
            heldDuration: 0.05,
            translation: CGSize(width: BlockTapClassifier.movementTolerance + 1, height: 0),
            longPressFired: false
        ))
        XCTAssertFalse(BlockTapClassifier.isTap(
            heldDuration: 0.05,
            translation: CGSize(width: 0, height: BlockTapClassifier.movementTolerance + 1),
            longPressFired: false
        ))
        XCTAssertTrue(BlockTapClassifier.isTap(
            heldDuration: 0.05,
            translation: CGSize(width: BlockTapClassifier.movementTolerance - 1, height: 0),
            longPressFired: false
        ))
    }
}
