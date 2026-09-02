import AppKit
import Combine
import Foundation
import NotchCenterKit

// MARK: - 媒体播放控制器（插件级共享 store：观测 + 控制 + 活动摘要）
//
// 与番茄钟同构：插件级**单例** ObservableObject，所有块视图观察同一份状态
// （媒体播放是系统级瞬态，与放置实例无关，不走 placementStore）。
//
// 轮询驱动（MediaRemote 无稳定的实时推送可依赖）：1s ticker + Now Playing
// 变更的 Darwin 通知即时补拉；宿主「正在播放」变化时在 1s 内必然反映到
// 抽屉块与活动摘要芯片。取数回调在后台队列完成，主线程只收最终快照。

@MainActor
final class MediaPlayerController: ObservableObject {
    /// 视图与摘要共用的展示快照（不携带封面：封面单独按曲目键发布）。
    struct MediaDisplay: Equatable {
        var state: MediaPlaybackState = .idle
        var title: String?
        var artist: String?
        var album: String?
        var elapsed: TimeInterval = 0
        var duration: TimeInterval = 0
    }

    static let shared = MediaPlayerController(provider: LiveNowPlayingProvider())
    /// 活动摘要标识（宿主按 id 覆盖更新 / 收回）。
    static let summaryID = "media-controls.summary"

    @Published private(set) var display = MediaDisplay()
    /// 封面图（仅当曲目/封面数据变化时更新，避免每秒重发同一张图）。
    @Published private(set) var artwork: NSImage?

    private weak var hostController: (any HostController)?
    private let provider: any NowPlayingProviding
    private var tickTimer: Timer?
    private let artworkCache = NSCache<NSString, NSImage>()
    private var lastArtworkKey: String?
    private var isActive = false
    private var isFetching = false
    private var summarySubmitted = false
    private var observingNotifications = false
    private var lastSummaryKey: String?

    init(provider: any NowPlayingProviding) {
        self.provider = provider
    }

    /// attachServices 注入：幂等启动观测（禁用后再启用会重新调用）。
    func resolve(stateStore: StateStore, hostController: any HostController) {
        self.hostController = hostController
        isActive = true
        guard provider.isObservationAvailable else {
            // 私有框架不可用：降级为整体不可用态，不起 ticker、不收通知。
            display = MediaDisplay(state: .unavailable)
            artwork = nil
            lastArtworkKey = nil
            return
        }
        poll()
        startTicking()
        registerNowPlayingNotification()
    }

    /// 插件被禁用：停表、退通知、收回摘要（不保留任何观测副作用）。
    /// 先把 `isActive` 置否，再清副作用：在途的异步取数回调回到主线程时
    /// 会被 `poll` / `ingest` 的守卫丢弃，不会在禁用后重新提交摘要。
    func suspend() {
        isActive = false
        stopTicking()
        unregisterNowPlayingNotification()
        retractSummaryIfNeeded()
        summarySubmitted = false
        lastSummaryKey = nil
        display = MediaDisplay(state: .idle)
        artwork = nil
        lastArtworkKey = nil
    }

    // MARK: 轮询与通知

    private static let nowPlayingChangedDarwinName = "com.apple.MediaRemote.NowPlayingInfoChanged"

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func registerNowPlayingNotification() {
        guard !observingNotifications else { return }
        observingNotifications = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = Self.nowPlayingChangedDarwinName as CFString
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<MediaPlayerController>
                    .fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    controller.poll()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterNowPlayingNotification() {
        guard observingNotifications else { return }
        observingNotifications = false
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(Self.nowPlayingChangedDarwinName as CFString),
            nil
        )
    }

    /// 拉一次最新快照（ticker / 变更通知 / 测试共用入口）。
    func poll() {
        guard isActive, !isFetching else { return }
        isFetching = true
        provider.refresh { [weak self] snapshot in
            guard let self else { return }
            self.isFetching = false
            self.ingest(snapshot)
        }
    }

    // MARK: 状态吸收

    private func ingest(_ snapshot: NowPlayingSnapshot) {
        guard isActive else { return }
        let state = deriveState(from: snapshot)
        let next = MediaDisplay(
            state: state,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            elapsed: snapshot.elapsed ?? 0,
            duration: snapshot.duration ?? 0
        )
        if next != display {
            display = next
        }
        updateArtworkIfNeeded(for: snapshot)
        syncSummary()
    }

    private func deriveState(from snapshot: NowPlayingSnapshot) -> MediaPlaybackState {
        guard provider.isObservationAvailable else { return .unavailable }
        guard snapshot.hasMediaItem else { return .idle }
        return (snapshot.isPlaying ?? true) ? .playing : .paused
    }

    // MARK: 封面（NSCache + 按曲目键去抖）

    private func updateArtworkIfNeeded(for snapshot: NowPlayingSnapshot) {
        guard snapshot.hasMediaItem else {
            if lastArtworkKey != nil {
                lastArtworkKey = nil
                artwork = nil
            }
            return
        }
        let key = Self.artworkKey(for: snapshot)
        guard key != lastArtworkKey else { return }
        lastArtworkKey = key

        if let cached = artworkCache.object(forKey: key as NSString) {
            artwork = cached
        } else if let data = snapshot.artworkData,
                  let image = NSImage(data: data) {
            artworkCache.setObject(image, forKey: key as NSString)
            artwork = image
        } else {
            artwork = nil
        }
    }

    /// 曲目封面键：优先媒体项唯一标识，缺失时退化为「时长 + 标题」近似。
    private static func artworkKey(for snapshot: NowPlayingSnapshot) -> String {
        if let uniqueID = snapshot.uniqueID, !uniqueID.isEmpty {
            return "id:\(uniqueID)"
        }
        return "t:\(snapshot.title ?? ""):\(snapshot.duration ?? -1)"
    }

    // MARK: 用户操作

    /// 播放 / 暂停切换（暂停态显示播放钮，统一走 toggle 命令）。
    func togglePlayPause() {
        _ = provider.send(.togglePlayPause)
    }

    func nextTrack() {
        _ = provider.send(.nextTrack)
    }

    func previousTrack() {
        _ = provider.send(.previousTrack)
    }

    /// 供视图用的播放/暂停按钮：播放中显暂停图标（命令 pause），否则显播放（命令 play）。
    func setPlaying(_ playing: Bool) {
        _ = provider.send(playing ? .play : .pause)
    }

    // MARK: 活动摘要（紧凑带迷你芯片；Agent Note 2026-09-03-compact-area-activity-summary）
    //
    // 语义：正在播放 → 提交/覆盖「曲名 + 艺术家」芯片（music.note + 播放进度）；
    // 暂停 → 原位置态（pause.fill + 进度停在暂停处）；停止/无可播 → 收回。
    // 只在「会改变芯片可见内容」的变化上重新提交：状态、曲名、艺术家、整秒进度。

    private func syncSummary() {
        guard let hostController else { return }
        switch display.state {
        case .unavailable, .idle:
            retractSummaryIfNeeded()
        case .playing, .paused:
            let key = summaryKey
            guard key != lastSummaryKey else { return }
            lastSummaryKey = key
            summarySubmitted = true
            hostController.showActivitySummary(
                ActivitySummary(
                    id: Self.summaryID,
                    title: summaryTitle,
                    subtitle: summarySubtitle,
                    symbolName: summarySymbol,
                    progress: summaryProgress
                )
            )
        }
    }

    private func retractSummaryIfNeeded() {
        guard summarySubmitted else { return }
        summarySubmitted = false
        lastSummaryKey = nil
        hostController?.removeActivitySummary(id: Self.summaryID)
    }

    private var summaryTitle: String {
        if let title = display.title, !title.isEmpty { return title }
        return display.state == .paused ? L("state.paused") : L("state.playing")
    }

    private var summarySubtitle: String? {
        let artist = display.artist.flatMap { $0.isEmpty ? nil : $0 }
        let album = display.album.flatMap { $0.isEmpty ? nil : $0 }
        switch (artist, album) {
        case let (artist?, album?): return "\(artist) — \(album)"
        case let (artist?, nil): return artist
        case let (nil, album?): return album
        case (nil, nil): return nil
        }
    }

    private var summarySymbol: String? {
        display.state == .paused ? "pause.fill" : "music.note"
    }

    private var summaryProgress: Double? {
        guard display.duration > 0 else { return nil }
        return min(max(display.elapsed / display.duration, 0), 1)
    }

    /// 摘要可见内容指纹：状态 + 曲名 + 艺术家/专辑 + 整秒进度 + 暂停位。
    private var summaryKey: String {
        let whole = Int(display.elapsed.rounded(.down))
        return "\(display.state == .paused ? "p" : "r")|\(summaryTitle)|\(summarySubtitle ?? "")|\(whole)"
    }
}
