import Foundation
import XCTest

@testable import LaunchdControlKit

/// 服务动作收敛单测：`ServiceActionGoal` 的纯判定与 `ServiceActionWatcher` 的
/// 循环行为（脚本化采样器驱动的假状态序列），不真跑 launchctl。
final class ServiceActionGoalTests: XCTestCase {
    // MARK: - 辅助

    private func snapshot(
        _ state: LaunchdServiceStatus.State,
        isLoaded: Bool = true,
        launchdPID: pid_t? = 100,
        autostartOn: Bool = false
    ) -> ServiceProbeSnapshot {
        ServiceProbeSnapshot(
            status: LaunchdServiceStatus(
                state: state, isLoaded: isLoaded, pid: nil, port: nil, launchdPID: launchdPID
            ),
            autostartOn: autostartOn
        )
    }

    /// 按序吐出预设快照，队列耗尽后重复最后一个（模拟状态停滞）。
    private actor ScriptedSampler {
        private var pending: [ServiceProbeSnapshot?]
        private var last: ServiceProbeSnapshot?
        private(set) var calls = 0

        init(_ snapshots: [ServiceProbeSnapshot?]) {
            self.pending = snapshots
        }

        func next() -> ServiceProbeSnapshot? {
            calls += 1
            guard !pending.isEmpty else { return last }
            let value = pending.removeFirst()
            last = value
            return value
        }
    }

    // MARK: - goal 判定

    func testRunningGoalAcceptsStartingOrManaged() {
        XCTAssertTrue(ServiceActionGoal.running.isSatisfied(by: snapshot(.starting)))
        XCTAssertTrue(ServiceActionGoal.running.isSatisfied(by: snapshot(.managed)))
        // 刻意不等 `.managed`：等外置卷的几十秒由黄灯状态行表达，旋转指示不能一直转。
        for state in [
            LaunchdServiceStatus.State.loadedNotRunning,
            .unmanagedExternal,
            .portConflict(listeningCount: 2),
        ] {
            XCTAssertFalse(
                ServiceActionGoal.running.isSatisfied(by: snapshot(state, isLoaded: false)),
                "\(state) 不应算启动已收敛"
            )
        }
        XCTAssertFalse(
            ServiceActionGoal.running.isSatisfied(by: snapshot(.stopped, isLoaded: false, launchdPID: nil))
        )
    }

    func testStoppedGoalOnlyChecksLaunchdRelease() {
        // 只看 launchd 是否释放：bootout 之后端口可能还在野进程手里，那不影响「已停」。
        XCTAssertTrue(ServiceActionGoal.stopped.isSatisfied(
            by: snapshot(.unmanagedExternal, isLoaded: false, launchdPID: nil)
        ))
        XCTAssertTrue(ServiceActionGoal.stopped.isSatisfied(
            by: snapshot(.stopped, isLoaded: false, launchdPID: nil)
        ))
        for state in [
            LaunchdServiceStatus.State.loadedNotRunning,
            .starting,
            .managed,
        ] {
            XCTAssertFalse(ServiceActionGoal.stopped.isSatisfied(by: snapshot(state)), "\(state) 仍被 launchd 持有")
        }
    }

    func testRestartedGoalRequiresFreshLaunchdPID() {
        let goal = ServiceActionGoal.restarted(previousLaunchdPID: 100)
        XCTAssertFalse(
            goal.isSatisfied(by: snapshot(.managed, launchdPID: 100)),
            "kickstart -k 后片刻仍会探到旧 PID，那不是收敛"
        )
        XCTAssertTrue(goal.isSatisfied(by: snapshot(.starting, launchdPID: 101)))
        XCTAssertTrue(goal.isSatisfied(by: snapshot(.managed, launchdPID: 101)))
        XCTAssertFalse(
            goal.isSatisfied(by: snapshot(.loadedNotRunning, launchdPID: nil)),
            "进程没了不算重启完成"
        )
        // 动作前未加载时 restart 回退为 bootstrap：拉起任意 PID 即收敛。
        XCTAssertTrue(
            ServiceActionGoal.restarted(previousLaunchdPID: nil).isSatisfied(by: snapshot(.starting, launchdPID: 7))
        )
    }

    func testAutostartGoalComparesReadbackOnly() {
        XCTAssertTrue(ServiceActionGoal.autostart(expected: true).isSatisfied(
            by: snapshot(.stopped, isLoaded: false, launchdPID: nil, autostartOn: true)
        ))
        XCTAssertFalse(ServiceActionGoal.autostart(expected: true).isSatisfied(
            by: snapshot(.stopped, isLoaded: false, launchdPID: nil, autostartOn: false)
        ))
        // 写 plist 与进程状态无关：服务在跑也可以收敛。
        XCTAssertTrue(ServiceActionGoal.autostart(expected: false).isSatisfied(
            by: snapshot(.managed, autostartOn: false)
        ))
    }

    func testTimeoutsAreOrderedByRisk() {
        // 自启动只是写 plist；启动要等 launchd 拉起进程；重启还要等新进程出现。
        XCTAssertLessThan(ServiceActionGoal.autostart(expected: true).timeout, ServiceActionGoal.stopped.timeout)
        XCTAssertLessThan(ServiceActionGoal.stopped.timeout, ServiceActionGoal.running.timeout)
        XCTAssertLessThan(
            ServiceActionGoal.running.timeout,
            ServiceActionGoal.restarted(previousLaunchdPID: nil).timeout
        )
    }

    // MARK: - 收敛循环

    func testWatcherSettlesAsSoonAsGoalIsMet() async {
        // 前两次采样未就绪，第三次 `.starting` 命中：循环必须当场收尾。
        let sampler = ScriptedSampler([
            snapshot(.loadedNotRunning),
            snapshot(.loadedNotRunning),
            snapshot(.starting, launchdPID: 200),
        ])
        let outcome = await ServiceActionWatcher.wait(
            goal: .running,
            interval: .milliseconds(1),
            timeout: .milliseconds(500),
            minimumDuration: .zero
        ) { await sampler.next() }
        XCTAssertEqual(outcome, .settled)
        let calls = await sampler.calls
        XCTAssertEqual(calls, 3, "命中即停，不该多采一次")
    }

    func testWatcherTimesOutWhenGoalNeverMet() async {
        let sampler = ScriptedSampler([snapshot(.stopped, isLoaded: false, launchdPID: nil)])
        let started = ContinuousClock.now
        let outcome = await ServiceActionWatcher.wait(
            goal: .running,
            interval: .milliseconds(1),
            timeout: .milliseconds(40),
            minimumDuration: .zero
        ) { await sampler.next() }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(40))
    }

    func testWatcherSettlesWhenSamplerIsReleased() async {
        // 采样器返回 nil（监视器已释放）时直接收尾，不空转到超时。
        let sampler = ScriptedSampler([nil])
        let outcome = await ServiceActionWatcher.wait(
            goal: .running,
            interval: .milliseconds(1),
            timeout: .seconds(5),
            minimumDuration: .zero
        ) { await sampler.next() }
        XCTAssertEqual(outcome, .settled)
    }

    func testWatcherHonoursMinimumVisibleDuration() async {
        // 首采即命中也要凑满可见性下限，否则旋转弧只闪一帧，观感像故障。
        let sampler = ScriptedSampler([snapshot(.managed, launchdPID: 200)])
        let started = ContinuousClock.now
        let outcome = await ServiceActionWatcher.wait(
            goal: .running,
            interval: .milliseconds(1),
            timeout: .seconds(5),
            minimumDuration: .milliseconds(80)
        ) { await sampler.next() }
        XCTAssertEqual(outcome, .settled)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(80))
    }
}
