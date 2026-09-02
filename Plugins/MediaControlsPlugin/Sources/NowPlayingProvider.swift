import Foundation

// MARK: - Now Playing 快照与可注入数据源

/// 一次轮询得到的「正在播放」快照（纯值、可比较）。
///
/// `Equatable` 有意忽略封面数据（大 Data 逐字节比较太贵）：封面的刷新由
/// 控制器按 `artworkKey` 单独判定，与文案/进度发布解耦。
struct NowPlayingSnapshot: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    /// 时长（秒）。
    var duration: TimeInterval?
    /// 已播放（秒）。
    var elapsed: TimeInterval?
    /// 播放/暂停位（查询失败为 nil）。
    var isPlaying: Bool?
    /// 封面图像数据（JPEG/PNG/TIFF，来源 App 决定）。
    var artworkData: Data?
    /// 媒体项唯一标识（探测换曲用；缺失时用「时长+标题」近似）。
    var uniqueID: String?

    init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval? = nil,
        isPlaying: Bool? = nil,
        artworkData: Data? = nil,
        uniqueID: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.artworkData = artworkData
        self.uniqueID = uniqueID
    }

    /// 是否有可展示的媒体项（无标题且无时长 → 没有在播放的东西）。
    var hasMediaItem: Bool {
        !(title?.isEmpty ?? true) || (duration != nil)
    }

    /// 换曲/内容变化探测键：变了说明是新的一首（封面、文案都应重置）。
    var trackKey: String {
        if let uniqueID, !uniqueID.isEmpty { return "id:\(uniqueID)" }
        return "t:\(title ?? "")\u{1F}d:\(duration ?? -1)"
    }

    static func == (lhs: NowPlayingSnapshot, rhs: NowPlayingSnapshot) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.elapsed == rhs.elapsed
            && lhs.isPlaying == rhs.isPlaying
            && lhs.uniqueID == rhs.uniqueID
    }
}

/// 快照解码：把 MediaRemote 返回的原始字典（键见 `NowPlayingInfoKey`，
/// 值可为 CFString/NSNumber/Data 桥接对象）翻译为 `NowPlayingSnapshot`。
/// 独立纯函数，供单元测试直接喂字典覆盖。
enum NowPlayingDecoder {
    static func snapshot(from info: [String: Any]) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: info[NowPlayingInfoKey.title] as? String,
            artist: info[NowPlayingInfoKey.artist] as? String,
            album: info[NowPlayingInfoKey.album] as? String,
            duration: (info[NowPlayingInfoKey.duration] as? NSNumber)?.doubleValue,
            elapsed: (info[NowPlayingInfoKey.elapsedTime] as? NSNumber)?.doubleValue,
            artworkData: info[NowPlayingInfoKey.artworkData] as? Data,
            uniqueID: info[NowPlayingInfoKey.uniqueIdentifier] as? String
        )
    }
}

/// 播放状态（视图与摘要共用）。
enum MediaPlaybackState: Equatable, Sendable {
    /// 私有框架不可用（只读也不支持）→ 整个插件降级。
    case unavailable
    /// 没有正在播放的媒体项。
    case idle
    /// 有媒体项且正在播放。
    case playing
    /// 有媒体项但已暂停。
    case paused
}

/// Now Playing 数据源抽象：真实实现走 `MediaRemoteSession`（私有框架），
/// 测试注入假数据源（状态机 / 降级路径回归，见 MediaControlsTests）。
@MainActor
protocol NowPlayingProviding: AnyObject {
    /// 是否支持只读观测（不支持时控制器直接进入 `.unavailable`）。
    var isObservationAvailable: Bool { get }
    /// 拉取一次最新快照（含播放位）；实现应在主线程回调。
    func refresh(completion: @escaping @MainActor (NowPlayingSnapshot) -> Void)
    /// 投递控制命令；返回是否成功投递。
    func send(_ command: MediaRemoteCommand) -> Bool
}

/// 真实数据源：私有框架适配器。取数全程在后台队列完成，仅在最终交付时跳回主线程。
@MainActor
final class LiveNowPlayingProvider: NowPlayingProviding {
    let isObservationAvailable: Bool = MediaRemoteSession.isObservationAvailable

    func refresh(completion: @escaping @MainActor (NowPlayingSnapshot) -> Void) {
        MediaRemoteSession.fetchNowPlayingInfo { info in
            let dict = (info as? [String: Any]) ?? [:]
            let decoded = NowPlayingDecoder.snapshot(from: dict)
            MediaRemoteSession.fetchIsPlaying { isPlaying in
                var merged = decoded
                merged.isPlaying = isPlaying
                Task { @MainActor in
                    completion(merged)
                }
            }
        }
    }

    func send(_ command: MediaRemoteCommand) -> Bool {
        MediaRemoteSession.send(command)
    }
}
