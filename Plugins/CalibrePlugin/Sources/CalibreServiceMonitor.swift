import AppKit
import Combine
import Foundation
import LaunchdControlKit

/// 服务监视器：后台轮询探测 + 用户动作编排（决策 7：库同步、插件调度）。
///
/// 所有系统调用经 `Task.detached` 丢到后台线程，结果回主线程更新
/// `@Published` 属性驱动 SwiftUI 刷新。
@MainActor
final class CalibreServiceMonitor: ObservableObject {
    /// 抽屉展开时的高频轮询间隔。
    static let activeInterval: TimeInterval = 2
    /// 收起时的低频轮询间隔。
    static let idleInterval: TimeInterval = 10

    /// 插件级共享单例：抽屉收起时内容分支退出视图树（SwiftUI 身份销毁），
    /// 每次展开宿主都会经 `makeView` 重建块视图——@StateObject 跟着重建并
    /// 从 `.stopped` 起步，首次探测返回后开关从关翻到开，表现为每次展开
    /// 都重播一次“打开”动画。状态真源必须活过视图生命周期：新视图直接以
    /// 当前真实状态起渲染。App 启动时由 `CalibrePlugin.attachServices` 预热，
    /// 展开瞬间再由视图 `.task` 补一次即时探测保证新鲜度。
    static let shared = CalibreServiceMonitor()

    @Published private(set) var status = LaunchdServiceStatus(
        state: .stopped, isLoaded: false, pid: nil, port: nil, launchdPID: nil
    )
    @Published private(set) var autostartOn = false
    @Published private(set) var isBusy = false
    /// 操作失败等一次性提示文案；nil 表示无提示。
    @Published var message: String?

    /// 主开关的语义（决策 4）：只反映 **launchd 管理的服务** 是否在跑。
    /// 野进程占用端口（unmanagedExternal）不算开启——否则服务已停但
    /// 端口被其他程序占用时开关会误显示为开。
    var isServiceOn: Bool {
        if case .managed = status.state { return true }
        return false
    }

    private let probe: LaunchdProbe
    private let control: LaunchdControl
    private var pollingTask: Task<Void, Never>?
    private var isActive = false

    init(probe: LaunchdProbe = LaunchdProbe(target: CalibreServiceConfig.target),
         control: LaunchdControl = LaunchdControl(target: CalibreServiceConfig.target)) {
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
        runAction(shouldStart ? L("calibre.action.starting") : L("calibre.action.stopping")) { control in
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
        runAction(L("calibre.action.restarting")) { control in
            _ = control.restart()
            return nil
        }
    }

    func setAutostart(_ on: Bool) {
        guard !isBusy else { return }
        runAction(on ? L("calibre.action.enableAutostart") : L("calibre.action.disableAutostart")) { control in
            _ = control.setAutostart(on)
            return nil
        }
    }

    /// 确保 plist 存在（缺失时按固定模板创建），成功后尝试启动。
    func ensurePlistAndStart() {
        guard !isBusy else { return }
        runAction(L("calibre.action.creatingPlist")) { [plistPath = CalibreServiceConfig.plistPath] control in
            let plist = LaunchdPlist(plistPath: plistPath)
            guard plist.createIfMissing(contents: CalibreServiceConfig.plistContents) else {
                return LF("calibre.error.createPlist", plistPath)
            }
            return control.start() ? nil : L("calibre.error.bootstrap")
        }
    }

    /// 打开网页：探测端口优先，硬编码 URL 回退（决策 8）。
    func openWeb() {
        if let port = status.port,
           let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(CalibreServiceConfig.fallbackWebURL)
        }
    }

    // MARK: 内部

    /// 把副作用动作丢到后台执行，期间置 busy，结束后立即刷新一次状态。
    /// 返回 nil 表示成功；返回字符串为错误提示。
    private func runAction(_ busyMessage: String, _ action: @escaping @Sendable (LaunchdControl) -> String?) {
        isBusy = true
        message = nil
        let control = control
        Task.detached(priority: .userInitiated) {
            let error = action(control)
            // launchctl 状态落定需要一点时间，稍候再探测。
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run { [weak self] in
                self?.isBusy = false
                self?.message = error ?? busyMessage
                Task { await self?.refreshOnce() }
            }
        }
    }
}
