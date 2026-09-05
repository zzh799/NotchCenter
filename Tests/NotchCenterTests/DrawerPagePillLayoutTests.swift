import CoreGraphics
import XCTest
@testable import NotchCenter

/// 分页胶囊行的槽位数学：定宽等距下的拖动落点与让位预览。
/// （预览与提交是否逐位同解，在 `DrawerPageTests.testPillDragPreviewMatchesCommittedOrder`
/// 里对着真引擎穷举校验。）
final class DrawerPagePillLayoutTests: XCTestCase {
    private var step: CGFloat { DrawerPagePillLayout.step }

    // MARK: 位移 → 目标槽位

    func testRestTranslationKeepsSlot() {
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 2, translation: 0, count: 5), 2
        )
    }

    func testSubHalfStepJitterDoesNotChangeSlot() {
        // 半格之内的抖动必须留在原槽位（按下不跳位，指针微抖不闪）。
        for translation in [-step / 2 + 1, -1, 1, step / 2 - 1] {
            XCTAssertEqual(
                DrawerPagePillLayout.targetIndex(draggedIndex: 2, translation: translation, count: 5),
                2,
                "位移 \(translation) 不该换槽位"
            )
        }
    }

    func testStepMultiplesMoveThatManySlots() {
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 1, translation: step, count: 5), 2
        )
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 3, translation: -step, count: 5), 2
        )
        // 跨多颗：2.6 步 → 就近落到 +3 槽。
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 0, translation: step * 2.6, count: 5), 3
        )
    }

    func testTargetIndexClampsToSequenceEnds() {
        // 两端夹紧：序列内没有"末尾之后"这个槽位（加号在胶囊外，不参与排序）。
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 0, translation: -step * 10, count: 5), 0
        )
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 4, translation: step * 10, count: 5), 4
        )
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 0, translation: 0, count: 1), 0
        )
        XCTAssertEqual(
            DrawerPagePillLayout.targetIndex(draggedIndex: 0, translation: step, count: 0), 0
        )
    }

    // MARK: 让位预览

    func testDraggedPillStaysInItsOwnSlot() {
        // 基座钉死：被拖者的显示槽位恒等于原槽位，跟手量才是纯粹的 offset。
        for target in 0..<5 {
            XCTAssertEqual(
                DrawerPagePillLayout.displayIndex(slot: 2, draggedIndex: 2, targetIndex: target),
                2
            )
        }
    }

    func testNoCrossMoveLeavesOthersUntouched() {
        for slot in [0, 1, 3, 4] {
            XCTAssertEqual(
                DrawerPagePillLayout.displayIndex(slot: slot, draggedIndex: 2, targetIndex: 2),
                slot,
                "目标位就是原位时无人让位"
            )
        }
    }

    func testMoveRightShiftsSpannedPillsLeftByOne() {
        // 2 → 4：中间被跨越的 3、4 各左移一位，0、1 与区间外的不动。
        XCTAssertEqual(
            DrawerPagePillLayout.displayIndex(slot: 3, draggedIndex: 2, targetIndex: 4), 2
        )
        XCTAssertEqual(
            DrawerPagePillLayout.displayIndex(slot: 4, draggedIndex: 2, targetIndex: 4), 3
        )
        XCTAssertEqual(
            DrawerPagePillLayout.displayIndex(slot: 0, draggedIndex: 2, targetIndex: 4), 0
        )
    }

    func testMoveLeftShiftsSpannedPillsRightByOne() {
        // 3 → 1：区间 [1, 3) 内的 1、2 各右移一位。
        XCTAssertEqual(
            DrawerPagePillLayout.displayIndex(slot: 1, draggedIndex: 3, targetIndex: 1), 2
        )
        XCTAssertEqual(
            DrawerPagePillLayout.displayIndex(slot: 2, draggedIndex: 3, targetIndex: 1), 3
        )
        XCTAssertEqual(
            DrawerPagePillLayout.displayIndex(slot: 4, draggedIndex: 3, targetIndex: 1), 4
        )
    }

    func testDisplayIndexIsABijectionForEveryPair() {
        // 每对 (被拖, 目标) 下，让位后的槽位集合必须正好铺满整行（无空槽、无叠位）。
        let count = 6
        for dragged in 0..<count {
            for target in 0..<count {
                let destinations = (0..<count).map {
                    $0 == dragged
                        ? target
                        : DrawerPagePillLayout.displayIndex(
                            slot: $0, draggedIndex: dragged, targetIndex: target
                        )
                }
                XCTAssertEqual(Set(destinations).count, count, "\(dragged)→\(target): \(destinations)")
            }
        }
    }

    // MARK: 滑动会话高亮层（激活胶囊 → 目标胶囊随进度平移）

    func testHighlightXEndpointsAreSlotOrigins() {
        // p=0 停在激活胶囊左缘、p=1 到目标胶囊左缘（槽距 = step）。
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 0, toSlot: 2, progress: 0), 0)
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 0, toSlot: 2, progress: 1), 2 * step)
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 3, toSlot: 1, progress: 1), step)
    }

    func testHighlightXInterpolatesLinearlyWithProgress() {
        // 半程 = 两槽中点；进度与滑动会话的 offset/gap 同源，跟手/落位/回弹一致。
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 1, toSlot: 3, progress: 0.5), 2 * step)
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 3, toSlot: 1, progress: 0.25), 2.5 * step)
        XCTAssertEqual(
            DrawerPagePillLayout.highlightX(fromSlot: 0, toSlot: 4, progress: 0.25),
            step,
            "四槽距的四分之一 = 一格"
        )
    }

    func testHighlightXClampsProgressAndHandlesSameSlot() {
        // 越界进度夹紧（落位 spring 轻微过冲时高亮不飞出目标胶囊）。
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 1, toSlot: 3, progress: -0.5), step)
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 1, toSlot: 3, progress: 4.0), 3 * step)
        // 会话异常（目标槽位缺失退化为激活槽位）时高亮纹丝不动。
        XCTAssertEqual(DrawerPagePillLayout.highlightX(fromSlot: 2, toSlot: 2, progress: 0.7), 2 * step)
    }

    // MARK: 胶囊行命中（设置面板拖拽的驻留切页）

    /// 三页胶囊行的参照系：行左缘 100，各胶囊中心 = rowLeft + 52 + slot×step
    ///（加号 20 + 间距 6 + 半颗胶囊 26），行宽 216，命中范围 ±半个间隙。
    private let rowLeft: CGFloat = 100

    private func center(_ slot: Int) -> CGFloat {
        rowLeft + (DrawerPagePillLayout.addButtonDiameter + DrawerPagePillLayout.addSpacing)
            + CGFloat(slot) * step
            + DrawerPagePillLayout.pillWidth / 2
    }

    func testRowWidthMatchesLayoutSum() {
        // n 颗胶囊 + 间隙 + 两端常驻加号（隐藏也占位）：52 + 56n − 4。
        XCTAssertEqual(DrawerPagePillLayout.rowWidth(pageCount: 0), 0)
        XCTAssertEqual(DrawerPagePillLayout.rowWidth(pageCount: 1), 104)
        XCTAssertEqual(DrawerPagePillLayout.rowWidth(pageCount: 3), 216)
    }

    func testRowCenterOffsetCompensatesEditTopBar() {
        // 编辑模式顶栏左侧多一颗"一键重排"（24 + 间距 8），行心右移 16pt。
        XCTAssertEqual(DrawerPagePillLayout.rowCenterOffset(isEditing: false), 0)
        XCTAssertEqual(DrawerPagePillLayout.rowCenterOffset(isEditing: true), 16)
    }

    func testHoveredSlotMapsCapsuleCentersToOwnSlot() {
        for slot in 0..<3 {
            XCTAssertEqual(
                DrawerPagePillLayout.hoveredSlot(x: center(slot), rowLeft: rowLeft, pageCount: 3),
                slot,
                "胶囊 \(slot) 的中心必须命中自身槽位"
            )
        }
    }

    func testHoveredSlotNearestCenterIncludesGapsAndAddButtons() {
        // 间隙取两侧就近；两端加号区就近归首/末颗胶囊（命中面宜宽）。
        XCTAssertEqual(
            DrawerPagePillLayout.hoveredSlot(
                x: (center(0) + center(1)) / 2, rowLeft: rowLeft, pageCount: 3
            ), 1
        )
        XCTAssertEqual(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft + 10, rowLeft: rowLeft, pageCount: 3), 0
        )
        XCTAssertEqual(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft + 206, rowLeft: rowLeft, pageCount: 3), 2
        )
    }

    func testHoveredSlotAcceptsHalfGapBeyondRowAndRejectsFarther() {
        XCTAssertEqual(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft - 2, rowLeft: rowLeft, pageCount: 3), 0
        )
        XCTAssertNil(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft - 4, rowLeft: rowLeft, pageCount: 3)
        )
        XCTAssertEqual(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft + 218, rowLeft: rowLeft, pageCount: 3), 2
        )
        XCTAssertNil(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft + 220, rowLeft: rowLeft, pageCount: 3)
        )
    }

    func testHoveredSlotSinglePageAndEmptyRow() {
        // 单页：胶囊命中自身，行右侧远处（多页时是末颗胶囊的地盘）不命中。
        XCTAssertEqual(
            DrawerPagePillLayout.hoveredSlot(x: center(0), rowLeft: rowLeft, pageCount: 1), 0
        )
        XCTAssertNil(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft + 306, rowLeft: rowLeft, pageCount: 1)
        )
        XCTAssertNil(
            DrawerPagePillLayout.hoveredSlot(x: rowLeft, rowLeft: rowLeft, pageCount: 0)
        )
    }
}
