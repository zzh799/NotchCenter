import AppKit
import Combine
import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 插件级共享采样引擎
//
// 与 MediaControls/Pomodoro 同构：插件级**单例** ObservableObject，所有块视图
// 观察同一份历史序列（系统指标与放置实例无关；每屏多副本零额外采样）。
//
// 节奏（共识 Q8-B）：有已放置实例时才运行；抽屉窗口可见 → 2s，收起（窗口
// orderOut，occlusion 丢失 .visible）→ 10s 降频保曲线连续；最后一个实例移除
// 或插件禁用 → 停表。可见性经块视图内嵌的 WindowVisibilityProbe 上报，
// 按窗口对象去重（多块同屏共享一份窗口可见性）。
//
// 采集在 Task.detached(.utility) 执行，主线程只做差分消化与发布；
// `isActive` 守卫保证禁用后在途回调被丢弃（MediaControls.suspend 同款语义）。

@MainActor
final class SystemMonitorStore: ObservableObject {
    static let shared = SystemMonitorStore()

    static let activeInterval: TimeInterval = 2
    static let idleInterval: TimeInterval = 10
    /// 历史容量：300s 窗 × 2s 采样 = 150 点，留一倍余量。
    static let maxHistoryPoints = 300

    @Published private(set) var history: [MetricSample] = []

    private let provider: any SystemMetricsProviding
    private var tickTimer: Timer?
    private var previousRaw: SystemRawSample?
    private var isFetching = false
    private var isActive = false

    /// 活跃放置实例（视图 appear 登记 / 移除回调与 disappear 注销）。
    private var livePlacements: Set<String> = []
    /// 每个承载窗口上的探针计数（多块同窗去重）。
    private var probeCounts: [ObjectIdentifier: Int] = [:]
    /// 当前可见（occlusion 含 .visible）的承载窗口。
    private var visibleWindows: Set<ObjectIdentifier> = []

    /// 当前节拍；nil = 未在运行。internal 供测试断言。
    private(set) var currentInterval: TimeInterval?

    init(provider: any SystemMetricsProviding = DarwinMetricsProvider()) {
        self.provider = provider
    }

    /// 有任何已放置实例在观察数据吗？
    var isObserved: Bool { !livePlacements.isEmpty }

    // MARK: 生命周期

    /// attachServices 注入（幂等）：启用后再禁用会重新调用。
    func attach() {
        isActive = true
        recomputeTimer()
    }

    /// 插件被禁用：停表并清掉全部观察登记（视图与探针随之失效）。
    /// 先置 `isActive = false` 再清副作用，在途采集回调回主线程后被守卫丢弃。
    func suspend() {
        isActive = false
        stopTicking()
        livePlacements.removeAll()
        probeCounts.removeAll()
        visibleWindows.removeAll()
    }

    // MARK: 实例登记（视图生命周期）

    func viewDidAppear(placementID: String) {
        guard !placementID.isEmpty else { return }
        livePlacements.insert(placementID)
        recomputeTimer()
    }

    func viewDidDisappear(placementID: String) {
        livePlacements.remove(placementID)
        recomputeTimer()
    }

    /// 宿主回调：放置实例被用户删除（视图可能还来不及消失，先强制注销）。
    func placementRemoved(placementID: String) {
        livePlacements.remove(placementID)
        recomputeTimer()
    }

    // MARK: 窗口可见性（WindowVisibilityProbe 上报）

    func probeAttached(windowID: ObjectIdentifier, isVisible: Bool) {
        probeCounts[windowID, default: 0] += 1
        if isVisible {
            visibleWindows.insert(windowID)
        }
        recomputeTimer()
    }

    func probeDetached(windowID: ObjectIdentifier) {
        if let count = probeCounts[windowID] {
            if count <= 1 {
                probeCounts.removeValue(forKey: windowID)
                visibleWindows.remove(windowID)
            } else {
                probeCounts[windowID] = count - 1
            }
        }
        recomputeTimer()
    }

    func probeVisibilityChanged(windowID: ObjectIdentifier, isVisible: Bool) {
        guard probeCounts[windowID] != nil else { return }
        if isVisible {
            visibleWindows.insert(windowID)
        } else {
            visibleWindows.remove(windowID)
        }
        recomputeTimer()
    }

    // MARK: 节拍

    /// 依据（启用 × 有实例 × 可见窗口）重算节拍；档位不变时不动现有表。
    private func recomputeTimer() {
        guard isActive, isObserved else {
            stopTicking()
            return
        }
        let interval = visibleWindows.isEmpty ? Self.idleInterval : Self.activeInterval
        if tickTimer != nil, currentInterval == interval { return }
        stopTicking()
        currentInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        poll()
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        currentInterval = nil
    }

    /// 拉一次最新快照（ticker 与测试共用入口）。
    func poll() {
        guard isActive, isObserved, !isFetching else { return }
        isFetching = true
        let provider = provider
        Task.detached(priority: .utility) { [weak self] in
            let raw = provider.collect()
            await self?.ingest(raw)
        }
    }

    /// 主线程消化：差分 → 追加历史（internal 供测试直注）。
    func ingest(_ raw: SystemRawSample) {
        isFetching = false
        guard isActive else { return }
        let sample = SystemMetricsLogic.differential(from: previousRaw, to: raw)
        previousRaw = raw
        history = MetricHistory.appending(sample, to: history, capacity: Self.maxHistoryPoints)
    }
}

// MARK: - 窗口可见性探针
//
// 抽屉收起 = 宿主对 drawerPanel orderOut，块视图树仍在隐藏窗口里活着
// （onDisappear 不会触发），必须靠窗口 occlusion 感知"用户看不看得见"。
// 探针 NSView 挂在块视图背景层：viewDidMoveToWindow 时登记窗口并订阅
// occlusion 通知（探针必须在 viewDidMoveToWindow 时机挂钩，见 memory：
// SwiftUI 宿主视图此时才拿到 window）。isPreview 副本不插探针。

struct WindowVisibilityProbe: NSViewRepresentable {
    /// 直接捕获单例即可；拆成参数只是为了测试可注入。
    let onAttach: (_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void
    let onDetach: (_ windowID: ObjectIdentifier) -> Void
    let onVisibilityChange: (_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onAttach = onAttach
        view.onDetach = onDetach
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onAttach: ((_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void)?
        var onDetach: ((_ windowID: ObjectIdentifier) -> Void)?
        var onVisibilityChange: ((_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void)?

        private var observedWindowID: ObjectIdentifier?
        private var isObserving = false

        deinit {
            if isObserving {
                NotificationCenter.default.removeObserver(self)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                let windowID = ObjectIdentifier(window)
                guard observedWindowID != windowID else { return }
                stopObserving()
                observedWindowID = windowID
                startObserving(window)
                onAttach?(windowID, window.occlusionState.contains(.visible))
            } else {
                stopObserving()
                if let windowID = observedWindowID {
                    observedWindowID = nil
                    onDetach?(windowID)
                }
            }
        }

        private func startObserving(_ window: NSWindow) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(occlusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            isObserving = true
        }

        private func stopObserving() {
            guard isObserving else { return }
            NotificationCenter.default.removeObserver(self)
            isObserving = false
        }

        @objc private func occlusionDidChange(_ notification: Notification) {
            guard let windowID = observedWindowID, let window else { return }
            onVisibilityChange?(windowID, window.occlusionState.contains(.visible))
        }
    }
}
