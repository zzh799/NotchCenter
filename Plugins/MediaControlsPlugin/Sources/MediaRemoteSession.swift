import Foundation

// MARK: - MediaRemote 私有框架会话（dlopen/dlsym 单层封装）
//
// macOS 没有公开 API 控制系统其他应用（Spotify / Music / 浏览器等）的播放，
// 只能访问私有框架 MediaRemote。本类型是**唯一的私有 API 接触面**：
// - dlopen + dlsym 惰性解析符号，失败即整体不可用（插件优雅降级，绝不崩溃）；
// - 只读观测：`fetchNowPlayingInfo` / `fetchIsPlaying`（异步回调）；
// - 控制：`send(_:)`（播放/暂停/上下曲）。
//
// 符号与命令值以 macOS 私有头（theos/macOS_headers 的 MediaRemote.h）为准，
// 本机（macOS 15.x）实测导出的**无下划线**现代符号：
//   MRMediaRemoteGetNowPlayingInfo / MRMediaRemoteGetNowPlayingApplicationIsPlaying /
//   MRMediaRemoteSendCommand / MRMediaRemoteRegisterForNowPlayingNotifications。
// 旧式 `_MR…` 前导下划线符号已不再导出，勿回退使用。
//
// Now Playing 字典的键以字面量访问（kMRMediaRemoteNowPlayingInfo* 常量取值
// 与名称一致，公开样例均按下标字面量取用；这些常量符号未可靠导出，不去 dlsym）。

/// 系统媒体控制命令（MRMediaRemoteCommand 枚举取值，仅收窄到本插件用到的子集）。
enum MediaRemoteCommand: Int, Sendable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

/// Now Playing 信息字典键（取值 = 名称，字面量访问）。
enum NowPlayingInfoKey {
    static let title = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
    static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let uniqueIdentifier = "kMRMediaRemoteNowPlayingInfoUniqueIdentifier"
}

/// 私有框架函数指针签名（严格按头文件声明，避免调用约定失配）。
private typealias InfoFn = @convention(c) (
    DispatchQueue,
    @escaping @convention(block) (CFDictionary?) -> Void
) -> Void
private typealias IsPlayingFn = @convention(c) (
    DispatchQueue,
    @escaping @convention(block) (UInt8) -> Void
) -> Void
/// C `Boolean`（unsigned char）返回值：非零 = 命令已投递。
private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> UInt8

final class MediaRemoteSession: @unchecked Sendable {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    nonisolated(unsafe) private static var loadedHandle: UnsafeMutableRawPointer?

    private static func handle() -> UnsafeMutableRawPointer? {
        if let loadedHandle { return loadedHandle }
        let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_GLOBAL)
        loadedHandle = handle
        return handle
    }

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = handle() else { return nil }
        return dlsym(handle, name)
    }

    /// 私有框架是否可观测（核心符号在即为可用；控制符号缺失时只读仍可用）。
    static var isObservationAvailable: Bool {
        symbol("MRMediaRemoteGetNowPlayingInfo") != nil
    }

    /// 仅用于单元测试注入故障：清掉已缓存的句柄，下次调用重新 dlopen/dlsym。
    static func resetForTesting() {
        loadedHandle = nil
    }

    // MARK: 只读观测

    /// 异步取当前 Now Playing 信息字典；失败（框架不可用 / 无回调）时为 nil。
    /// 回调一定发生：超时由调用方节流与快照比较兜底，不额外加锁等待。
    static func fetchNowPlayingInfo(
        completion: @escaping @Sendable (CFDictionary?) -> Void
    ) {
        guard let pointer = symbol("MRMediaRemoteGetNowPlayingInfo") else {
            completion(nil)
            return
        }
        let fn = unsafeBitCast(pointer, to: InfoFn.self)
        fn(DispatchQueue.global(qos: .utility)) { info in
            completion(info)
        }
    }

    /// 异步取「当前 Now Playing 应用是否正在播放」；失败时为 nil。
    static func fetchIsPlaying(
        completion: @escaping @Sendable (Bool?) -> Void
    ) {
        guard let pointer = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            completion(nil)
            return
        }
        let fn = unsafeBitCast(pointer, to: IsPlayingFn.self)
        fn(DispatchQueue.global(qos: .utility)) { raw in
            completion(raw != 0)
        }
    }

    // MARK: 控制

    /// 投递媒体控制命令；返回是否成功投递（框架不可用 / 无响应为 false）。
    /// 头文件签名 `Boolean MRMediaRemoteSendCommand(MRMediaRemoteCommand, NSDictionary *)`。
    static func send(_ command: MediaRemoteCommand) -> Bool {
        guard let pointer = symbol("MRMediaRemoteSendCommand") else { return false }
        let fn = unsafeBitCast(pointer, to: SendCommandFn.self)
        return fn(Int32(command.rawValue), nil) != 0
    }
}
