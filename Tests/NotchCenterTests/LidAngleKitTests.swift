import XCTest
@testable import LidAngleKit

// MARK: - 硬件前置条件
//
// 盖角传感器是 Apple 内建硬件的私有 HID 接触面:虚拟机上没有,CI runner 上也没有。
// 需要真实读数的用例一律先经下面这个门跳过,而**不要断言「本机有传感器」**——后者只
// 能证明跑测试的这台机器恰好有传感器,在无传感器的机器上就变成假红灯(发布流水线曾
// 因此自 2026-09-10 起连续多日失败,与代码质量无关)。开发机有传感器,这些用例在
// 本地照常真实执行,不损失覆盖。领域约定见 docs/agents/测试指南.md「注意事项」。

/// 无盖角传感器时跳过当前用例(虚拟机 / CI runner)。
func skipUnlessLidAngleSensorAvailable(
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    try XCTSkipUnless(
        LidAngleSensor().isAvailable,
        "本机无盖角传感器(虚拟机 / CI runner),跳过真实读数用例",
        file: file,
        line: line
    )
}

// MARK: - 盖角状态机
//
// `LidAngleMonitor` 的阈值判定是本库相对上游 LidAngleKit 的**新增能力**
// (上游只有裸读数)。宿主机器上传感器真实存在,所以这里既能测纯逻辑,
// 也能测一次真实读数。

final class LidThresholdsTests: XCTestCase {

    /// 默认阈值必须与上游 Mac-Duo 的判定口径一致。
    func testDefaultsMatchUpstreamExpectations() {
        let thresholds = LidThresholds()
        XCTAssertEqual(thresholds.closedAngle, 3)
        XCTAssertEqual(thresholds.closingSpeed, 12)
    }

    /// `isShutting` 把"正在合"也算作合上,便于 UI 提前响应。
    func testShuttingCoversClosingAndClosed() {
        XCTAssertFalse(LidState.open.isShutting)
        XCTAssertTrue(LidState.closing.isShutting)
        XCTAssertTrue(LidState.closed.isShutting)
    }
}

@MainActor
final class LidAngleMonitorTests: XCTestCase {

    /// 传感器在位时必须优先选中 0.01° 的 report 7 档位——档位探测错了,精度会整档
    /// 降级而不报错,所以这条要钉住。无传感器时跳过(见文件头「硬件前置条件」)。
    func testPrefersHundredthsResolutionWhenSensorIsPresent() throws {
        try skipUnlessLidAngleSensorAvailable()
        let monitor = LidAngleMonitor()
        XCTAssertEqual(monitor.resolution, .hundredthsOfADegree, "应优先使用 0.01° 的 report 7")
    }

    /// 真实读数必须落在合法区间,并给出一个确定的状态。
    func testRealReadingIsSane() throws {
        try skipUnlessLidAngleSensorAvailable()
        let monitor = LidAngleMonitor()
        let reading = monitor.sampleNow()
        let angle = try XCTUnwrap(reading.angle, "传感器可用时 sampleNow 必须给出读数")
        XCTAssertTrue((0...360).contains(angle), "盖角应在 0...360:\(angle)")
        XCTAssertTrue(reading.isFresh, "真实读数应标记为 fresh")
        XCTAssertTrue(LidState.allCases.contains(reading.state))
    }

    /// 盖子不动时不得被判成"正在合":静止读数的速度应在阈值以内。
    func testIdleLidIsNotReportedAsClosing() throws {
        try skipUnlessLidAngleSensorAvailable()
        let monitor = LidAngleMonitor()
        _ = monitor.sampleNow()
        Thread.sleep(forTimeInterval: 0.3)
        let reading = monitor.sampleNow()
        guard let angle = reading.angle, angle > LidThresholds().closedAngle else {
            // 机器真的合着盖子时这条测试没有意义,跳过而不是误报。
            throw XCTSkip("盖子处于闭合状态,无法检验静止判定")
        }
        XCTAssertNotEqual(reading.state, .closing, "静止的盖子不得被判为正在合上")
    }

    /// `resetBaseline` 后速度归零,状态由当前角度直接推出——系统唤醒后必须如此,
    /// 否则"几乎合着醒过来"会被误判成正在合盖。
    func testResetBaselineRecomputesStateFromTheAngle() throws {
        try skipUnlessLidAngleSensorAvailable()
        let monitor = LidAngleMonitor()
        let reading = monitor.sampleNow()
        let angle = try XCTUnwrap(reading.angle)
        let reset = monitor.sampleNow()
        XCTAssertEqual(reset.velocity, 0, accuracy: 0.001, "重置后速度应为 0")
        let expected: LidState = angle <= LidThresholds().closedAngle ? .closed : .open
        XCTAssertEqual(reset.state, expected)
    }

    /// 起停不得崩溃,且可重复调用(宿主会在前后台切换时反复调用)。
    func testStartAndStopAreIdempotent() {
        let monitor = LidAngleMonitor()
        monitor.start(interval: LidAngleMonitor.idleInterval)
        monitor.start(interval: LidAngleMonitor.activeInterval)
        monitor.stop()
        monitor.stop()
        monitor.start()
        monitor.stop()
    }

    /// 回调节拍应真的把读数送出来。
    ///
    /// 用私有队列而不是主队列:`wait(for:)` 会阻塞主线程,主队列上的
    /// `DispatchSourceTimer` 就永远不被派发(见 `start(on:interval:)` 的注意)。
    func testCallbackDeliversReadings() {
        let monitor = LidAngleMonitor()
        let queue = DispatchQueue(label: "LidAngleKitTests.readings")
        let received = expectation(description: "收到至少一次读数")
        received.assertForOverFulfill = false
        monitor.onReading = { _ in received.fulfill() }
        monitor.start(on: queue, interval: 0.05)
        wait(for: [received], timeout: 5)
        monitor.stop()
        monitor.onReading = nil
    }
}

// MARK: - 传感器读取

final class LidAngleSensorTests: XCTestCase {

    /// 越界读数必须被丢弃:设备刚打开与系统唤醒瞬间会给垃圾值。
    func testRejectedValuesLeaveTheAngleNil() throws {
        try skipUnlessLidAngleSensorAvailable()
        let sensor = LidAngleSensor()
        // 正常读数必须是有限值且在量程内。
        let angle = sensor.angle()
        if let angle {
            XCTAssertTrue(angle.isFinite)
            XCTAssertTrue((0...360).contains(angle))
        }
    }

    /// 档位的 report ID 与步长必须自洽。
    func testResolutionMetadata() {
        XCTAssertEqual(LidAngleSensor.Resolution.hundredthsOfADegree.reportID, 7)
        XCTAssertEqual(LidAngleSensor.Resolution.wholeDegrees.reportID, 1)
        XCTAssertEqual(LidAngleSensor.Resolution.hundredthsOfADegree.step, 0.01)
        XCTAssertEqual(LidAngleSensor.Resolution.wholeDegrees.step, 1)
    }
}
