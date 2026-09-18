import Foundation

// MARK: - 动作收敛（busy 窗口的真实结束条件）

/// 一次采样的结果：探测快照 + 读回的自启动值。
///
/// 收敛判定与 UI 刷新共用同一份采样，避免为了判 goal 再走一遍 shell。
public struct ServiceProbeSnapshot: Sendable, Equatable {
    public let status: LaunchdServiceStatus
    public let autostartOn: Bool

    public init(status: LaunchdServiceStatus, autostartOn: Bool) {
        self.status = status
        self.autostartOn = autostartOn
    }
}

/// 一次动作的收敛目标：busy 窗口的结束条件。
///
/// `launchctl` 返回只说明 launchd 受理了动作，与「状态落定」之间隔着不确定的
/// 时间——停一个已退出的服务是几十毫秒，`bootstrap` 后 worker 等外置卷则可达
/// 数十秒（此时 `probe()` 判 `.starting`）。用固定时长收尾必然错在一侧：短了会在
/// 就绪前撤掉「进行中」指示，长了是无谓空转。把结束条件写成可判定的纯值后，
/// busy 与真实状态同寿命。判定为纯函数，`ServiceActionGoalTests` 覆盖。
public enum ServiceActionGoal: Sendable, Equatable {
    /// 启动：launchd 已把进程拉起来（`.starting`）或 worker 已在监听（`.managed`）。
    ///
    /// 刻意**不等** `.managed`：wrapper 等外置卷可以是几十秒，旋转指示转到那时
    /// 会被读成卡死，而这几十秒的诚实表达是既有的黄灯 `.starting` 状态行。
    case running
    /// 停止：launchd 已释放任务（`isLoaded == false`）。
    /// 野进程是否仍占着端口不改变「launchd 这一侧已经停掉」这个事实，故不要求 `.stopped`。
    case stopped
    /// 重启：launchd 已拉起**新**进程（`launchdPID` 非 nil 且与动作前不同）。
    /// 传递动作前的 PID 而非「是否在跑」：`kickstart -k` 之后片刻仍可能探到旧 PID。
    case restarted(previousLaunchdPID: pid_t?)
    /// 写 plist：读回的 `RunAtLoad` 等于目标值（与 launchd 进程状态无关）。
    case autostart(expected: Bool)

    /// 目标是否达成。
    public func isSatisfied(by snapshot: ServiceProbeSnapshot) -> Bool {
        switch self {
        case .running:
            return snapshot.status.state == .starting || snapshot.status.state == .managed
        case .stopped:
            return !snapshot.status.isLoaded
        case .restarted(let previousLaunchdPID):
            guard let pid = snapshot.status.launchdPID else { return false }
            return pid != previousLaunchdPID
        case .autostart(let expected):
            return snapshot.autostartOn == expected
        }
    }

    /// 收敛超时：超过即认定动作未达预期，调用方须报错而不是静默当成功。
    /// 取值留出的是「命令已发出但状态没到位」的排查余量，不是预期耗时。
    public var timeout: Duration {
        switch self {
        case .running: return .seconds(15)
        case .stopped: return .seconds(6)
        case .restarted: return .seconds(20)
        case .autostart: return .seconds(4)
        }
    }
}

// MARK: - 收敛循环

/// busy 窗口的收敛循环：按固定间隔采样，直到 goal 命中或超时。
///
/// 采样器由调用方注入（服务插件的监视器传入自己的 `refreshOnce()`，顺带把中间
/// 真实状态推给 UI）；采样返回 nil 表示调用方已释放，直接收尾。
public enum ServiceActionWatcher {
    public enum Outcome: Sendable, Equatable {
        /// goal 命中，动作按预期收敛。
        case settled
        /// 超时仍未命中：动作已发出但状态没到位。
        case timedOut
    }

    /// 采样间隔。比抽屉展开时的 2s 轮询密，比一次性探测细——每次采样含
    /// launchctl/pgrep/lsof/ps 数次 fork，只覆盖到 goal 达成为止。
    public static let pollInterval: Duration = .milliseconds(300)
    /// busy 的可见性下限（不参与收敛判定）：动作极快时旋转弧只闪一帧，观感像故障。
    public static let minimumDuration: Duration = .milliseconds(450)

    /// - Parameters:
    ///   - goal: 收敛目标。
    ///   - interval: 采样间隔。
    ///   - timeout: 收敛超时；nil 用 `goal.timeout`。
    ///   - minimumDuration: 可见性下限（从命令返回后计）。
    ///   - sample: 采样器；返回 nil 表示调用方已释放，按已收敛收尾。
    public static func wait(
        goal: ServiceActionGoal,
        interval: Duration = ServiceActionWatcher.pollInterval,
        timeout: Duration? = nil,
        minimumDuration: Duration = ServiceActionWatcher.minimumDuration,
        sample: @Sendable () async -> ServiceProbeSnapshot?
    ) async -> Outcome {
        let limit = timeout ?? goal.timeout
        let started = ContinuousClock.now
        while true {
            // 调用方（宿主退出 / 插件禁用）已经不等了，就别再花 shell 调用。
            guard !Task.isCancelled else { return .settled }
            guard let snapshot = await sample() else { return .settled }
            if goal.isSatisfied(by: snapshot) {
                let elapsed = ContinuousClock.now - started
                if elapsed < minimumDuration {
                    try? await Task.sleep(for: minimumDuration - elapsed)
                }
                return .settled
            }
            guard ContinuousClock.now - started < limit else { return .timedOut }
            try? await Task.sleep(for: interval)
        }
    }
}
