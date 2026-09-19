import Foundation
import NotchCenterKit
import XCTest
@testable import ClipboardHistoryPlugin

/// 悬浮预览回归（决策记录 2026-09-20-clipboard-hover-preview）：
/// 计时语义（停稳才出、浮现后跟随、换行重计时、超容差重计时、离开即收）
/// 与卡片摆放几何（翻转、夹紧）。
///
/// 真实 hover 事件、Retina 观感、与长按浮窗/角标按钮的实际叠放覆盖不到，那几项
/// 必须在真机核对——本套件只锁"能被断言的那部分"。
@MainActor
final class ClipboardHoverPreviewTests: XCTestCase {
    private func entry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(text: text)
    }

    /// 睡眠略长于注入的 dwell，避免调度抖动导致的偶发红。
    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: 计时

    func testHoverDoesNotShowBeforeDwellElapses() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(150))
        let target = entry("hello")
        model.hover(entry: target, at: CGPoint(x: 10, y: 10))
        await wait(60)
        XCTAssertNil(model.shown, "停稳时间没到就不该浮现")
    }

    func testHoverShowsAfterDwellElapses() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(80))
        let target = entry("hello")
        model.hover(entry: target, at: CGPoint(x: 10, y: 20))
        await wait(160)
        XCTAssertEqual(model.shown?.entry.id, target.id)
        XCTAssertEqual(model.shown?.cursor, CGPoint(x: 10, y: 20))
    }

    /// 已浮现后同行内移动只跟随重定位，不重新计时——手抖一下不该让卡片消失。
    func testHoverFollowsCursorAfterShownWithoutHiding() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(80))
        let target = entry("hello")
        model.hover(entry: target, at: CGPoint(x: 10, y: 20))
        await wait(160)
        XCTAssertNotNil(model.shown)

        model.hover(entry: target, at: CGPoint(x: 90, y: 60))
        XCTAssertEqual(model.shown?.cursor, CGPoint(x: 90, y: 60), "浮现后应即时跟随")
        await wait(40)
        XCTAssertEqual(model.shown?.entry.id, target.id, "跟随不得触发一次收起再浮现")
    }

    /// 行内位移超过容差 → 重新计时（"停稳才出"的语义）。
    func testHoverMovementBeyondToleranceRestartsDwell() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(150))
        let target = entry("hello")
        model.hover(entry: target, at: CGPoint(x: 0, y: 0))
        await wait(80)
        model.hover(entry: target, at: CGPoint(x: 40, y: 0))
        await wait(80)
        XCTAssertNil(model.shown, "位移超容差后应重新计时，80ms 还不够")
        await wait(120)
        XCTAssertEqual(model.shown?.cursor, CGPoint(x: 40, y: 0))
    }

    /// 容差内的抖动不重置计时——否则鼠标永远停不稳，卡片永远出不来。
    func testHoverJitterWithinToleranceDoesNotRestartDwell() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(120))
        let target = entry("hello")
        model.hover(entry: target, at: CGPoint(x: 0, y: 0))
        await wait(50)
        model.hover(entry: target, at: CGPoint(x: 1, y: 1))
        await wait(50)
        model.hover(entry: target, at: CGPoint(x: 0, y: 2))
        await wait(90)
        XCTAssertEqual(model.shown?.entry.id, target.id, "容差内抖动不该让计时一直重新开始")
    }

    /// 换行 → 作废旧目标并重新计时，且旧目标不会在计时到期后冒出来。
    func testHoverSwitchingEntryDropsPreviousCandidate() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(150))
        let first = entry("first")
        let second = entry("second")
        model.hover(entry: first, at: .zero)
        await wait(80)
        model.hover(entry: second, at: CGPoint(x: 5, y: 5))
        XCTAssertNil(model.shown, "换行即刻清空已浮现结果")
        await wait(90)
        XCTAssertNil(model.shown, "第二行自己的计时还没到")
        await wait(110)
        XCTAssertEqual(model.shown?.entry.id, second.id, "到点的必须是新行，不是被作废的旧行")
    }

    func testEndHidesShownPreviewImmediately() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(60))
        let target = entry("hello")
        model.hover(entry: target, at: .zero)
        await wait(140)
        XCTAssertNotNil(model.shown)
        model.end(entry: target)
        XCTAssertNil(model.shown)
    }

    func testEndCancelsPendingDwell() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(150))
        let target = entry("hello")
        model.hover(entry: target, at: .zero)
        await wait(50)
        model.end(entry: target)
        await wait(200)
        XCTAssertNil(model.shown, "离开后计时必须作废，不能补浮现")
    }

    /// 相邻行的进入/离开会交叉投递，非当前目标的通知必须被忽略。
    func testEndForUnrelatedEntryIsIgnored() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(60))
        let target = entry("hello")
        model.hover(entry: target, at: .zero)
        await wait(140)
        model.end(entry: entry("someone else"))
        XCTAssertEqual(model.shown?.entry.id, target.id)
    }

    func testCancelClearsBothPendingAndShown() async {
        let model = ClipboardHoverPreviewModel(dwell: .milliseconds(150))
        model.hover(entry: entry("pending"), at: .zero)
        model.cancel()
        await wait(200)
        XCTAssertNil(model.shown, "cancel 之后连待浮现的候选都要作废")

        model.hover(entry: entry("shown"), at: .zero)
        await wait(200)
        XCTAssertNotNil(model.shown)
        model.cancel()
        XCTAssertNil(model.shown)
        XCTAssertNil(model.shown?.cursor)
    }

    // MARK: 摆放几何

    func testOriginSitsBelowRightOfCursorWhenThereIsRoom() {
        let origin = ClipboardHoverCardGeometry.origin(
            cursor: CGPoint(x: 100, y: 100),
            cardSize: CGSize(width: 200, height: 120),
            containerSize: CGSize(width: 600, height: 400)
        )
        XCTAssertEqual(origin, CGPoint(
            x: 100 + ClipboardHoverCardGeometry.cursorOffset.width,
            y: 100 + ClipboardHoverCardGeometry.cursorOffset.height
        ))
    }

    func testOriginFlipsToLeftAndUpNearEdges() {
        let card = CGSize(width: 200, height: 120)
        let container = CGSize(width: 600, height: 400)
        let origin = ClipboardHoverCardGeometry.origin(
            cursor: CGPoint(x: 580, y: 390),
            cardSize: card,
            containerSize: container
        )
        XCTAssertLessThan(origin.x, 580, "右边界应翻到光标左侧")
        XCTAssertLessThan(origin.y, 390, "下边界应翻到光标上方")
        XCTAssertGreaterThanOrEqual(origin.x, 0)
        XCTAssertGreaterThanOrEqual(origin.y, 0)
    }

    /// 容器比卡片还小时翻转也放不下，只能夹住——宁可裁角也不能越出块矩形。
    func testOriginClampsInsideContainerWhenTooSmall() {
        let origin = ClipboardHoverCardGeometry.origin(
            cursor: CGPoint(x: 50, y: 50),
            cardSize: CGSize(width: 240, height: 160),
            containerSize: CGSize(width: 120, height: 90),
            inset: 6
        )
        XCTAssertEqual(origin, CGPoint(x: 6, y: 6))
    }

    func testCardSizeIsClampedToContainer() {
        let roomy = ClipboardHoverMetrics.cardSize(in: CGSize(width: 600, height: 400))
        XCTAssertEqual(roomy, ClipboardHoverMetrics.idealSize)

        let tight = ClipboardHoverMetrics.cardSize(in: CGSize(width: 120, height: 90))
        XCTAssertLessThan(tight.width, ClipboardHoverMetrics.idealSize.width)
        XCTAssertLessThan(tight.height, ClipboardHoverMetrics.idealSize.height)
        XCTAssertEqual(tight.width, 120 - ClipboardHoverMetrics.margin * 2)
    }
}
