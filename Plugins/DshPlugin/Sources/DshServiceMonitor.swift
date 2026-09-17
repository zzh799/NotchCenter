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

    func setActive(_ active: Bool) {
        isActive = active
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
        runAction(shouldStart ? L("dsh.action.starting") : L("dsh.action.stopping")) { control in
            if shouldStart {
                _ = control.start()
            } else {
                _ = control.stop()
            }
            return nil
        }
    }

    func restart() {
        guard !isBusy else { return }
        runAction(L("dsh.action.restarting")) { control in
            return control.restart() ? nil : L("dsh.error.restart")
        }
    }

    func setAutostart(_ on: Bool) {
        guard !isBusy else { return }
        runAction(on ? L("dsh.action.autostartOn") : L("dsh.action.autostartOff")) { control in
            _ = control.setAutostart(on)
            return nil
        }
    }

    /// 确保 plist 存在（缺失时按固定模板创建），成功后尝试启动。
    func ensurePlistAndStart() {
        guard !isBusy else { return }
        runAction(L("dsh.action.creatingPlist")) { control in
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

    /// 把副作用动作丢到后台执行，期间置 busy，结束后立即刷新一次状态。
    /// 返回 nil 表示成功；返回字符串为错误提示。
    private func runAction(_ busyMessage: String, _ action: @escaping @Sendable (LaunchdControl) -> String?) {
        isBusy = true
        message = nil
        let control = control
        Task(priority: .userInitiated) { [weak self] in
            let error = await Task.detached(priority: .userInitiated) {
                action(control)
            }.value
            // launchctl 状态落定需要一点时间，稍候再探测。
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            self.isBusy = false
            self.message = error ?? busyMessage
            await self.refreshOnce()
        }
    }
}
