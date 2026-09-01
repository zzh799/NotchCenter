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
        // commitThreshold 与 shouldCommit 同一条公式。
        XCTAssertEqual(DrawerPageSwipe.commitThreshold(limit: limit), 90)
        XCTAssertEqual(DrawerPageSwipe.commitThreshold(limit: 200), 56, accuracy: 0.001)
    }

    // MARK: 速度判据（较强速度的滑动也能触发翻页，不只看滑动距离）

    func testShouldCommitIgnoresSlowVelocity() {
        // 位移没到门槛、速度也不够猛：慢推不落位（刻意滑到一半停住就该弹回）。
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: 60, limit: limit, velocity: -700))
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: -60, limit: limit, velocity: 700))
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: 60, limit: limit, velocity: 700))
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: -60, limit: limit, velocity: -700))
    }

    func testShouldCommitAcceptsStrongAlignedVelocity() {
        // 位移不足但松手速度够猛且同向：一甩就翻页。
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(offset: -60, limit: limit, velocity: -800))
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(offset: 60, limit: limit, velocity: 1_500))
    }

    func testShouldCommitRequiresVelocityAlignedWithOffset() {
        // 往回甩的加速度不落位：位移向前、速度向后 = 用户反悔了。
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: 60, limit: limit, velocity: -1_500))
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: -60, limit: limit, velocity: 1_500))
        // 位移为零（方向都没锁过）时速度再猛也不算。
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(offset: 0, limit: limit, velocity: -3_000))
    }

    func testShouldCommitUsesPredictedEndTranslation() {
        // 拖拽通路：松手瞬间的强速度经 DragGesture 的预测终点折算成位移。
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(
            offset: 50, limit: limit, predictedOffset: 95
        ))
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(
            offset: 50, limit: limit, predictedOffset: 89
        ))
        // 预测终点与当前位移反向（回拉刹车）：不落位。
        XCTAssertFalse(DrawerPageSwipe.shouldCommit(
            offset: 50, limit: limit, predictedOffset: -200
        ))
        // 位移已够门槛时预测方向无关紧要（距离判据先成立）。
        XCTAssertTrue(DrawerPageSwipe.shouldCommit(
            offset: -95, limit: limit, predictedOffset: 200
        ))
    }

    // MARK: 滑动进度（面板尺寸插值与胶囊高亮共用的唯一进度）

    func testProgressIsOffsetOverTravel() {
        // 进度 = |位移| / |落位全程|；两侧方向一致。
        XCTAssertEqual(DrawerPageSwipe.progress(offset: -500, gap: 1_000), 0.5, accuracy: 0.001)
        XCTAssertEqual(DrawerPageSwipe.progress(offset: 500, gap: 1_000), 0.5, accuracy: 0.001)
        // 左滑的 gap 为负（= -目标页宽），取绝对值同样成立。
        XCTAssertEqual(DrawerPageSwipe.progress(offset: 300, gap: -600), 0.5, accuracy: 0.001)
        XCTAssertEqual(DrawerPageSwipe.progress(offset: 0, gap: -600), 0, "没滑就是 0（往回滑进度归零、尺寸恢复）")
        // 越界（过度拖拽）夹紧到 1。
        XCTAssertEqual(DrawerPageSwipe.progress(offset: -2_000, gap: 1_000), 1, accuracy: 0.001)
        XCTAssertEqual(DrawerPageSwipe.progress(offset: 700, gap: 200), 1, accuracy: 0.001)
        XCTAssertEqual(DrawerPageSwipe.progress(offset: -3, gap: 4), 0.75, accuracy: 0.001)
        // 没有落位全程可参照（gap 为 0）时进度恒为 0。
        XCTAssertEqual(DrawerPageSwipe.progress(offset: 100, gap: 0), 0)
    }

    func testInterpolatedSizeIsLinearBetweenEndpoints() {
        let start = CGSize(width: 1_000, height: 300)
        let target = CGSize(width: 400, height: 600)
        // 中点 = 两侧平均；终点 = 目标页自身所需尺寸。
        XCTAssertEqual(
            DrawerPageSwipe.interpolatedSize(from: start, to: target, progress: 0.5),
            CGSize(width: 700, height: 450)
        )
        XCTAssertEqual(
            DrawerPageSwipe.interpolatedSize(from: start, to: target, progress: 1),
            target
        )
        XCTAssertEqual(
            DrawerPageSwipe.interpolatedSize(from: start, to: target, progress: 0),
            start,
            "往回滑进度归零 = 恢复到本页尺寸"
        )
        // 两页尺寸相同时插值是恒等变换（面板不该有可见抖动）。
        let same = CGSize(width: 800, height: 400)
        XCTAssertEqual(
            DrawerPageSwipe.interpolatedSize(from: same, to: same, progress: 0.73),
            same
        )
    }

    // MARK: 速度估计（样本窗口差商）

    func testVelocityEstimateUsesRecentWindow() {
        let now: TimeInterval = 1.0
        typealias Sample = (time: TimeInterval, x: CGFloat)
        let old: Sample = (time: 0.5, x: -50)
        // 窗口外（> 0.12s 前）的样本不参与：只按近段差商。
        let recent: [Sample] = [(time: 0.90, x: -80), (time: 0.96, x: -170)]
        XCTAssertEqual(
            DrawerPageSwipe.velocityEstimate(from: [old] + recent, at: now),
            -1_500,
            accuracy: 1.0,
            "(-170 - -80) / (0.96 - 0.90) = -1500 pt/s"
        )
    }

    func testVelocityEstimateNeedsTwoSamples() {
        XCTAssertEqual(DrawerPageSwipe.velocityEstimate(from: [], at: 1), 0)
        XCTAssertEqual(
            DrawerPageSwipe.velocityEstimate(from: [(time: 0.9, x: -80)], at: 1),
            0,
            "单样本无差商可言"
        )
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

    // MARK: 落位后的预览层撤除

    /// 构造一个处于落位终点（offset = arrivalOffset）的会话快照。
    private func makeSession(
        side: DrawerPageSide,
        gridWidth: CGFloat,
        targetWidth: CGFloat
    ) -> PanelUIState.DrawerSwipe {
        let originSize = CGSize(width: gridWidth, height: 500)
        let targetSize = CGSize(width: targetWidth, height: 500)
        let gap = DrawerPageSwipe.gap(side: side, gridWidth: gridWidth, targetWidth: targetWidth)
        return PanelUIState.DrawerSwipe(
            originPage: 0,
            side: side,
            targetPage: 1,
            elements: [],
            contentSize: targetSize,
            targetWindowSize: targetSize,
            leftColumn: 0,
            gap: gap,
            startContentSize: originSize,
            startWindowSize: originSize,
            limit: abs(gap),
            offset: DrawerPageSwipe.arrivalOffset(gap: gap)
        )
    }

    func testLandedPreviewPokesBackIntoClipOnlyWhenTargetIsWider() {
        // 落位后 offset=0，预览层横坐标 = gap = 原点页宽：目标页更宽时会探回
        // 已变宽的裁剪框内（重影条带），因此视图必须按 isLanded 就地撤层，
        // 不能赌"落位后它在屏外"。
        func landed(_ session: PanelUIState.DrawerSwipe) -> PanelUIState.DrawerSwipe {
            var s = session
            s.offset = 0
            s.isLanded = true
            return s
        }
        let wider = landed(makeSession(side: .right, gridWidth: 600, targetWidth: 1_000))
        XCTAssertLessThan(
            wider.offset + wider.gap,
            wider.contentSize.width,
            "宽目标页：落位后预览层左缘落在裁剪框内（重影条带存在）"
        )
        let narrower = landed(makeSession(side: .right, gridWidth: 1_000, targetWidth: 600))
        XCTAssertGreaterThanOrEqual(
            narrower.offset + narrower.gap,
            narrower.contentSize.width,
            "目标页不宽于原页：预览层完全在右缘外（屏外假设成立的唯一情形）"
        )
        let leftward = landed(makeSession(side: .left, gridWidth: 1_000, targetWidth: 600))
        XCTAssertLessThanOrEqual(
            leftward.offset + leftward.gap + leftward.contentSize.width,
            0,
            "左滑落位：预览层整体在左缘外"
        )
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

    func testFastFlickCommitsViaVelocityWhileDistanceIsShort() {
        // 一甩：累加 -80pt（< 落位门槛 90），但 80pt 在 0.04s 内完成 =
        // 1000pt/s > 800——速度快照样翻页（"较强速度的滑动能触发滑到
        // 目的页，而不只看滑动距离"）。
        var tracker = DrawerPageScrollTracker()
        _ = tracker.feed(deltaX: -40, phase: .began, at: 0, limit: limit)
        let frame = tracker.feed(deltaX: -40, phase: .changed, at: 0.04, limit: limit)
        XCTAssertEqual(frame?.offset ?? 0, -80, accuracy: 0.001, "位移本身没到门槛")
        XCTAssertFalse(frame?.commits ?? true, "触控板有边界，中途帧不就地提交")
        XCTAssertEqual(tracker.finish(at: 0.05, limit: limit), .right, "速度够猛 → 落位")
    }

    func testSlowDragDoesNotCommitViaVelocity() {
        // 同样的 80pt 用 0.3s 推完（266pt/s < 800）：速度与位移都不够 → 弹回。
        var tracker = DrawerPageScrollTracker()
        _ = tracker.feed(deltaX: -30, phase: .began, at: 10, limit: limit)
        _ = tracker.feed(deltaX: -30, phase: .changed, at: 10.15, limit: limit)
        _ = tracker.feed(deltaX: -20, phase: .changed, at: 10.3, limit: limit)
        XCTAssertNil(tracker.finish(at: 10.32, limit: limit))
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

    func testDirectionReversalFlipsPastOriginWithDeadBand() {
        var tracker = DrawerPageScrollTracker()
        XCTAssertEqual(tracker.feed(deltaX: -60, phase: .began, at: 0, limit: limit)?.side, .right)
        // 反手但条带没过原点（累加仍为负）：方向不变，位移跟手回收。
        let partial = tracker.feed(deltaX: 20, phase: .changed, at: 0.01, limit: limit)
        XCTAssertEqual(partial?.side, .right, "原点死区内不换向")
        XCTAssertEqual(partial?.offset ?? 0, -40, accuracy: 0.001,
                       "位移 = 手势累计（连续、不因反手重起）")
        // 越过原点死区（+8 外）：改锁另一侧（立刻反悔）。
        guard let crossed = tracker.feed(deltaX: 50, phase: .changed, at: 0.02, limit: limit) else {
            return XCTFail("越过原点应换向并继续出帧")
        }
        XCTAssertEqual(crossed.side, .left, "越过原点（死区外）改锁另一侧")
        XCTAssertEqual(crossed.offset, 10, accuracy: 0.001, "位移 = 手势累计（原点为 0）")
    }

    func testReversalJitterAroundOriginStaysLocked() {
        var tracker = DrawerPageScrollTracker()
        _ = tracker.feed(deltaX: -60, phase: .began, at: 0, limit: limit)
        // 原点附近 ±7pt 抖动：不换向（死区吸收），位移跟手微动。
        XCTAssertEqual(tracker.feed(deltaX: 67, phase: .changed, at: 0.01, limit: limit)?.side, .right)
        XCTAssertEqual(tracker.feed(deltaX: -13, phase: .changed, at: 0.02, limit: limit)?.side, .right)
    }

    func testReversalAcrossOriginTwiceFlipsBackAndCommitsOriginalSide() {
        // A→B（-140）→ 反手越过原点（+60，换到 C 侧）→ 再反回 B 侧（-140）：
        // 方向随条带位移往返，松手落位回原目标侧（旧实现会卡在换绑后的另一侧）。
        var tracker = DrawerPageScrollTracker()
        XCTAssertEqual(tracker.feed(deltaX: -140, phase: .began, at: 0, limit: limit)?.side, .right)
        XCTAssertEqual(tracker.feed(deltaX: 200, phase: .changed, at: 0.01, limit: limit)?.side, .left, "越过原点换到左向")
        XCTAssertEqual(tracker.feed(deltaX: -200, phase: .changed, at: 0.02, limit: limit)?.side, .right, "再越过原点换回右向")
        // 松手：位移 -140 ≥ 门槛 90 → 落位回 B 侧。
        XCTAssertEqual(tracker.finish(at: 0.03, limit: limit), .right)
    }

    // MARK: 反手换向（原点穿越死区）

    func testReversedSideDeadBand() {
        // 死区内（|offset| ≤ flipDeadBand）不换；越过才换到另一侧。
        XCTAssertNil(DrawerPageSwipe.reversedSide(current: .right, offset: 8))
        XCTAssertEqual(DrawerPageSwipe.reversedSide(current: .right, offset: 9), .left)
        XCTAssertNil(DrawerPageSwipe.reversedSide(current: .right, offset: -30))
        XCTAssertNil(DrawerPageSwipe.reversedSide(current: .left, offset: 30))
        XCTAssertEqual(DrawerPageSwipe.reversedSide(current: .left, offset: -9), .right)
        XCTAssertNil(DrawerPageSwipe.reversedSide(current: .left, offset: 0))
    }

    func testSideForOffsetIsStripPosition() {
        // 条带位移的符号 = 意图方向；0 = 在原点 = 无意图（提交门据此拒绝）。
        XCTAssertEqual(DrawerPageSwipe.side(forOffset: -1), .right)
        XCTAssertEqual(DrawerPageSwipe.side(forOffset: 1), .left)
        XCTAssertNil(DrawerPageSwipe.side(forOffset: 0))
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
