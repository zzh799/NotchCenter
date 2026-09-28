import Foundation

// MARK: - 块标识

/// 本插件两个块的 id。来源的"形状"要与块匹配（集合型 vs 单体型），
/// 判定处集中在一处，免得散落的字符串字面量各自漂移。
enum AlbumBlock {
    static let carousel = "album.carousel"
    static let photo = "album.photo"
}

// MARK: - 图片来源

/// 一个块实例绑定的图片来源。
///
/// 持久化为 `placementStore` 里的 `config.*.source`（JSON，`{"type":…,"value":…}`）。
/// 编码刻意做成带判别字段的扁平结构而非 `Codable` 自动合成的嵌套形式：后者对
/// 关联值 enum 生成的形状随 Swift 版本浮动，而这份数据要长期躺在用户磁盘上
/// （同 `RemindersSource` 的取舍）。
///
/// **只存引用，不复制**：本地来源存绝对路径（App 未沙盒，不需要安全作用域书签，
/// 同 `ScratchpadStore`），图库来源存 PhotoKit 的 `localIdentifier`。本插件永不
/// 复制、移动、删除、改写用户原图。
enum AlbumSource: Equatable, Hashable, Sendable, Codable {
    /// 本地文件夹（轮播）。
    case localFolder(path: String)
    /// 本地图片文件（单张）。
    case localImageFile(path: String)
    /// 照片图库里的某个相册（轮播），值为 `PHAssetCollection.localIdentifier`。
    case photosAlbum(identifier: String)
    /// 照片图库里的某一张（单张），值为 `PHAsset.localIdentifier`。
    case photosAsset(identifier: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        switch type {
        case "localFolder":
            self = .localFolder(path: value)
        case "localImageFile":
            self = .localImageFile(path: value)
        case "photosAlbum":
            self = .photosAlbum(identifier: value)
        case "photosAsset":
            self = .photosAsset(identifier: value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown album source type: \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .localFolder(path):
            try container.encode("localFolder", forKey: .type)
            try container.encode(path, forKey: .value)
        case let .localImageFile(path):
            try container.encode("localImageFile", forKey: .type)
            try container.encode(path, forKey: .value)
        case let .photosAlbum(identifier):
            try container.encode("photosAlbum", forKey: .type)
            try container.encode(identifier, forKey: .value)
        case let .photosAsset(identifier):
            try container.encode("photosAsset", forKey: .type)
            try container.encode(identifier, forKey: .value)
        }
    }

    /// 是否来自照片图库（决定要不要先看权限、走 PhotoKit 取图）。
    var isFromPhotosLibrary: Bool {
        switch self {
        case .localFolder, .localImageFile: return false
        case .photosAlbum, .photosAsset: return true
        }
    }

    /// 集合型来源（可轮播出多张）还是单体型来源（只有一张）。
    var isCollection: Bool {
        switch self {
        case .localFolder, .photosAlbum: return true
        case .localImageFile, .photosAsset: return false
        }
    }

    /// 该块能否用这个来源。形状不匹配的一律拒收——把它显示出来只会得到
    /// 一个永远空着的块。
    static func accepts(_ source: AlbumSource, forBlock blockID: String) -> Bool {
        switch blockID {
        case AlbumBlock.carousel: return source.isCollection
        case AlbumBlock.photo: return !source.isCollection
        default: return false
        }
    }

    /// 本地来源的路径（设置面板展示用，`~` 缩写）；图库来源返回 nil。
    var localPath: String? {
        switch self {
        case let .localFolder(path), let .localImageFile(path):
            return (path as NSString).abbreviatingWithTildeInPath
        case .photosAlbum, .photosAsset:
            return nil
        }
    }

    /// 图库来源的标识符（相册 id 或资产 id）；本地来源返回 nil。
    var photosIdentifier: String? {
        switch self {
        case .localFolder, .localImageFile: return nil
        case let .photosAlbum(identifier), let .photosAsset(identifier): return identifier
        }
    }
}

// MARK: - 待显示的图

/// 一张图的纯值引用。**绝不把 `PHAsset` / `NSImage` 带出取图层**：跨隔离域、
/// 进数组、进视图只传这个可 `Sendable` 的小结构（同 `RemindersItem` 的取舍）。
struct AlbumItemRef: Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Equatable, Hashable, Sendable {
        /// 本地文件，`identifier` 是绝对路径。
        case localFile
        /// 照片图库资产，`identifier` 是 `PHAsset.localIdentifier`。
        case photosAsset
    }

    let kind: Kind
    let identifier: String
    /// 说明带用的名字：本地为文件名；图库为 nil（图库没有稳定的"文件名"）。
    let title: String?
    /// 图库资产的拍摄时间；本地为 nil（不为一个角标去多读一遍文件元数据）。
    let capturedAt: Date?

    var id: String { "\(kind.rawValue):\(identifier)" }

    static func localFile(path: String, title: String) -> AlbumItemRef {
        AlbumItemRef(kind: .localFile, identifier: path, title: title, capturedAt: nil)
    }

    static func photosAsset(identifier: String, capturedAt: Date?) -> AlbumItemRef {
        AlbumItemRef(kind: .photosAsset, identifier: identifier, title: nil, capturedAt: capturedAt)
    }
}
