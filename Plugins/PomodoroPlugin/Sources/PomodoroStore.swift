import AppKit
import Combine
import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 番茄钟共享 store（引擎驱动 + 设置持久化 + 活动岛生命周期 + 音效）

/// 视图层（活动岛 / 紧凑块 / 抽屉块）观察的展示快照。
struct PomodoroDisplay: Equatable {
    var phase: PomodoroPhase = .idle
    /// 当前阶段剩余秒数（向上取整）。
    var remainingSeconds: Int = 0
    /// 当前阶段进度 0...1。
    var progress: Double = 0
    var isPaused: Bool = false
    /// 今日完成的专注次数。
    var completedToday: Int = 0
}

/// 今日完成统计（StateStore 持久化，跨天自动清零）。
private struct PomodoroStats: Codable, Equatable {
    var day: String
    var completed: Int
}

/// 插件内共享模型：所有块与活动岛观察同一份 store（番茄钟是全局单例状态，
/// 与放置实例无关，不走 placementStore）。
@MainActor
final class PomodoroStore: ObservableObject {
    static let shared = PomodoroStore()
    /// 活动岛标识（宿主按 id 收回）。
    static let islandID = "pomodoro.island"

    private static let configKey = "config"
    private static let statsKey = "stats"

    @Published private(set) var config: PomodoroConfig
    @Published private(set) var display = PomodoroDisplay()

    private var engine = PomodoroEngine()
    private(set) var sharedStateStore: StateStore?
    private weak var hostController: (any HostController)?
    private let soundPlayer: any PomodoroSoundPlaying
    private var tickTimer: Timer?
    private var stats = PomodoroStats(day: "", completed: 0)

    init(soundPlayer: any PomodoroSoundPlaying = NSSoundPlayer()) {
        self.soundPlayer = soundPlayer
        self.config = PomodoroConfigLogic.sanitized(PomodoroConfig())

        var engine = PomodoroEngine()
        engine.makeReminderInterval = { [weak self] in
            guard let self else { return 0 }
            let interval = self.engineConfig.reminderInterval
            return Double.random(in: interval.lowerBound...max(interval.upperBound, interval.lowerBound))
        }
        self.engine = engine
    }

    /// attachServices 注入：加载持久化设置与统计（幂等，禁用后再启用会重新调用）。
    func resolve(stateStore: StateStore, hostController: any HostController) {
        sharedStateStore = stateStore
        self.hostController = hostController
        if let stored: PomodoroConfig = stateStore.object(PomodoroConfig.self, forKey: Self.configKey) {
            config = PomodoroConfigLogic.sanitized(stored)
        }
        if let stored: PomodoroStats = stateStore.object(PomodoroStats.self, forKey: Self.statsKey) {
            stats = stored
        }
        publishDisplay(now: Date())
    }

    /// 插件被禁用：停止引擎、收起活动岛、停表（不卸载数据）。
    func suspend() {
        engine.stop()
        stopTicking()
        removeIsland()
        publishDisplay(now: Date())
    }

    // MARK: 用户操作

    func start() {
        guard engine.phase == .idle else { return }
        if let event = engine.start(now: Date(), config: engineConfig) {
            handle(event)
        }
        publishDisplay(now: Date())
        showIsland()
        startTicking()
    }

    func stop() {
        guard engine.phase != .idle else { return }
        engine.stop()
        stopTicking()
        removeIsland()
        publishDisplay(now: Date())
    }

    func togglePause() {
        guard engine.phase != .idle else { return }
        engine.togglePause(now: Date())
        publishDisplay(now: Date())
    }

    func skip() {
        guard engine.phase != .idle else { return }
        if let event = engine.skip(now: Date(), config: engineConfig) {
            handle(event)
        }
        publishDisplay(now: Date())
    }

    /// 设置写入（设置界面滑杆/选择器）：净化后立即持久化。
    /// 变更对当前阶段不打断（阶段结束时刻已锚定），下次调度生效。
    func update(_ mutate: (inout PomodoroConfig) -> Void) {
        var next = config
        mutate(&next)
        let sanitized = PomodoroConfigLogic.sanitized(next)
        guard sanitized != config else { return }
        config = sanitized
        try? sharedStateStore?.setObject(sanitized, forKey: Self.configKey)
    }

    /// 设置界面试听音效。
    func preview(_ soundName: String) {
        soundPlayer.play(soundName)
    }

    // MARK: 引擎驱动

    private var engineConfig: PomodoroEngineConfig {
        PomodoroEngineConfig(
            focusDuration: TimeInterval(config.focusMinutes) * 60,
            restDuration: TimeInterval(config.restMinutes) * 60,
            microBreakDuration: TimeInterval(config.microBreakSeconds),
            reminderInterval:
                TimeInterval(config.reminderMinMinutes) * 60
                ... TimeInterval(config.reminderMaxMinutes) * 60
        )
    }

    private func handle(_ event: PomodoroEvent) {
        switch event {
        case .focusStarted:
            soundPlayer.play(config.startSound)
        case .focusCompleted:
            soundPlayer.play(config.endSound)
            recordCompletedFocus()
        case .focusSkipped:
            soundPlayer.play(config.endSound)
        case .microBreakStarted:
            soundPlayer.play(config.microBreakSound)
        }
    }

    private func tick() {
        let now = Date()
        if let event = engine.tick(now: now, config: engineConfig) {
            handle(event)
        }
        publishDisplay(now: now)
    }

    private func publishDisplay(now: Date) {
        let next = PomodoroDisplay(
            phase: engine.phase,
            remainingSeconds: Int(engine.remaining(now: now).rounded(.up)),
            progress: engine.progress(now: now),
            isPaused: engine.pausedRemaining != nil,
            completedToday: completedToday
        )
        if next != display {
            display = next
        }
    }

    private var completedToday: Int {
        stats.day == Self.dayString(Date()) ? stats.completed : 0
    }

    private func recordCompletedFocus() {
        let today = Self.dayString(Date())
        if stats.day != today {
            stats = PomodoroStats(day: today, completed: 0)
        }
        stats.completed += 1
        try? sharedStateStore?.setObject(stats, forKey: Self.statsKey)
    }

    private static func dayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    // MARK: 定时器（0.5s：倒计时秒级平滑 + 阶段转移及时）

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: 活动岛

    private func showIsland() {
        guard let hostController else { return }
        hostController.showActivityIsland(
            ActivityIslandContent(
                id: Self.islandID,
                maxSize: PomodoroIslandLayout.maxSize,
                view: AnyView(PomodoroIslandView(store: self))
            )
        )
    }

    private func removeIsland() {
        hostController?.removeActivityIsland(id: Self.islandID)
    }
}
