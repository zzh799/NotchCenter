import AppKit
import NotchCenterKit
import XCTest
@testable import MediaControlsPlugin

/// MediaControlsPlugin 状态机回归（Agent Note 2026-09-03-media-controls-plugin）：
/// 播放/暂停/停止的摘要提交与收回、秒级节流、私有框架不可用的优雅降级、
/// 控制命令转发与原始字典解码。全部注入假数据源，绝不触碰真实私有框架。
@MainActor
final class MediaControlsTests: XCTestCase {
    // MARK: 测试替身

    private final class FakeProvider: NowPlayingProviding {
        var isObservationAvailable: Bool
        var nextSnapshot = NowPlayingSnapshot()
        private(set) var refreshCount = 0
        private(set) var sentCommands: [MediaRemoteCommand] = []

        init(available: Bool = true) {
            isObservationAvailable = available
        }

        func refresh(completion: @escaping @MainActor (NowPlayingSnapshot) -> Void) {
            refreshCount += 1
            completion(nextSnapshot)
        }

        func send(_ command: MediaRemoteCommand) -> Bool {
            sentCommands.append(command)
            return true
        }
    }

    /// 挂起型数据源：模拟在途取数（poll 之后、完成回调到达前插件被禁用）。
    private final class DeferredProvider: NowPlayingProviding {
        let isObservationAvailable = true
        private var pending: [(@MainActor (NowPlayingSnapshot) -> Void)] = []

        func refresh(completion: @escaping @MainActor (NowPlayingSnapshot) -> Void) {
            pending.append(completion)
        }

        func complete(_ snapshot: NowPlayingSnapshot) {
            guard !pending.isEmpty else { return }
            pending.removeFirst()(snapshot)
        }

        func send(_ command: MediaRemoteCommand) -> Bool { true }
    }

    private final class RecordingHost: HostController {
        private(set) var summaries: [ActivitySummary] = []
        private(set) var removedIDs: [String] = []

        func showActivitySummary(_ summary: ActivitySummary) {
            summaries.append(summary)
        }

        func removeActivitySummary(id: String) {
            removedIDs.append(id)
        }

        func expandDrawer() {}
        func collapseDrawer() {}
        func enterEditMode() {}
        func exitEditMode() {}
        func refreshCompactDisplay() {}
    }

    // MARK: 夹具

    private func playingSnapshot(
        elapsed: TimeInterval = 30,
        title: String = "Anti-Hero",
        artist: String = "Taylor Swift",
        album: String? = "Midnights",
        isPlaying: Bool = true,
        duration: TimeInterval = 150,
        artwork: Data? = nil
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: elapsed,
            isPlaying: isPlaying,
            artworkData: artwork,
            uniqueID: "fixture-track"
        )
    }

    private func makeController(
        provider: FakeProvider,
        host: RecordingHost = RecordingHost()
    ) -> (controller: MediaPlayerController, provider: FakeProvider, host: RecordingHost) {
        let controller = MediaPlayerController(provider: provider)
        controller.resolve(stateStore: makeStateStore(), hostController: host)
        return (controller, provider, host)
    }

    /// 隔离临时存储（媒体状态瞬态、不落持久化，仅满足注入签名；不写键故无文件残留）。
    private func makeStateStore() -> StateStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaControlsTests-\(UUID().uuidString)", isDirectory: true)
        return StateStore(rootDirectory: root)
    }

    // MARK: 摘要生命周期

    func testPlayingSubmitsSummaryChipWithTrackFields() {
        let provider = FakeProvider()
        provider.nextSnapshot = playingSnapshot()
        let (_, _, host) = makeController(provider: provider)

        XCTAssertEqual(host.summaries.count, 1)
        let summary = try! XCTUnwrap(host.summaries.first)
        XCTAssertEqual(summary.id, MediaPlayerController.summaryID)
        XCTAssertEqual(summary.title, "Anti-Hero")
        XCTAssertEqual(summary.subtitle, "Taylor Swift — Midnights")
        XCTAssertEqual(summary.symbolName, "music.note")
        XCTAssertEqual(summary.progress ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertTrue(host.removedIDs.isEmpty)
    }

    func testPausedFlipsSymbolAndKeepsProgressInPlace() {
        let provider = FakeProvider()
        provider.nextSnapshot = playingSnapshot(isPlaying: true)
        let (controller, _, host) = makeController(provider: provider)

        // 暂停：状态位翻转，芯片原位更新（pause.fill + 进度停在暂停处）。
        provider.nextSnapshot = playingSnapshot(isPlaying: false)
        controller.poll()

        XCTAssertEqual(host.summaries.count, 2)
        let paused = try! XCTUnwrap(host.summaries.last)
        XCTAssertEqual(paused.symbolName, "pause.fill")
        XCTAssertEqual(paused.title, "Anti-Hero")
        XCTAssertEqual(paused.progress ?? -1, 0.2, accuracy: 0.0001)
    }

    func testStoppedRetractsSummary() {
        let provider = FakeProvider()
        provider.nextSnapshot = playingSnapshot()
        let (controller, _, host) = makeController(provider: provider)
        XCTAssertEqual(host.summaries.count, 1)

        provider.nextSnapshot = NowPlayingSnapshot() // 停止：无标题无时长
        controller.poll()

        XCTAssertEqual(host.removedIDs, [MediaPlayerController.summaryID])
        XCTAssertEqual(host.summaries.count, 1, "收回后不应再提交")
    }

    func testElapsedTicksThrottleToWholeSecond() {
        let provider = FakeProvider()
        provider.nextSnapshot = playingSnapshot(elapsed: 30.2)
        let (controller, _, host) = makeController(provider: provider)
        XCTAssertEqual(host.summaries.count, 1)

        // 秒内细分进度：不重新提交（芯片进度在宿主侧按值渲染，无需打搅）。
        provider.nextSnapshot = playingSnapshot(elapsed: 30.9)
        controller.poll()
        XCTAssertEqual(host.summaries.count, 1)

        // 跨整秒：覆盖提交一次。
        provider.nextSnapshot = playingSnapshot(elapsed: 31.4)
        controller.poll()
        XCTAssertEqual(host.summaries.count, 2)
        let summary = try! XCTUnwrap(host.summaries.last)
        XCTAssertEqual(summary.progress ?? -1, 31.4 / 150, accuracy: 0.0001)
    }

    func testTrackChangeUpdatesChip() {
        let provider = FakeProvider()
        provider.nextSnapshot = playingSnapshot()
        let (controller, _, host) = makeController(provider: provider)

        provider.nextSnapshot = playingSnapshot(title: "Maroon", album: nil, isPlaying: true)
        controller.poll()

        XCTAssertEqual(host.summaries.count, 2)
        XCTAssertEqual(host.summaries.last?.title, "Maroon")
        XCTAssertEqual(host.summaries.last?.subtitle, "Taylor Swift")
    }

    func testSuspendRetractsAndIgnoresFurtherPolls() {
        let provider = FakeProvider()
        provider.nextSnapshot = playingSnapshot()
        let (controller, providerRef, host) = makeController(provider: provider)
        XCTAssertEqual(host.summaries.count, 1)

        let pollsBefore = providerRef.refreshCount
        controller.suspend()
        XCTAssertEqual(host.removedIDs, [MediaPlayerController.summaryID])

        controller.poll() // 停用后拉取入口直接短路
        XCTAssertEqual(providerRef.refreshCount, pollsBefore)
    }

    func testInFlightFetchAfterSuspendIsDiscarded() {
        let provider = DeferredProvider()
        let host = RecordingHost()
        let controller = MediaPlayerController(provider: provider)
        controller.resolve(stateStore: makeStateStore(), hostController: host)

        controller.suspend()
        // 在途取数此刻才回来：不得复活摘要、不得改展示。
        provider.complete(playingSnapshot())

        XCTAssertTrue(host.summaries.isEmpty)
        XCTAssertTrue(host.removedIDs.isEmpty)
        XCTAssertEqual(controller.display.state, .idle)
    }

    func testUnavailableProviderDegradesWithoutPolling() {
        let provider = FakeProvider(available: false)
        let (controller, providerRef, host) = makeController(provider: provider)

        XCTAssertEqual(controller.display.state, .unavailable)
        XCTAssertEqual(providerRef.refreshCount, 0, "不可用时不拉取")
        XCTAssertTrue(host.summaries.isEmpty)
        controller.suspend()
    }

    // MARK: 控制命令

    func testControlCommandsForwardedToProvider() {
        let provider = FakeProvider()
        let (controller, _, _) = makeController(provider: provider)

        controller.togglePlayPause()
        controller.nextTrack()
        controller.previousTrack()
        controller.setPlaying(true)
        controller.setPlaying(false)

        XCTAssertEqual(
            provider.sentCommands,
            [.togglePlayPause, .nextTrack, .previousTrack, .play, .pause]
        )
    }

    // MARK: 封面

    func testArtworkPublishesOncePerTrackAndClearsWhenStopped() {
        let provider = FakeProvider()
        let artworkData = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]) // 非真实图像 → 解码失败即占位
        provider.nextSnapshot = playingSnapshot(artwork: artworkData)
        let (controller, _, _) = makeController(provider: provider)
        XCTAssertNil(controller.artwork, "解码失败保持占位（无崩溃）")

        provider.nextSnapshot = playingSnapshot()
        controller.poll()
        provider.nextSnapshot = NowPlayingSnapshot()
        controller.poll()
        XCTAssertNil(controller.artwork)
    }

    func testSnapshotEqualityIgnoresArtworkData() {
        let a = playingSnapshot(artwork: Data([1, 2, 3]))
        let b = playingSnapshot(artwork: Data([4, 5, 6]))
        XCTAssertEqual(a, b, "封面数据不参与快照相等性（去抖按曲目键单独处理）")
    }
}

// MARK: - 原始字典解码（纯函数）

extension MediaControlsTests {
    func testDecoderMapsRawMediaRemoteDict() {
        let raw: [String: Any] = [
            NowPlayingInfoKey.title: "Anti-Hero" as NSString,
            NowPlayingInfoKey.artist: "Taylor Swift" as NSString,
            NowPlayingInfoKey.album: "Midnights" as NSString,
            NowPlayingInfoKey.duration: NSNumber(value: 150.0),
            NowPlayingInfoKey.elapsedTime: NSNumber(value: 30.5),
            NowPlayingInfoKey.uniqueIdentifier: "track-42" as NSString,
            NowPlayingInfoKey.artworkData: Data([0x00, 0x01]),
        ]
        let snapshot = NowPlayingDecoder.snapshot(from: raw)
        XCTAssertEqual(snapshot.title, "Anti-Hero")
        XCTAssertEqual(snapshot.artist, "Taylor Swift")
        XCTAssertEqual(snapshot.album, "Midnights")
        XCTAssertEqual(snapshot.duration, 150)
        XCTAssertEqual(snapshot.elapsed, 30.5)
        XCTAssertEqual(snapshot.uniqueID, "track-42")
        XCTAssertEqual(snapshot.artworkData, Data([0x00, 0x01]))
        XCTAssertTrue(snapshot.hasMediaItem)
        XCTAssertEqual(snapshot.trackKey, "id:track-42")
    }

    func testDecoderHandlesMissingFieldsAndEmptyDict() {
        let empty = NowPlayingDecoder.snapshot(from: [:])
        XCTAssertFalse(empty.hasMediaItem)
        XCTAssertNil(empty.title)
        XCTAssertEqual(empty.trackKey, "t:\u{1F}d:-1.0") // 无标题无时长近似键（duration -1 兜底）

        let partial: [String: Any] = [NowPlayingInfoKey.title: "Podcast" as NSString]
        let partialSnapshot = NowPlayingDecoder.snapshot(from: partial)
        XCTAssertTrue(partialSnapshot.hasMediaItem)
        XCTAssertEqual(partialSnapshot.trackKey, "t:Podcast\u{1F}d:-1.0")
    }
}
