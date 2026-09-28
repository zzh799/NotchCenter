import AppKit
import Combine
import Foundation
import LaunchdControlKit

/// 服务监视器：后台轮询探测 + 用户动作编排（决策 7：库同步、插件调度）。
///
/// 所有系统调用经 `Task.detached` 丢到后台线程，结果回主线程更新
/// `@Published` 属性驱动 SwiftUI 刷新。
@MainActor
final class DshServiceMonitor: ObservableObject {
    /// 抽屉展开时的高频轮询间隔。
    static let activeInterval: TimeInterval = 2
    /// 收起时的低频轮询间隔。
    static let idleInterval: TimeInterval = 10

    /// 插件级共享单例：抽屉收起时内容分支退出视图树（SwiftUI 身份销毁），
    /// 每次展开宿主都会经 `makeView` 重建块视图——@StateObject 跟着重建并
    /// 从 `.stopped` 起步，首次探测返回后开关从关翻到开，表现为每次展开
    /// 都重播一次“打开”动画。状态真源必须活过视图生命周期：新视图直接以
    /// 当前真实状态起渲染。App 启动时由 `DshPlugin.attachServices` 预热，
    /// 展开瞬间再由视图 `.task` 补一次即时探测保证新鲜度。
    static let shared = DshServiceMonitor()

    @Published private(set) var status = LaunchdServiceStatus(
        state: .stopped, isLoaded: false, pid: nil, port: nil, launchdPID: nil
    )
    @Published private(set) var autostartOn = false
    @Published private(set) var isBusy = false
    /// 在飞动作的文案（busy 期间非 nil）：块状态位与浮窗状态行都改报它，
    /// 否则动作期间 UI 仍显示动作前的真实状态（重启/开自启时尤其离谱）。
    @Published private(set) var busyLabel: String?
    /// 操作失败等一次性提示文案；nil 表示无提示。
    @Published var message: String?

    /// 主开关的语义（决策 4）：只反映 **launchd 管理的服务** 是否在跑。
    /// 野进程占用端口（unmanagedExternal）不算开启——否则 dsh 已停但
    /// 端口被其他程序占用时开关会误显示为开。
    /// 启动期（`.starting`，worker 尚未监听）也算开启：开关不在启动瞬间回弹。
    var isServiceOn: Bool {
        switch status.state {
        case .managed, .starting: return true
        default: return false
        }
    }

    private let probe: LaunchdProbe
    private let control: LaunchdControl
    private var pollingTask: Task<Void, Never>?
    private var isActive = false

    init(probe: LaunchdProbe = LaunchdProbe(target: DshServiceConfig.target),
         control: LaunchdControl = LaunchdControl(target: DshServiceConfig.target)) {
        self.probe = probe
        self.control = control
        startPolling()
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: 轮询

    /// 切换轮询档位：只改间隔，轮询循环每拍读 `isActive` 决定 2s（展开）/ 10s
    /// （收起），因此**不重启**当前任务。要停表用 `suspend()`。
    func setActive(_ active: Bool) {
        isActive = active
    }

    /// 停表（插件被禁用时调用）：取消轮询循环。`resume()` 可再起。
    func suspend() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 重新起表（插件被重新启用时调用）。幂等：已在跑则不动。
    ///
    /// 起表前把档位重置为 idle——冷启那一刻还不知道抽屉是否展开，视图
    /// `.onAppear` 会按真实可见性立刻调 `setActive` 校正。
    func resume() {
        guard pollingTask == nil else { return }
        isActive = false
        startPolling()
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOnce()
                let interval = self.isActive ? Self.activeInterval : Self.idleInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 单次探测：后台执行，回主线程更新状态。
    func refreshOnce() async {
        let probe = probe
        let control = control
        let snapshot = await Task.detached(priority: .utility) {
            (status: probe.probe(), autostart: control.readRunAtLoad())
        }.value
        guard !Task.isCancelled else { return }
        status = snapshot.status
        autostartOn = snapshot.autostart ?? false
    }

    // MARK: 动作

    func toggleRunning() {
        guard !isBusy else { return }
        // 开关语义是 launchd 服务：off（含 loadedNotRunning / 野进程占用）→ 启动。
        let shouldStart = !isServiceOn
        // 已加载但没在跑（进程崩过 / bootout 残留）：bootstrap 对已加载的任务必然
        // 报 already loaded，正确的动作是 kickstart。旧代码吞掉这个失败，动作结果
        // 可见化之后不改会把「其实起来了但没在跑」误报成 bootstrap 失败。
        let needsKickstart = shouldStart && status.isLoaded
        runAction(
            shouldStart ? L("dsh.action.starting") : L("dsh.action.stopping"),
            goal: shouldStart ? .running : .stopped
        ) { control in
            if !shouldStart {
                _ = control.stop()
                return nil
            }
            if needsKickstart { return control.restart() ? nil : L("dsh.error.restart") }
            return control.start() ? nil : L("dsh.error.bootstrap")
        }
    }

    func restart() {
        guard !isBusy else { return }
        // 传动作前的 PID：kickstart -k 之后片刻仍可能探到旧 PID，只看「在不在跑」会误判收敛。
        let previousLaunchdPID = status.launchdPID
        runAction(L("dsh.action.restarting"), goal: .restarted(previousLaunchdPID: previousLaunchdPID)) { control in
            return control.restart() ? nil : L("dsh.error.restart")
        }
    }

    func setAutostart(_ on: Bool) {
        guard !isBusy else { return }
        // plist 缺失等失败由 goal（读回值 == 目标）兜住，不在动作里另做判定。
        runAction(on ? L("dsh.action.autostartOn") : L("dsh.action.autostartOff"),
                  goal: .autostart(expected: on)) { control in
            _ = control.setAutostart(on)
            return nil
        }
    }

    /// 确保 plist 存在（缺失时按固定模板创建），成功后尝试启动。
    func ensurePlistAndStart() {
        guard !isBusy else { return }
        runAction(L("dsh.action.creatingPlist"), goal: .running) { control in
            let plist = LaunchdPlist(plistPath: DshServiceConfig.plistPath)
            guard plist.createIfMissing(contents: DshServiceConfig.plistContents) else {
                return LF("dsh.error.createPlist", DshServiceConfig.plistPath)
            }
            return control.start() ? nil : L("dsh.error.bootstrap")
        }
    }

    /// 打开网页：探测端口优先，硬编码 URL 回退（决策 8）。
    func openWeb() {
        if let port = status.port,
           let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(DshServiceConfig.fallbackWebURL)
        }
    }

    // MARK: 内部

    /// 把副作用动作丢到后台执行，期间置 busy（并在 `busyLabel` 挂上在飞动作文案）。
    /// busy 何时结束由 `goal` 的真实收敛决定，不是固定时长（见 `ServiceActionGoal`）。
    /// 返回 nil 表示动作已发出；返回字符串为错误提示。
    private func runAction(
        _ busyMessage: String,
        goal: ServiceActionGoal,
        _ action: @escaping @Sendable (LaunchdControl) -> String?
    ) {
        isBusy = true
        busyLabel = busyMessage
        message = nil
        let control = control
        Task(priority: .userInitiated) { [weak self] in
            let error = await Task.detached(priority: .userInitiated) {
                action(control)
            }.value
            guard let self else { return }
            var outcome = ServiceActionWatcher.Outcome.settled
            // 动作自己报了失败：结果已经知道，不再等 goal——否则一个注定不达标的
            // 动作会把旋转指示空转满整个超时。
            if error == nil {
                outcome = await ServiceActionWatcher.wait(goal: goal) {
                    await self.refreshOnce()
                    let status = await self.status
                    let autostartOn = await self.autostartOn
                    return ServiceProbeSnapshot(status: status, autostartOn: autostartOn)
                }
            }
            self.isBusy = false
            self.busyLabel = nil
            if let error {
                self.message = error
            } else {
                self.message = outcome == .timedOut ? L("dsh.error.actionTimeout") : busyMessage
            }
            await self.refreshOnce()
        }
    }
}
