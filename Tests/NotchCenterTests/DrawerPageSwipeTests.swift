import AppKit
import XCTest
@testable import NotchCenter

/// 抽屉左右滑动切页的判据：方向门槛与横纵压比、跟手位移与橡皮筋、落位阈值、
/// 冷却与"一次手势只翻一页"，以及相邻页按显示序列解析。
///
/// 钉的是当前手感（同 `ResizeHysteresisTests` / `DrawerGestureMathTests`），
/// 事件序列按 `NotchPanelController.handleDrawerScroll` 的契约重放。
final class DrawerPageSwipeTests: XCTestCase {
    /// 常用页宽：落位门槛 = min(1000 × 0.28, 90) = 90pt。
    private let limit: CGFloat = 1_000

    // MARK: 方向判定

    func testSideForHorizontalTranslation() {
        // 内容跟手：向右拖（正位移）揭示左侧页，向左拖揭示右侧页。
        XCTAssertEqual(DrawerPageSwipe.side(for: CGSize(width: 120, height: 0), threshold: 14), .left)
        XCTAssertEqual(DrawerPageSwipe.side(for: CGSize(width: -120, height: 0), threshold: 14), .right)
    }

    func testSideRequiresThreshold() {
        XCTAssertNil(DrawerPageSwipe.side(for: CGSize(width: 39, height: 0), threshold: 40))
        XCTAssertEqual(DrawerPageSwipe.side(for: CGSize(width: -40, height: 0), threshold: 40), .right)
    }

    func testSideRequiresLateralDominance() {
        // 斜着划（纵向更多）与纯竖向都不是切页。
        XCTAssertNil(DrawerPageSwipe.side(for: CGSize(width: 300, height: 300), threshold: 14))
        XCTAssertNil(DrawerPageSwipe.side(for: CGSize(width: 40, height: 400), threshold: 14))
        // 恰好压过 dominanceRatio 才算横向。
        let justEnough = CGSize(width: -200, height: -200 / DrawerPageSwipe.dominanceRatio)
        XCTAssertEqual(DrawerPageSwipe.side(for: justEnough, threshold: 14), .right)
        XCTAssertNil(DrawerPageSwipe.side(for: CGSize(width: -200, height: -140), threshold: 14))
    }

    // MARK: 跟手位移与落位阈值

    func testOffsetTracksOneToOneWithinLimit() {
        XCTAssertEqual(DrawerPageSwipe.offset(translation: -40, limit: limit), -40)
        XCTAssertEqual(DrawerPageSwipe.offset(translation: 260, limit: limit), 260)
    }

    func testOffsetRubberBandsBeyondLimit() {
        // 越界后每 1pt 只推进 rubberBand，且保持同号。
        let expected = -(limit + (1_200 - limit) * DrawerPageSwipe.rubberBand)
        XCTAssertEqual(DrawerPageSwipe.offset(translation: -1_200, limit: limit), expected, accuracy: 0.001)
        XCTAssertEqual(
            DrawerPageSwipe.offset(translation: -5_000, limit: limit),
            -(limit + (5_000 - limit) * DrawerPageSwipe.rubberBand),
            accuracy: 0.001,
            "再猛拖也只按阻尼推进，不会几倍页宽地飞出去"
        )
        XCTAssertEqual(DrawerPageSwipe.offset(translation: -300, limit: 0), 0, "无页宽可参照时不产生位移")
    }

    func testShouldCommitUsesNarrowerOfRatioAndDistance() {
        // 宽页面：门槛退化成绝对距离 90pt（否则手指划不到 28% 页宽）。
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: -89, limit: limit))
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(offset: -90, limit: limit))
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(offset: 90, limit: limit))
        // 窄页面（200pt）：比例门槛 56pt 比 90pt 更严。
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: 55, limit: 200))
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(offset: 60, limit: 200))
    }

    // MARK: 页带几何（两层刚性相邻 + 落位终点）

    func testGapAbutsPagesByTheirOwnWidths() {
        XCTAssertEqual(DrawerPageSwipe.gap(side: .right, gridWidth: 1_000, targetWidth: 600), 1_000)
        XCTAssertEqual(DrawerPageSwipe.gap(side: .left, gridWidth: 1_000, targetWidth: 600), -600)
    }

    func testArrivalOffsetLandsPreviewExactlyAtZero() {
        // 预览层位置 = offset + gap，落位终点必须让它正好覆盖可视区（x=0）。
        let cases: [(side: DrawerPageSide, gridWidth: CGFloat, targetWidth: CGFloat)] = [
            (.right, 1_000, 600), (.left, 1_000, 600), (.right, 600, 1_000),
        ]
        for case let (side, gridWidth, targetWidth) in cases {
            let gap = DrawerPageSwipe.gap(side: side, gridWidth: gridWidth, targetWidth: targetWidth)
            let offset = DrawerPageSwipe.arrivalOffset(gap: gap)
            XCTAssertEqual(offset + gap, 0, "预览层落到 x=0（\(side)）")
            XCTAssertEqual(abs(offset), side == .right ? gridWidth : targetWidth,
                           "网格位移等于它自己那一页的宽度：滑到刚好看不见")
        }
    }

    func testArrivalOffsetIsBeyondCommitThreshold() {
        // 落位终点必然远过门槛：门槛取 min(页宽×0.28, 90)，位移却要走满整页宽。
        let gap = DrawerPageSwipe.gap(side: .right, gridWidth: limit, targetWidth: limit)
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(
            offset: DrawerPageSwipe.arrivalOffset(gap: gap), limit: limit
        ))
    }

    // MARK: 触控板累加器（有手势边界）

    func testFlickLocksDirectionAndFollowsAccumulation() {
        var tracker = DrawerPageScrollTracker()
        XCTAssertNil(
            tracker.feed(deltaX: -20, phase: .began, at: 0, limit: limit),
            "未达方向门槛时不出方向"
        )
        guard let first = tracker.feed(deltaX: -20, phase: .changed, at: 0.01, limit: limit) else {
            return XCTFail("累加到 40pt 应锁定方向")
        }
        XCTAssertEqual(first.side, .right)
        XCTAssertEqual(first.offset, -40, accuracy: 0.001)
        XCTAssertFalse(first.commits, "触控板有 .ended，提交不该发生在中途帧")

        guard let next = tracker.feed(deltaX: -60, phase: .changed, at: 0.02, limit: limit) else {
            return XCTFail("方向锁定后应持续输出跟手帧")
        }
        XCTAssertEqual(next.offset, -100, accuracy: 0.001, "位移跟手：随累加量线性推进")
        XCTAssertEqual(next.side, .right, "方向一旦锁定就不因抖动回头")
    }

    func testFinishCommitsOnlyPastThreshold() {
        var tracker = DrawerPageScrollTracker()
        _ = tracker.feed(deltaX: -120, phase: .began, at: 0, limit: limit)
        XCTAssertEqual(tracker.finish(at: 0.03, limit: limit), .right, "位移 120 > 90 → 落位")

        var short = DrawerPageScrollTracker()
        _ = short.feed(deltaX: -50, phase: .began, at: 5, limit: limit)
        XCTAssertNil(short.finish(at: 5.02, limit: limit), "没到落位阈值应弹回")
    }

    func testVerticalScrollNeverLocks() {
        var tracker = DrawerPageScrollTracker()
        for index in 0..<40 {
            let phase: NSEvent.Phase = index == 0 ? .began : .changed
            XCTAssertNil(
                tracker.feed(deltaX: 6, deltaY: 60, phase: phase, at: Double(index) * 0.01, limit: limit),
                "纵向为主的滚动不得切页（横向共 240pt 已越过方向门槛）"
            )
        }
        XCTAssertNil(tracker.finish(at: 1, limit: limit))
    }

    func testDirectionReversalRestartsAndReLocks() {
        var tracker = DrawerPageScrollTracker()
        XCTAssertEqual(tracker.feed(deltaX: -60, phase: .began, at: 0, limit: limit)?.side, .right)
        // 往回划：重新起算并改锁另一侧（+80 单独越线 → 左侧页）。
        guard let reversed = tracker.feed(deltaX: 80, phase: .changed, at: 0.01, limit: limit) else {
            return XCTFail("反向累加应改锁另一侧")
        }
        XCTAssertEqual(reversed.side, .left)
        XCTAssertEqual(reversed.offset, 80, accuracy: 0.001)
    }

    func testCooldownBlocksTheNextGesture() {
        var tracker = DrawerPageScrollTracker()
        _ = tracker.feed(deltaX: -120, phase: .began, at: 10, limit: limit)
        let committedAt: TimeInterval = 10.05
        XCTAssertEqual(tracker.finish(at: committedAt, limit: limit), .right)
        // 冷却窗口内的下一次轻扫：一帧都不认（一次猛扫的尾巴不得连翻数页）。
        XCTAssertNil(tracker.feed(deltaX: -200, phase: .began, at: committedAt + 0.05, limit: limit))
        XCTAssertNil(tracker.finish(at: committedAt + 0.07, limit: limit))
        // 冷却过后重新放行。
        let later = committedAt + DrawerPageSwipe.cooldown + 0.01
        XCTAssertNotNil(tracker.feed(deltaX: -60, phase: .began, at: later, limit: limit))
    }

    func testOneGestureCommitsAtMostOnePage() {
        var tracker = DrawerPageScrollTracker()
        var followFrames = 0
        // 一次超长慢扫（累加 2000pt）：中途只出位移，不出第二次提交。
        for index in 0..<40 {
            let phase: NSEvent.Phase = index == 0 ? .began : .changed
            if let frame = tracker.feed(deltaX: -50, phase: phase, at: Double(index) * 0.01, limit: limit) {
                followFrames += 1
                XCTAssertFalse(frame.commits, "有手势边界时提交只发生在 finish")
            }
        }
        XCTAssertGreaterThan(followFrames, 1, "跟手帧应持续输出")
        XCTAssertEqual(tracker.finish(at: 0.4, limit: limit), .right)
        // 同一手势内再 finish：已清理，不会翻第二页。
        XCTAssertNil(tracker.finish(at: 0.41, limit: limit))
    }

    // MARK: 触控板累加器（无手势边界）

    func testPhaseLessDevicesCommitInFrame() {
        var tracker = DrawerPageScrollTracker()
        // Magic Mouse / 传统滚轮：phase 恒为空，等不到 .ended，只能越线即提交。
        let frame = tracker.feed(deltaX: -100, phase: [], at: 20, limit: limit)
        XCTAssertEqual(frame?.side, .right)
        XCTAssertEqual(frame?.commits, true)
        // 提交后立刻进入冷却。
        XCTAssertNil(tracker.feed(deltaX: -300, phase: [], at: 20.1, limit: limit))
        let afterCooldown = tracker.feed(
            deltaX: -100,
            phase: [],
            at: 20 + DrawerPageSwipe.cooldown + 0.01,
            limit: limit
        )
        XCTAssertEqual(afterCooldown?.commits, true)
    }

    func testPhaseLessDeviceStillNeedsDominance() {
        var tracker = DrawerPageScrollTracker()
        XCTAssertNil(tracker.feed(deltaX: -200, deltaY: 900, phase: [], at: 0, limit: limit))
    }

    func testResetDropsPartialAccumulationAndUnlock() {
        var tracker = DrawerPageScrollTracker()
        XCTAssertEqual(tracker.feed(deltaX: -60, phase: .began, at: 30, limit: limit)?.side, .right)
        tracker.reset()
        XCTAssertEqual(tracker.accumulatedX, 0)
        XCTAssertEqual(tracker.accumulatedY, 0)
        XCTAssertNil(tracker.lockedSide)
        // 光标移到块上时丢弃已累加的部分：下次从零起算，不会"攒够就翻"。
        XCTAssertNil(tracker.feed(deltaX: -35, phase: .changed, at: 30.05, limit: limit))
    }

    // MARK: 相邻页解析（按显示序列，不比索引大小）

    func testNeighborPageWalksBothDirections() {
        let pages = [-1, 0, 1, 2]
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: -1, side: .left), nil)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: -1, side: .right), 0)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: 1, side: .left), 0)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: 1, side: .right), 2)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: 2, side: .right), nil)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: 2, side: .left), 1)
    }

    func testNeighborPageFollowsUserOrderNotIndex() {
        // 胶囊拖动排序后序列可以不单调：相邻一律按数组位置取。
        let pages = [-1, -2, 0, 1, 2, 3, 4]
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: -1, side: .right), -2)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: -2, side: .left), -1)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: 0, side: .left), -2)
        XCTAssertEqual(LayoutModel.neighborPage(in: pages, active: 4, side: .right), nil)
    }

    func testNeighborPageOnSinglePageIsAlwaysNil() {
        XCTAssertNil(LayoutModel.neighborPage(in: [0], active: 0, side: .left))
        XCTAssertNil(LayoutModel.neighborPage(in: [0], active: 0, side: .right))
    }
}
