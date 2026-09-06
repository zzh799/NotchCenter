import XCTest
@testable import NotchCenter

/// 滑动切页自驱弹簧（`DrawerSwipeSpringDriver`）：解析解的数学性质、收敛拍
/// 触发与身份守卫。时钟与调度全部注入——测试手动步进假时钟、逐帧调
/// `tick()`，与真机 Timer 解耦。
@MainActor
final class DrawerSwipeSpringDriverTests: XCTestCase {
    /// 与 `DrawerAnimation.spring` 同参数：response 0.3 / damping 0.86。
    private let response = 0.3
    private let damping = 0.86

    private var omegaN: Double { 2 * .pi / response }

    /// 可步进假时钟。
    private final class FakeClock {
        var now: TimeInterval = 0
        func advance(_ dt: TimeInterval) { now += dt }
    }

    private func makeDriver(clock: FakeClock) -> DrawerSwipeSpringDriver {
        DrawerSwipeSpringDriver(
            response: response,
            dampingFraction: damping,
            now: { [clock] in clock.now },
            schedule: { _ in {} }
        )
    }

    // MARK: 解析解

    func testSampleStartsExactlyAtInitialState() {
        let (x, v) = DrawerSwipeSpringDriver.sample(
            x0: -800, v0: -120, target: -1_032, omegaN: omegaN, zeta: damping, at: 0
        )
        XCTAssertEqual(x, -800, accuracy: 0.0001)
        XCTAssertEqual(v, -120, accuracy: 0.0001)
    }

    func testSampleConvergesToTarget() {
        // 包络 e^(-ζω_n t)：0.5s 后 1000pt 振幅衰减到 0.5pt 内、速度低于
        // 8pt/s——与"spring(0.3/0.86) 视觉收敛约 0.5s"同一量级，收敛拍不会早到。
        let (x, v) = DrawerSwipeSpringDriver.sample(
            x0: 0, v0: 0, target: -1_000, omegaN: omegaN, zeta: damping, at: 0.5
        )
        XCTAssertEqual(x, -1_000, accuracy: 0.5)
        XCTAssertLessThan(abs(v), 8)
    }

    func testSampleIsAFlowSplitStepsMatchDirectStep() {
        // 解析解是流：从 (x0, v0) 走到 t，与先走到 t1、再以 (x1, v1) 为初值走
        // t - t1，结果必须一致（无积分漂移；Timer 抖动不影响表现值正确性）。
        let direct = DrawerSwipeSpringDriver.sample(
            x0: -100, v0: -2_000, target: -1_032, omegaN: omegaN, zeta: damping, at: 0.37
        )
        let mid = DrawerSwipeSpringDriver.sample(
            x0: -100, v0: -2_000, target: -1_032, omegaN: omegaN, zeta: damping, at: 0.1
        )
        let stepped = DrawerSwipeSpringDriver.sample(
            x0: mid.x, v0: mid.v, target: -1_032, omegaN: omegaN, zeta: damping, at: 0.27
        )
        XCTAssertEqual(direct.x, stepped.x, accuracy: 0.0001)
        XCTAssertEqual(direct.v, stepped.v, accuracy: 0.0001)
    }

    // MARK: 生命周期

    func testDriverDeliversFramesThenSettlesExactlyOnce() {
        let clock = FakeClock()
        var frames: [CGFloat] = []
        var settles = 0
        let driver = makeDriver(clock: clock)
        driver.run(
            from: 0, to: -1_032, token: UUID(),
            onFrame: { frames.append($0) },
            onSettle: { settles += 1 }
        )
        XCTAssertTrue(driver.isRunning)

        // 中途帧：表现值在起点与目标之间、单调逼近。
        clock.advance(0.1)
        driver.tick()
        clock.advance(0.1)
        driver.tick()
        XCTAssertEqual(frames.count, 2)
        XCTAssertLessThan(frames[0], 0)
        XCTAssertLessThan(frames[1], frames[0], "向负目标收敛应单调推进")
        XCTAssertGreaterThan(frames[1], -1_032, "未收敛不得贴死目标")

        // 到收敛：精确贴目标 + 收敛拍恰好一次，随后停表。
        clock.advance(0.6)
        driver.tick()
        XCTAssertEqual(frames.last, -1_032, "收敛帧必须精确等于目标（像素重合交接的前提）")
        XCTAssertEqual(settles, 1)
        XCTAssertFalse(driver.isRunning)

        // 停表后 tick 空跑。
        driver.tick()
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(settles, 1)
    }

    func testDriverSettleRespectsMaxDurationCap() {
        let clock = FakeClock()
        var settles = 0
        var lastFrame: CGFloat = 0
        let driver = makeDriver(clock: clock)
        driver.run(
            from: 0, to: -5_000_000, token: UUID(),
            onFrame: { lastFrame = $0 },
            onSettle: { settles += 1 }
        )
        clock.advance(5)
        driver.tick()
        XCTAssertEqual(settles, 1, "超长行程由安全上限强制收敛，不得悬挂")
        XCTAssertEqual(lastFrame, -5_000_000)
        XCTAssertFalse(driver.isRunning)
    }

    func testDriverCancelStopsFramesAndSettle() {
        let clock = FakeClock()
        var frames: [CGFloat] = []
        var settles = 0
        let driver = makeDriver(clock: clock)
        driver.run(
            from: 0, to: -1_000, token: UUID(),
            onFrame: { frames.append($0) },
            onSettle: { settles += 1 }
        )
        clock.advance(0.05)
        driver.tick()
        XCTAssertEqual(frames.count, 1)

        // 接管（grab）= 取消：停在最后写入的表现值，帧与收敛拍都不再送达。
        driver.cancel()
        clock.advance(1)
        driver.tick()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(settles, 0)
        XCTAssertFalse(driver.isRunning)
    }

    func testDriverRestartReplacesCallbacks() {
        let clock = FakeClock()
        var firstFrames = 0
        var secondFrames: [CGFloat] = []
        var settles = 0
        let driver = makeDriver(clock: clock)
        driver.run(
            from: 0, to: -1_000, token: UUID(),
            onFrame: { _ in firstFrames += 1 },
            onSettle: { settles += 1 }
        )
        // 二次 run（新会话/新去向）替换回调与状态，旧回调作废。
        driver.run(
            from: -500, to: 0, token: UUID(),
            onFrame: { secondFrames.append($0) },
            onSettle: { settles += 1 }
        )
        clock.advance(0.1)
        driver.tick()
        clock.advance(0.6)
        driver.tick()
        XCTAssertEqual(firstFrames, 0, "旧回调不得再收到帧")
        XCTAssertEqual(secondFrames.count, 2)
        XCTAssertEqual(settles, 1, "只有新一次运行收敛")
        XCTAssertEqual(secondFrames.last, 0)
    }
}
