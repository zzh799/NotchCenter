import Combine
import Foundation
import NotchCenterKit

/// 防休眠状态存储（由官方 CaffeinatePlugin 使用）。
/// 状态经 StateStore 持久化（文档 §4.6）；不触发真实休眠抑制的单元测试逻辑可注入。
@MainActor
final class KeepAwakeStore: ObservableObject {
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var isChangingKeepAwake = false
    @Published private(set) var keepAwakeErrorMessage: String?

    private static let ownsSleepDisabledKey = "ownsSleepDisabled"
    private static let completedSleepGuardRecoveryKey = "completedSleepGuardRecoveryV1"

    private let stateStore: StateStore
    private let systemSleepGuard: SystemSleepGuard
    private var caffeinateProcess: Process?
    private var keepAwakeTask: Task<Void, Never>?

    init(stateStore: StateStore, systemSleepGuard: SystemSleepGuard = SystemSleepGuard()) {
        self.stateStore = stateStore
        self.systemSleepGuard = systemSleepGuard

        let ownsSleepDisabled = stateStore.object(Bool.self, forKey: Self.ownsSleepDisabledKey) ?? false
        let hasCompletedRecovery = stateStore.object(Bool.self, forKey: Self.completedSleepGuardRecoveryKey) ?? false

        // 首次探测要跑 pmset（同步 spawn 数十毫秒），整体放后台，别卡主线程。
        isChangingKeepAwake = ownsSleepDisabled || !hasCompletedRecovery
        keepAwakeTask = Task { [weak self] in
            await self?.resolveInitialSleepState(
                ownsSleepDisabled: ownsSleepDisabled,
                hasCompletedRecovery: hasCompletedRecovery
            )
        }
    }

    /// 启动时的状态收敛：读一次真实 SleepDisabled，决定是否需要崩溃恢复。
    private func resolveInitialSleepState(ownsSleepDisabled: Bool, hasCompletedRecovery: Bool) async {
        let sleepDisabled = await SystemSleepGuard.isSleepDisabled()
        guard !Task.isCancelled else { return }

        let needsLegacyRecovery = !hasCompletedRecovery && sleepDisabled
        if ownsSleepDisabled || needsLegacyRecovery {
            isKeepingAwake = sleepDisabled
            isChangingKeepAwake = true
            await recoverSleepAfterUnexpectedExit()
        } else {
            try? stateStore.setObject(true, forKey: Self.completedSleepGuardRecoveryKey)
            try? stateStore.setObject(false, forKey: Self.ownsSleepDisabledKey)
            isChangingKeepAwake = false
            keepAwakeTask = nil
        }
    }

    func toggleKeepAwake() {
        guard !isChangingKeepAwake else { return }

        if isKeepingAwake {
            stopKeepingAwake()
        } else {
            requestKeepAwake()
        }
    }

    /// 插件被禁用 / 宿主退出时调用，停止防休眠并尝试恢复系统睡眠设置。
    func stopKeepingAwake() {
        keepAwakeTask?.cancel()
        keepAwakeTask = nil
        systemSleepGuard.requestStop()
        isChangingKeepAwake = true

        let process = caffeinateProcess
        caffeinateProcess = nil

        if let process, process.isRunning {
            process.terminate()
        }

        guard isKeepingAwake || process != nil else {
            isChangingKeepAwake = false
            return
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            let didStop = await self.systemSleepGuard.resetSleepIfNeeded()
            guard !Task.isCancelled else { return }

            let sleepDisabled = await SystemSleepGuard.isSleepDisabled()
            self.setOwnsSleepDisabled(!didStop)
            self.isKeepingAwake = !didStop && sleepDisabled
            self.isChangingKeepAwake = false
            if !didStop {
                self.keepAwakeErrorMessage = L("caffeinate.error.adminRequired.restore")
            }
            self.keepAwakeTask = nil
        }
    }

    func dismissKeepAwakeError() {
        keepAwakeErrorMessage = nil
    }

    // MARK: - 内部

    private func requestKeepAwake() {
        guard caffeinateProcess == nil, !systemSleepGuard.isRunning else { return }

        isChangingKeepAwake = true
        keepAwakeErrorMessage = nil
        setOwnsSleepDisabled(true)

        do {
            try systemSleepGuard.start()
        } catch {
            setOwnsSleepDisabled(false)
            isChangingKeepAwake = false
            keepAwakeErrorMessage = L("caffeinate.error.adminRequired.lidClosed")
            return
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            let isReady = await self.systemSleepGuard.waitUntilReady()
            guard !Task.isCancelled else { return }

            guard isReady, self.startCaffeinate() else {
                let didReset = await self.systemSleepGuard.resetSleepIfNeeded()
                let sleepDisabled = await SystemSleepGuard.isSleepDisabled()
                self.setOwnsSleepDisabled(!didReset)
                self.isKeepingAwake = !didReset && sleepDisabled
                self.isChangingKeepAwake = false
                self.keepAwakeErrorMessage = L("caffeinate.error.adminRequired.lidClosed")
                self.keepAwakeTask = nil
                return
            }

            self.isKeepingAwake = true
            self.isChangingKeepAwake = false
            self.keepAwakeTask = nil
        }
    }

    private func startCaffeinate() -> Bool {
        guard caffeinateProcess == nil else { return true }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = [
            "-dims",
            "-w",
            String(ProcessInfo.processInfo.processIdentifier)
        ]

        do {
            try process.run()
            caffeinateProcess = process
            return true
        } catch {
            caffeinateProcess = nil
            return false
        }
    }

    private func recoverSleepAfterUnexpectedExit() async {
        let didReset = await systemSleepGuard.resetSleepIfNeeded()
        guard !Task.isCancelled else { return }

        setOwnsSleepDisabled(!didReset)
        if didReset {
            try? stateStore.setObject(true, forKey: Self.completedSleepGuardRecoveryKey)
        }
        let sleepDisabled = await SystemSleepGuard.isSleepDisabled()
        isKeepingAwake = !didReset && sleepDisabled
        isChangingKeepAwake = false
        if !didReset {
            keepAwakeErrorMessage = L("caffeinate.error.adminRequired.restore")
        }
        keepAwakeTask = nil
    }

    private func setOwnsSleepDisabled(_ ownsSleepDisabled: Bool) {
        try? stateStore.setObject(ownsSleepDisabled, forKey: Self.ownsSleepDisabledKey)
    }
}