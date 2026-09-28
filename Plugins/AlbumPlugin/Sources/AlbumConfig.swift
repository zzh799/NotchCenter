import Foundation
import NotchCenterKit

// MARK: - 轮播间隔档位

/// 自动切换的间隔档位（秒）。3s 是"还能看清一张"的下限，60s 是上限；档位化而不是
/// 自由输入，免得用户填 0.5s 把解码拖垮。
///
/// 刻意**不放在 `AlbumConfigLogic` 里**：那个类型是 `@MainActor`（要读写 StateStore），
/// 而这里的常量被用作 `CarouselConfig` 的属性默认值——属性默认值在非隔离上下文求值，
/// 引用主执行者隔离的常量会被 Swift 6 直接判错。
enum AlbumIntervals {
    static let allowed: [Double] = [3, 5, 8, 15, 30, 60]
    static let fallback: Double = 8
}

// MARK: - 每实例配置

/// 轮播块配置。持久化在该实例的 `placementStore`（`config.carousel`）。
///
/// 每个字段都用 `decodeIfPresent ?? 默认值` 手写解码：这份 JSON 要长期躺在用户
/// 磁盘上，缺字段、旧版本文件、未来新增字段都不该让它整体失效。视图运行期状态
/// （当前第几张、是否暂停）**不在这里**，不落盘。
struct CarouselConfig: Codable, Equatable, Sendable {
    var version = 1
    var source: AlbumSource?
    var intervalSeconds = AlbumIntervals.fallback
    var randomOrder = false
    var recursive = false
    var fillsFrame = true
    var showsCaption = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, source, intervalSeconds, randomOrder, recursive, fillsFrame, showsCaption
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // 来源类型未知（未来版本写入的）解码会抛错，`try?` 把"抛错"与"键缺失"
        // 一起折成 nil，按"未配置"处理——比整份配置失效好，用户重选一次即可。
        source = try? container.decodeIfPresent(AlbumSource.self, forKey: .source)
        intervalSeconds =
            try container.decodeIfPresent(Double.self, forKey: .intervalSeconds)
            ?? AlbumIntervals.fallback
        randomOrder = try container.decodeIfPresent(Bool.self, forKey: .randomOrder) ?? false
        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        fillsFrame = try container.decodeIfPresent(Bool.self, forKey: .fillsFrame) ?? true
        showsCaption = try container.decodeIfPresent(Bool.self, forKey: .showsCaption) ?? true
    }
}

/// 单张照片块配置（`config.photo`）。解码口径同 `CarouselConfig`。
struct PhotoConfig: Codable, Equatable, Sendable {
    var version = 1
    var source: AlbumSource?
    var fillsFrame = true
    var showsCaption = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, source, fillsFrame, showsCaption
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        source = try? container.decodeIfPresent(AlbumSource.self, forKey: .source)
        fillsFrame = try container.decodeIfPresent(Bool.self, forKey: .fillsFrame) ?? true
        showsCaption = try container.decodeIfPresent(Bool.self, forKey: .showsCaption) ?? true
    }
}

// MARK: - 配置读写（纯逻辑，可直接单测）

@MainActor
enum AlbumConfigLogic {
    static let carouselStoreKey = "config.carousel"
    static let photoStoreKey = "config.photo"

    /// 间隔取最近档位；非法值（NaN / 负数 / 巨值）回默认。
    /// 纯函数，非隔离——它不碰 store，没必要被主执行者绑住。
    nonisolated static func sanitizeInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return AlbumIntervals.fallback }
        let allowed = AlbumIntervals.allowed
        let clamped = min(max(seconds, allowed[0]), allowed[allowed.count - 1])
        return allowed.min { abs($0 - clamped) < abs($1 - clamped) } ?? AlbumIntervals.fallback
    }

    /// 丢掉与块形状不匹配的来源（例如用户先配了轮播再改成单张块）。
    nonisolated static func sanitize(source: AlbumSource?, forBlock blockID: String) -> AlbumSource? {
        guard let source, AlbumSource.accepts(source, forBlock: blockID) else { return nil }
        return source
    }

    static func loadCarousel(from store: StateStore?) -> CarouselConfig {
        guard let store else { return CarouselConfig() }
        var config = store.object(CarouselConfig.self, forKey: carouselStoreKey) ?? CarouselConfig()
        config.intervalSeconds = sanitizeInterval(config.intervalSeconds)
        config.source = sanitize(source: config.source, forBlock: AlbumBlock.carousel)
        return config
    }

    static func loadPhoto(from store: StateStore?) -> PhotoConfig {
        guard let store else { return PhotoConfig() }
        var config = store.object(PhotoConfig.self, forKey: photoStoreKey) ?? PhotoConfig()
        config.source = sanitize(source: config.source, forBlock: AlbumBlock.photo)
        return config
    }

    static func save(_ config: CarouselConfig, to store: StateStore?) {
        try? store?.setObject(config, forKey: carouselStoreKey)
    }

    static func save(_ config: PhotoConfig, to store: StateStore?) {
        try? store?.setObject(config, forKey: photoStoreKey)
    }

    /// 实例被移除时清掉它的持久化配置。
    static func clearCarousel(from store: StateStore?) {
        store?.removeValue(forKey: carouselStoreKey)
    }

    static func clearPhoto(from store: StateStore?) {
        store?.removeValue(forKey: photoStoreKey)
    }
}
