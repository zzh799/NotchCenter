import Foundation

// MARK: - Now Playing 快照与可注入数据源

/// 当前 Now Playing 应用的身份。`bundleIdentifier` 可能缺失（播放器没向系统注册
/// bundle id），此时退化用 `processIdentifier` 反查运行中的应用。
struct NowPlayingClientIdentity: Equatable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
}

/// 一次观测得到的快照（纯值、可比较）。
///
/// 只保留本组件真正用得上的东西：桥是否可用、有没有媒体项、播放位、播放应用身份。
/// 曲目元数据（标题/歌手/封面）刻意不解码：参考图版式只展示媒体来源应用，多解一份
/// 大的封面 Data 只是白烧 CPU 与内存（桥那边也已用 `--no-artwork` 关掉）。
struct NowPlayingSnapshot: Equatable, Sendable {
    /// 桥本身不可用（资源缺失 / 子进程起不来或中途退出）。与「没有媒体」是两回事：
    /// 前者要显示降级空态，后者是正常空态。
    var bridgeFailed: Bool = false
    /// 系统是否登记了一个媒体项。
    var hasMediaItem: Bool = false
    /// 播放/暂停位（拿不到时按"在放"处理）。
    var isPlaying: Bool?
    /// 当前播放应用的身份（拿不到时为 nil）。
    var client: NowPlayingClientIdentity?

    static let bridgeUnavailable = NowPlayingSnapshot(bridgeFailed: true)
}

/// 展示状态（视图与控制器共用）。
enum MediaPlaybackState: Equatable, Sendable {
    /// 桥不可用 → 组件整体降级。
    case unavailable
    /// 桥可用，但当前没有任何媒体项。
    case idle
    /// 有媒体项且正在播放。
    case playing
    /// 有媒体项但已暂停。
    case paused
}

extension MediaPlaybackState {
    /// 由一次观测结果推导展示状态（纯函数，单测直接钉）。
    static func derive(from snapshot: NowPlayingSnapshot) -> MediaPlaybackState {
        guard !snapshot.bridgeFailed else { return .unavailable }
        guard snapshot.hasMediaItem else { return .idle }
        return (snapshot.isPlaying ?? true) ? .playing : .paused
    }

    /// 此刻有一个可控制的媒体项（播放中或暂停）：应用身份与控制按钮据此展示。
    var rendersMediaItem: Bool { self == .playing || self == .paused }
}

/// 媒体控制命令（取值 = 上游 MRACommand 对应的 MRCommand 编号，与桥的 `send` 对齐）。
enum MediaRemoteCommand: Int, Sendable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

/// Now Playing 数据源抽象：真实实现走 `MediaRemoteBridge`（/usr/bin/perl + helper
/// framework），测试注入假实现，状态机与降级路径的回归不触碰真实子进程。
///
/// 推送模型：桥自己会在状态变化时逐行输出，控制器不需要按秒轮询。
@MainActor
protocol NowPlayingProviding: AnyObject {
    /// 开始观测（幂等）。资源缺失或子进程起不来时立即回调 `bridgeUnavailable` 快照。
    func start(onChange: @escaping @MainActor (NowPlayingSnapshot) -> Void)
    /// 停止观测并终止子进程（幂等）。
    func stop()
    /// 投递控制命令；返回是否成功投递。
    @discardableResult
    func send(_ command: MediaRemoteCommand) -> Bool
}

/// 真实数据源：把桥的 stdout JSON 行翻译成快照。
@MainActor
final class LiveNowPlayingProvider: NowPlayingProviding {
    private let bridge: MediaRemoteBridge
    private var onChange: (@MainActor (NowPlayingSnapshot) -> Void)?

    init(bridge: MediaRemoteBridge = MediaRemoteBridge()) {
        self.bridge = bridge
    }

    func start(onChange: @escaping @MainActor (NowPlayingSnapshot) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        bridge.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .line(let line):
                self.onChange?(Self.decode(line))
            case .unavailable:
                self.onChange?(.bridgeUnavailable)
            }
        }
    }

    func stop() {
        onChange = nil
        bridge.stop()
    }

    func send(_ command: MediaRemoteCommand) -> Bool {
        bridge.send(commandID: command.rawValue)
    }

    /// 一行 stream 输出 → 快照。
    ///
    /// 行格式：`{"type":"data","diff":false,"payload":{…}}`；没有媒体时 payload 是空字典。
    /// 解码失败一律按「没有媒体」处理而不是「桥坏了」：线上格式漂移时宁可少显示，
    /// 也不要把组件打成不可用（那会让用户以为插件坏了）。
    static func decode(_ line: String) -> NowPlayingSnapshot {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return NowPlayingSnapshot() }

        let bundleIdentifier = payload["bundleIdentifier"] as? String
        let processIdentifier = (payload["processIdentifier"] as? NSNumber)?.int32Value
        let client = (bundleIdentifier != nil || processIdentifier != nil)
            ? NowPlayingClientIdentity(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            )
            : nil
        return NowPlayingSnapshot(
            hasMediaItem: !payload.isEmpty,
            isPlaying: payload["playing"] as? Bool,
            client: client
        )
    }
}
