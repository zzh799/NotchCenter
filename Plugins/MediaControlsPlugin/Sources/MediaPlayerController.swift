import Combine
import Foundation

// MARK: - 媒体播放控制器（插件级共享 store：观测 + 控制）
//
// 媒体播放是系统级瞬态，与放置实例无关，因此不落 stateStore，而是插件级单例
// ObservableObject，所有块视图观察同一份状态（与番茄钟同构）。
//
// 观测是**推送式**的：桥子进程在状态变化时逐行输出，控制器只在有块呈现期间让它常驻。
// 块可见性的判断依据是 Kit 的 `\.isDrawerPresented`——宿主对抽屉内容做温存，
// `.onAppear` / `.onDisappear` 只表达挂载 / 卸载（见
// docs/agent-notes/implemented/2026-09-11-drawer-content-warmth.md），三条入口共用
// 一个幂等登记函数喂给本控制器。

@MainActor
final class MediaPlayerController: ObservableObject {
    static let shared = MediaPlayerController(
        provider: LiveNowPlayingProvider(),
        identityResolver: WorkspaceAppIdentityResolver()
    )

    @Published private(set) var state: MediaPlaybackState = .idle
    @Published private(set) var app: MediaAppIdentity?

    private let provider: any NowPlayingProviding
    private let identityResolver: any MediaAppIdentityResolving

    private var presentedPlacements: Set<String> = []
    private var observing = false

    init(provider: any NowPlayingProviding, identityResolver: any MediaAppIdentityResolving) {
        self.provider = provider
        self.identityResolver = identityResolver
    }

    /// 测试用只读探针：当前是否在观测（桥子进程是否在跑）。
    var isObserving: Bool { observing }

    // MARK: 块可见性（视图驱动，幂等）

    /// 登记某个放置实例是否呈现。
    ///
    /// 收起与卸载会先后各触发一次收尾，重复登记/注销必须是无操作，否则会重复起进程
    /// 或把仍在屏的另一块提前停掉。
    func setPresented(_ presented: Bool, placementID: String) {
        if presented {
            guard presentedPlacements.insert(placementID).inserted else { return }
            guard !observing else { return }
            observing = true
            provider.start { [weak self] snapshot in
                self?.ingest(snapshot)
            }
        } else {
            guard presentedPlacements.remove(placementID) != nil else { return }
            if presentedPlacements.isEmpty { stopObserving() }
        }
    }

    /// 插件被禁用：停观测、清登记（幂等）。
    ///
    /// 视图卸载通常已经收过尾，这里再收一次是防「禁用时抽屉正温存着」这类路径漏掉，
    /// 底线上不能留下常驻的 perl 子进程。
    func suspend() {
        presentedPlacements.removeAll()
        stopObserving()
        state = .idle
        app = nil
    }

    private func stopObserving() {
        guard observing else { return }
        observing = false
        provider.stop()
    }

    // MARK: 状态吸收

    private func ingest(_ snapshot: NowPlayingSnapshot) {
        // 停止观测之后到达的推送一律丢弃：收尾时序不能靠 provider 单方面保证。
        guard observing else { return }

        let nextState = MediaPlaybackState.derive(from: snapshot)
        if nextState != state { state = nextState }

        let nextApp = identityResolver.identity(
            forBundleIdentifier: snapshot.client?.bundleIdentifier,
            processIdentifier: snapshot.client?.processIdentifier
        )
        if nextApp != app { app = nextApp }
    }

    // MARK: 用户操作

    func togglePlayPause() { dispatch(.togglePlayPause) }
    func nextTrack() { dispatch(.nextTrack) }
    func previousTrack() { dispatch(.previousTrack) }

    private func dispatch(_ command: MediaRemoteCommand) {
        // 没在观测（抽屉收起 / 插件被禁用）时不派发：按钮可能在收起动画期间还被点中。
        guard observing else { return }
        provider.send(command)
    }
}
