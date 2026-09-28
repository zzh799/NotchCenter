import AppKit
import NotchCenterKit
import XCTest
@testable import MediaControlsPlugin

/// MediaControlsPlugin 回归（Agent Note 2026-09-28-media-controls-plugin-restore）：
/// 状态推导、桥输出解码、应用身份发布、观测的起停与幂等、命令转发、桥不可用的降级、
/// 停止观测后丢弃迟到推送。全部注入假数据源，绝不启动真实子进程。
@MainActor
final class MediaControlsTests: XCTestCase {
    // MARK: 测试替身

    private final class FakeProvider: NowPlayingProviding {
        private(set) var isStarted = false
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var sentCommands: [MediaRemoteCommand] = []
        /// 最后一次 `start` 拿到的回调。`stop()` 之后仍然留着，用来模拟「迟到的推送」。
        private var retainedHandler: (@MainActor (NowPlayingSnapshot) -> Void)?

        func start(onChange: @escaping @MainActor (NowPlayingSnapshot) -> Void) {
            if !isStarted {
                isStarted = true
                startCount += 1
            }
            retainedHandler = onChange
        }

        func stop() {
            guard isStarted else { return }
            isStarted = false
            stopCount += 1
        }

        func send(_ command: MediaRemoteCommand) -> Bool {
            sentCommands.append(command)
            return true
        }

        /// 模拟桥推送一次观测结果。
        func push(_ snapshot: NowPlayingSnapshot) {
            retainedHandler?(snapshot)
        }
    }

    private final class FakeIdentityResolver: MediaAppIdentityResolving {
        var identities: [String: MediaAppIdentity] = [:]
        private(set) var requestedBundleIdentifiers: [String?] = []
        private(set) var requestedProcessIdentifiers: [pid_t?] = []

        func identity(forBundleIdentifier identifier: String?, processIdentifier: pid_t?) -> MediaAppIdentity? {
            requestedBundleIdentifiers.append(identifier)
            requestedProcessIdentifiers.append(processIdentifier)
            guard let identifier else { return nil }
            return identities[identifier]
        }
    }

    // MARK: 夹具

    private func snapshot(
        bridgeFailed: Bool = false,
        hasMediaItem: Bool = true,
        isPlaying: Bool? = true,
        bundleID: String? = nil,
        pid: pid_t? = nil
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            bridgeFailed: bridgeFailed,
            hasMediaItem: hasMediaItem,
            isPlaying: isPlaying,
            client: (bundleID != nil || pid != nil)
                ? NowPlayingClientIdentity(bundleIdentifier: bundleID, processIdentifier: pid)
                : nil
        )
    }

    private func identity(_ bundleID: String, name: String) -> MediaAppIdentity {
        MediaAppIdentity(bundleIdentifier: bundleID, displayName: name, icon: nil)
    }

    private func makeController(
        provider: FakeProvider,
        resolver: FakeIdentityResolver = FakeIdentityResolver()
    ) -> MediaPlayerController {
        MediaPlayerController(provider: provider, identityResolver: resolver)
    }

    // MARK: 状态推导（纯函数）

    func testDeriveStateBranches() {
        XCTAssertEqual(MediaPlaybackState.derive(from: snapshot(bridgeFailed: true)), .unavailable)
        XCTAssertEqual(
            MediaPlaybackState.derive(from: snapshot(hasMediaItem: false, isPlaying: nil)),
            .idle
        )
        XCTAssertEqual(MediaPlaybackState.derive(from: snapshot(isPlaying: true)), .playing)
        XCTAssertEqual(MediaPlaybackState.derive(from: snapshot(isPlaying: false)), .paused)
        // 播放位拿不到时按"在放"处理，不退化成暂停。
        XCTAssertEqual(MediaPlaybackState.derive(from: snapshot(isPlaying: nil)), .playing)
    }

    func testBridgeFailureWinsOverMediaPayload() {
        // 桥坏了但快照里恰好还有上一次的媒体信息时，仍然要判成不可用。
        let failed = NowPlayingSnapshot(bridgeFailed: true, hasMediaItem: true, isPlaying: true, client: nil)
        XCTAssertEqual(MediaPlaybackState.derive(from: failed), .unavailable)
    }

    func testInitialStateIsIdleAndNotObserving() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isObserving)
        XCTAssertEqual(provider.startCount, 0)
    }

    // MARK: 桥输出解码

    func testDecodeStreamLine() {
        let line = #"{"type":"data","diff":false,"payload":{"title":"Anti-Hero","playing":false,"bundleIdentifier":"com.apple.Music","processIdentifier":4711}}"#
        let decoded = LiveNowPlayingProvider.decode(line)

        XCTAssertTrue(decoded.hasMediaItem)
        XCTAssertEqual(decoded.isPlaying, false)
        XCTAssertEqual(decoded.client?.bundleIdentifier, "com.apple.Music")
        XCTAssertEqual(decoded.client?.processIdentifier, 4711)
    }

    func testDecodeTreatsEmptyPayloadAsNothingPlaying() {
        let decoded = LiveNowPlayingProvider.decode(#"{"type":"data","diff":false,"payload":{}}"#)

        XCTAssertFalse(decoded.hasMediaItem)
        XCTAssertNil(decoded.client)
        XCTAssertFalse(decoded.bridgeFailed, "空 payload 是正常空态，不是桥故障")
    }

    func testDecodeFallsBackToNothingPlayingOnGarbage() {
        // 线上格式漂移时宁可少显示，也不要把组件打成不可用。
        for line in ["", "not json", #"{"type":"error"}"#, "[]"] {
            let decoded = LiveNowPlayingProvider.decode(line)
            XCTAssertFalse(decoded.hasMediaItem, "line=\(line)")
            XCTAssertFalse(decoded.bridgeFailed, "line=\(line)")
        }
    }

    func testDecodeKeepsProcessIdentifierWhenBundleIdentifierMissing() {
        let decoded = LiveNowPlayingProvider.decode(
            #"{"type":"data","diff":false,"payload":{"playing":true,"processIdentifier":99}}"#
        )

        XCTAssertNil(decoded.client?.bundleIdentifier)
        XCTAssertEqual(decoded.client?.processIdentifier, 99)
    }

    // MARK: 观测起停（幂等）

    func testFirstPresentationStartsObservation() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)

        controller.setPresented(true, placementID: "p1")

        XCTAssertTrue(controller.isObserving)
        XCTAssertEqual(provider.startCount, 1)
    }

    func testDuplicatePresentationRegistrationIsIdempotent() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)

        controller.setPresented(true, placementID: "p1")
        controller.setPresented(true, placementID: "p1") // 收起与卸载会各触发一次
        XCTAssertEqual(provider.startCount, 1)

        controller.setPresented(false, placementID: "p1")
        controller.setPresented(false, placementID: "p1")
        XCTAssertEqual(provider.stopCount, 1)
        XCTAssertFalse(controller.isObserving)
    }

    func testObservationStopsOnlyWhenTheLastPlacementLeaves() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)

        controller.setPresented(true, placementID: "p1")
        controller.setPresented(true, placementID: "p2")
        controller.setPresented(false, placementID: "p1")
        XCTAssertTrue(controller.isObserving)

        controller.setPresented(false, placementID: "p2")
        XCTAssertFalse(controller.isObserving)
        XCTAssertEqual(provider.stopCount, 1)
    }

    // MARK: 状态吸收与应用身份

    func testPushPublishesStateAndAppIdentity() {
        let provider = FakeProvider()
        let resolver = FakeIdentityResolver()
        resolver.identities["com.apple.Music"] = identity("com.apple.Music", name: "音乐.app")
        let controller = makeController(provider: provider, resolver: resolver)
        controller.setPresented(true, placementID: "p1")

        provider.push(snapshot(bundleID: "com.apple.Music"))

        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.app?.displayName, "音乐.app")
        XCTAssertEqual(controller.app?.bundleIdentifier, "com.apple.Music")
    }

    func testProcessIdentifierIsForwardedForFallbackResolution() {
        let provider = FakeProvider()
        let resolver = FakeIdentityResolver()
        let controller = makeController(provider: provider, resolver: resolver)
        controller.setPresented(true, placementID: "p1")

        provider.push(snapshot(pid: 4711))

        XCTAssertEqual(resolver.requestedProcessIdentifiers.last ?? nil, 4711)
        XCTAssertNil(controller.app, "假解析器未命中，应退化为不带应用身份")
        XCTAssertEqual(controller.state, .playing, "身份取不到不影响播放态渲染")
    }

    func testPausedPushKeepsIdentity() {
        let provider = FakeProvider()
        let resolver = FakeIdentityResolver()
        resolver.identities["com.spotify.client"] = identity("com.spotify.client", name: "Spotify.app")
        let controller = makeController(provider: provider, resolver: resolver)
        controller.setPresented(true, placementID: "p1")

        provider.push(snapshot(isPlaying: false, bundleID: "com.spotify.client"))

        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.app?.displayName, "Spotify.app")
    }

    func testStoppingPlaybackClearsAppIdentity() {
        let provider = FakeProvider()
        let resolver = FakeIdentityResolver()
        resolver.identities["com.apple.Music"] = identity("com.apple.Music", name: "音乐.app")
        let controller = makeController(provider: provider, resolver: resolver)
        controller.setPresented(true, placementID: "p1")
        provider.push(snapshot(bundleID: "com.apple.Music"))

        provider.push(snapshot(hasMediaItem: false, isPlaying: nil))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.app)
    }

    func testBridgeFailureShowsUnavailableState() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)
        controller.setPresented(true, placementID: "p1")

        provider.push(.bridgeUnavailable)

        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertNil(controller.app)
    }

    func testAppIdentityEqualityIgnoresIcon() {
        let a = MediaAppIdentity(bundleIdentifier: "com.apple.Music", displayName: "音乐.app", icon: NSImage())
        let b = MediaAppIdentity(bundleIdentifier: "com.apple.Music", displayName: "音乐.app", icon: nil)

        XCTAssertEqual(a, b, "图标没有值语义，同一应用的两份身份必须视作未变化")
    }

    // MARK: 命令转发

    func testCommandsForwardWhileObserving() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)
        controller.setPresented(true, placementID: "p1")

        controller.previousTrack()
        controller.togglePlayPause()
        controller.nextTrack()

        XCTAssertEqual(provider.sentCommands, [.previousTrack, .togglePlayPause, .nextTrack])
    }

    func testCommandsRingFencedWhenNotObserving() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)
        controller.setPresented(true, placementID: "p1")
        controller.togglePlayPause()

        controller.setPresented(false, placementID: "p1")
        controller.togglePlayPause()
        controller.nextTrack()

        XCTAssertEqual(provider.sentCommands, [.togglePlayPause])
    }

    // MARK: 收尾

    func testLatePushesAfterStopAreDiscarded() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)
        controller.setPresented(true, placementID: "p1")

        controller.setPresented(false, placementID: "p1")
        provider.push(snapshot(bundleID: "com.apple.Music")) // 桥收尾时序不明时可能迟到

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.app)
    }

    func testSuspendStopsObservationAndIsIdempotent() {
        let provider = FakeProvider()
        let controller = makeController(provider: provider)
        controller.setPresented(true, placementID: "p1")

        controller.suspend()
        controller.suspend()

        XCTAssertFalse(controller.isObserving)
        XCTAssertEqual(provider.stopCount, 1)
        XCTAssertEqual(controller.state, .idle)

        // 重新呈现后仍能正常起观测（视图重新挂载走同一条路径）。
        controller.setPresented(true, placementID: "p1")
        XCTAssertTrue(controller.isObserving)
        XCTAssertEqual(provider.startCount, 2)
    }
}
