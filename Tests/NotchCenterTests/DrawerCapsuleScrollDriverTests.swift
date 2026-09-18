import XCTest
@testable import NotchCenter

/// 胶囊行边缘自动滚驱动器（`DrawerCapsuleScrollDriver`）：步进速率、端点停表、
/// 迟到 tick 不跳步。时钟与调度全部注入——测试手动步进假时钟、逐帧调 `tick()`，
/// 与真机 Timer 解耦（与 `DrawerSwipeSpringDriverTests` 同一风格）。
@MainActor
final class DrawerCapsuleScrollDriverTests: XCTestCase {
    /// 可步进假时钟。
    private final class FakeClock {
        var now: TimeInterval = 0
        func advance(_ dt: TimeInterval) { now += dt }
    }

    /// 偏移的宿主替身（生产是 `uiState.drawerCapsuleScrollOffset`）。
    private final class OffsetBox {
        var value: CGFloat = 0
    }

    /// 三页、区宽 116 的参照系：行宽 216，偏移余量 = (216 − 116)/2 = 50
    /// （移位域对称 ±50，0 = 行心对齐区心）。
    private let regionLeft: CGFloat = 100
    private let regionWidth: CGFloat = 116
    private let pageCount = 3
    private var extent: CGFloat { DrawerPagePillLayout.scrollExtent(regionWidth: regionWidth, pageCount: pageCount) }

    private func makeEnvironment(
        pointerX: CGFloat,
        box: OffsetBox
    ) -> DrawerCapsuleScrollDriver.Environment {
        DrawerCapsuleScrollDriver.Environment(
            pointerX: pointerX,
            regionLeft: regionLeft,
            regionWidth: regionWidth,
            pageCount: pageCount,
            offset: { box.value },
            apply: { box.value = $0 }
        )
    }

    private func makeDriver(clock: FakeClock) -> DrawerCapsuleScrollDriver {
        DrawerCapsuleScrollDriver(now: { [clock] in clock.now }, schedule: { _ in {} })
    }

    /// 帧间隔取 120Hz（驱动器生产调度同频）。
    private let frame: TimeInterval = 1.0 / 120

    func testEdgePointerRunsWhileMidRegionPointerDoesNot() {
        let clock = FakeClock()
        let box = OffsetBox()
        let driver = makeDriver(clock: clock)

        driver.update(makeEnvironment(pointerX: regionLeft + regionWidth / 2, box: box))
        XCTAssertFalse(driver.isRunning, "区中间的指针不该起滚表")

        driver.update(makeEnvironment(pointerX: regionLeft + regionWidth, box: box))
        XCTAssertTrue(driver.isRunning, "压到区右缘应起滚表")

        driver.update(nil)
        XCTAssertFalse(driver.isRunning, "指针上报 nil（松手）应停表")
    }

    func testTrailingEdgeStepsOffsetForwardAtFullSpeed() {
        let clock = FakeClock()
        let box = OffsetBox()
        let driver = makeDriver(clock: clock)
        driver.update(makeEnvironment(pointerX: regionLeft + regionWidth, box: box))

        clock.advance(frame)
        driver.tick()
        // 满速 420pt/s × 1/120s = 3.5pt。
        XCTAssertEqual(box.value, DrawerPagePillLayout.autoScrollMaxSpeed * CGFloat(frame), accuracy: 0.001)
        XCTAssertEqual(driver.isRunning, true, "还没到端点，继续滚")
    }

    func testLeadingEdgeStepsOffsetBackward() {
        let clock = FakeClock()
        let box = OffsetBox()
        let driver = makeDriver(clock: clock)
        driver.update(makeEnvironment(pointerX: regionLeft, box: box))

        clock.advance(frame)
        driver.tick()
        XCTAssertEqual(box.value, 0 - DrawerPagePillLayout.autoScrollMaxSpeed * CGFloat(frame), accuracy: 0.001)
    }

    func testClampsAtTrailingEndAndStopsTicking() {
        let clock = FakeClock()
        let box = OffsetBox()
        box.value = extent - 1
        let driver = makeDriver(clock: clock)
        driver.update(makeEnvironment(pointerX: regionLeft + regionWidth, box: box))

        clock.advance(frame)
        driver.tick()
        XCTAssertEqual(box.value, extent, "越界值必须被夹到端点")

        clock.advance(frame)
        driver.tick()
        XCTAssertFalse(driver.isRunning, "顶到端点即停表（指针不动时不留空转计时器）")
        XCTAssertEqual(box.value, extent)
    }

    func testClampsAtLeadingEndAndStopsTicking() {
        let clock = FakeClock()
        let box = OffsetBox()
        box.value = -extent + 1
        let driver = makeDriver(clock: clock)
        driver.update(makeEnvironment(pointerX: regionLeft, box: box))

        clock.advance(frame)
        driver.tick()
        XCTAssertEqual(box.value, -extent)

        clock.advance(frame)
        driver.tick()
        XCTAssertFalse(driver.isRunning)
    }

    func testLateTickDoesNotJumpMoreThanOneThirtiethSecond() {
        // 迟到的 tick（长卡顿/休眠唤醒）只按上限步进——否则一帧就能把行甩到端点。
        let clock = FakeClock()
        let box = OffsetBox()
        let driver = makeDriver(clock: clock)
        driver.update(makeEnvironment(pointerX: regionLeft + regionWidth, box: box))

        clock.advance(1.0)
        driver.tick()
        XCTAssertEqual(
            box.value,
            DrawerPagePillLayout.autoScrollMaxSpeed / 30,
            accuracy: 0.001
        )
    }

    func testPointerLeavingBandStopsImmediately() {
        let clock = FakeClock()
        let box = OffsetBox()
        let driver = makeDriver(clock: clock)
        driver.update(makeEnvironment(pointerX: regionLeft + regionWidth, box: box))
        clock.advance(frame)
        driver.tick()
        let afterFirstTick = box.value

        driver.update(makeEnvironment(pointerX: regionLeft + regionWidth / 2, box: box))
        XCTAssertFalse(driver.isRunning)
        clock.advance(frame)
        driver.tick()
        XCTAssertEqual(box.value, afterFirstTick, "停表后 tick 空跑")
    }

    func testNonOverflowingRowNeverScrolls() {
        // 行放得下（区宽 300 > 行宽 216）：即便指针压在边带上也不该动，
        // 且 tick 立刻因"顶在端点"停表。
        let clock = FakeClock()
        let box = OffsetBox()
        let driver = makeDriver(clock: clock)
        driver.update(
            DrawerCapsuleScrollDriver.Environment(
                pointerX: 400,
                regionLeft: 100,
                regionWidth: 300,
                pageCount: pageCount,
                offset: { box.value },
                apply: { box.value = $0 }
            )
        )
        clock.advance(frame)
        driver.tick()
        XCTAssertEqual(box.value, 0)
        XCTAssertFalse(driver.isRunning)
    }
}
