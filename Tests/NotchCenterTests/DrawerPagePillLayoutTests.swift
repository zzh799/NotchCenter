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

    // MARK: 顶栏滚动区（偏移 / 可见性 / 露出 / 自动滚）

    /// 三页、区宽 116（行宽 216）是本节全部用例的参照系：槽位 0/1/2 的行内区间
    /// 分别是 [26,78] / [82,134] / [138,190]，加号 [0,20] 与 [196,216]；行心相对
    /// 区心的偏移余量 = (216 − 116)/2 = 50。偏移 0 = 行心对齐区心（两端各裁 50）。
    private let tightRegion: CGFloat = 116

    func testScrollExtentIsZeroWhenRowFits() {
        // 放得下就是不可滚（行居中，偏移恒 0）。
        XCTAssertEqual(DrawerPagePillLayout.scrollExtent(regionWidth: 300, pageCount: 3), 0)
        XCTAssertEqual(DrawerPagePillLayout.scrollExtent(regionWidth: 216, pageCount: 3), 0)
        XCTAssertEqual(DrawerPagePillLayout.scrollExtent(regionWidth: 116, pageCount: 3), 50)
    }

    func testClampedOffsetKeepsSymmetricDomain() {
        XCTAssertEqual(DrawerPagePillLayout.clampedOffset(-999, regionWidth: tightRegion, pageCount: 3), -50)
        XCTAssertEqual(DrawerPagePillLayout.clampedOffset(-30, regionWidth: tightRegion, pageCount: 3), -30)
        XCTAssertEqual(DrawerPagePillLayout.clampedOffset(30, regionWidth: tightRegion, pageCount: 3), 30)
        XCTAssertEqual(DrawerPagePillLayout.clampedOffset(999, regionWidth: tightRegion, pageCount: 3), 50)
        // 放得下时任何存量偏移都归 0（指标/页数变化后越界值的兜底）。
        XCTAssertEqual(DrawerPagePillLayout.clampedOffset(30, regionWidth: 400, pageCount: 3), 0)
        XCTAssertEqual(DrawerPagePillLayout.clampedOffset(-30, regionWidth: 400, pageCount: 3), 0)
    }

    func testRowLeftInRegionKeepsRowHeartOnRegionHeart() {
        // 放得下：居中（300 − 216）/2 = 42。
        XCTAssertEqual(
            DrawerPagePillLayout.rowLeftInRegion(regionWidth: 300, pageCount: 3, offset: 0), 42
        )
        // 溢出：偏移 0 仍是**居中**（行心对齐区心，两端各裁 50）——这是"面板宽度
        // 变化时胶囊不平移"的根据（行左缘不再绑在随宽度移动的区左缘上）。
        XCTAssertEqual(
            DrawerPagePillLayout.rowLeftInRegion(regionWidth: tightRegion, pageCount: 3, offset: 0), -50
        )
        // 偏移把行整体左移/右移，两端极值恰好让行首/行尾进视野。
        XCTAssertEqual(
            DrawerPagePillLayout.rowLeftInRegion(regionWidth: tightRegion, pageCount: 3, offset: 30), -80
        )
        XCTAssertEqual(
            DrawerPagePillLayout.rowLeftInRegion(regionWidth: tightRegion, pageCount: 3, offset: -50), 0
        )
        XCTAssertEqual(
            DrawerPagePillLayout.rowLeftInRegion(regionWidth: tightRegion, pageCount: 3, offset: 50), -100
        )
    }

    func testAddButtonRangesSitOutsideSlotMath() {
        XCTAssertEqual(DrawerPagePillLayout.leadingAddRange, 0...20)
        XCTAssertEqual(DrawerPagePillLayout.trailingAddRange(pageCount: 3), 196...216)
    }

    func testVisibilityFullPartialHidden() {
        let visibility = { (slot: Int, offset: CGFloat) in
            DrawerPagePillLayout.visibility(
                of: DrawerPagePillLayout.pillRange(slot: slot),
                regionWidth: self.tightRegion,
                pageCount: 3,
                offset: offset
            )
        }
        // 居中（窗口 = [50, 166]）：中间的槽位 1 整颗在内，两端各被裁 24pt。
        XCTAssertEqual(visibility(0, 0), .partial(offset: 24, width: 28))
        XCTAssertEqual(visibility(1, 0), .full)
        XCTAssertEqual(visibility(2, 0), .partial(offset: 0, width: 28))
        // 滚到左端（窗口 = [0, 116]）：槽位 0 整颗在内、槽位 2 出视野。
        XCTAssertEqual(visibility(0, -50), .full)
        XCTAssertEqual(visibility(1, -50), .partial(offset: 0, width: 34))
        XCTAssertEqual(visibility(2, -50), .hidden)
        // 滚到右端（窗口 = [100, 216]）：槽位 0 出视野、槽位 2 整颗在内。
        XCTAssertEqual(visibility(0, 50), .hidden)
        XCTAssertEqual(visibility(1, 50), .partial(offset: 18, width: 34))
        XCTAssertEqual(visibility(2, 50), .full)
    }

    func testVisibilityTreatsUnknownRegionAsUnclipped() {
        // 宽度还没量到（0）时不许误判"全在视野外"——那会让整行不可点。
        XCTAssertEqual(
            DrawerPagePillLayout.visibility(
                of: DrawerPagePillLayout.pillRange(slot: 5),
                regionWidth: 0,
                pageCount: 6,
                offset: 0
            ),
            .full
        )
    }

    func testOffsetRevealingMovesOnlyWhenSlotIsClipped() {
        // 放得下：偏移恒 0，谁也不动。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 2, offset: 0, regionWidth: 300, pageCount: 3), 0
        )
        // 居中时中间那颗本来就整颗可见 → 切页到它纹丝不动（"尽量留在原位"）。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 1, offset: 0, regionWidth: tightRegion, pageCount: 3), 0
        )
        // 两端被裁 → 最小位移到刚好整颗露出（槽位 0 往右 24；槽位 2 往左 24）。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 0, offset: 0, regionWidth: tightRegion, pageCount: 3), -24
        )
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 2, offset: 0, regionWidth: tightRegion, pageCount: 3), 24
        )
        // 已完整可见的槽位不回滚多余偏移（就近夹紧：自由滚过去的行不被拽动）。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 2, offset: 50, regionWidth: tightRegion, pageCount: 3), 50
        )
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 0, offset: -50, regionWidth: tightRegion, pageCount: 3), -50
        )
        // 被推出视野时往回拉。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 0, offset: 50, regionWidth: tightRegion, pageCount: 3), -24
        )
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(slot: 2, offset: -50, regionWidth: tightRegion, pageCount: 3), 24
        )
    }

    func testOffsetRevealingFallsBackToLastSlotWhenUnionCannotFit() {
        // 并集装得下（[82,190] 宽 108 ≤ 116）→ 就近取一个能同时露出两者的偏移。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(
                slots: [1, 2], offset: 0, regionWidth: tightRegion, pageCount: 3
            ),
            24
        )
        // 并集装不下（[26,190] 宽 164）→ 只保证最后一个（切页里目标页比起点重要）。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(
                slots: [0, 2], offset: 0, regionWidth: tightRegion, pageCount: 3
            ),
            24
        )
        // 空集合不崩、原样夹紧。
        XCTAssertEqual(
            DrawerPagePillLayout.offsetRevealing(
                slots: [], offset: 200, regionWidth: tightRegion, pageCount: 3
            ),
            50
        )
    }

    func testAutoScrollVelocityZeroOutsideEdgeBands() {
        let edge = DrawerPagePillLayout.autoScrollEdge
        XCTAssertEqual(
            DrawerPagePillLayout.autoScrollVelocity(pointerX: 200, regionLeft: 100, regionWidth: 200), 0,
            "区中间不滚"
        )
        XCTAssertEqual(
            DrawerPagePillLayout.autoScrollVelocity(
                pointerX: 100 + edge + 1, regionLeft: 100, regionWidth: 200
            ),
            0,
            "边带外一丁点不滚"
        )
    }

    func testAutoScrollVelocitySignAndSaturation() {
        let edge = DrawerPagePillLayout.autoScrollEdge
        let maxSpeed = DrawerPagePillLayout.autoScrollMaxSpeed
        // 右带 → 正速率（行左移、露出右侧内容）；压到区右缘 = 满速。
        XCTAssertEqual(
            DrawerPagePillLayout.autoScrollVelocity(pointerX: 300, regionLeft: 100, regionWidth: 200),
            maxSpeed
        )
        // 左带 → 负速率。
        XCTAssertEqual(
            DrawerPagePillLayout.autoScrollVelocity(pointerX: 100, regionLeft: 100, regionWidth: 200),
            -maxSpeed
        )
        // 带内线性：压入一半 = 半速。
        XCTAssertEqual(
            DrawerPagePillLayout.autoScrollVelocity(pointerX: 288, regionLeft: 100, regionWidth: 200),
            maxSpeed / 2
        )
        // 宽还没量到时不滚。
        XCTAssertEqual(
            DrawerPagePillLayout.autoScrollVelocity(pointerX: 100, regionLeft: 100, regionWidth: 0), 0
        )
    }
}
