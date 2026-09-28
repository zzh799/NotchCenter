import AppKit
import Photos

// MARK: - 图库相册（纯值描述）

/// 照片图库里一个相册的可见信息（设置面板列表用，纯值）。
struct AlbumAlbumRef: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// `PHAssetCollection.estimatedAssetCount`；系统给不出快速估算时为 nil。
    let assetCount: Int?
    /// 智能相册（最近项目 / 个人收藏 / 截屏…），列表里单独分组。
    let isSmart: Bool
}

// MARK: - 读取口

/// 照片图库的读取口。生产实现是 PhotoKit，测试注入假实现。
///
/// **本层不做授权判断、更不触发任何 TCC 弹窗**：授权状态由宿主的「权限管理」通道
/// 统一裁决（`HostController.permissionStatus(of: .photos)`），插件只在这条通道
/// 报告"可用"之后才来读；未授权时 `fetch*` 本身也只返回空集，不会弹窗。
@MainActor
protocol AlbumPhotoLibraryProtocol: AnyObject {
    func albums() -> [AlbumAlbumRef]
    func albumTitle(forIdentifier identifier: String) -> String?
    func items(inAlbum identifier: String, limit: Int) -> [AlbumItemRef]
    /// 资产还在不在（单张来源探活用）：不在就返回 nil，块据此落到"来源已不在原位"。
    func asset(identifier: String) -> AlbumItemRef?
    func image(forAsset identifier: String, maxPixel: CGFloat) async -> CGImage?
}

/// 图库读取口的注入点。生产指向 PhotoKit 实现；单测换成假实现，于是单测
/// 既不需要真图库，也绝不会碰到授权弹窗（这是权限红线的硬要求）。
@MainActor
enum AlbumPhotoAccess {
    static var library: (any AlbumPhotoLibraryProtocol) = AlbumPhotoLibrary.shared
}

// MARK: - PhotoKit 实现

@MainActor
final class AlbumPhotoLibrary: AlbumPhotoLibraryProtocol {
    static let shared = AlbumPhotoLibrary()

    /// 单个相册最多取多少张（同目录扫描的上限口径）。
    static let maxAssetsPerAlbum = 500

    /// 列进"整库/精选"的智能相册。
    ///
    /// 刻意只挑这几档：`.any` 会把"视频 / 慢动作 / 延时摄影 / 全景"一并列出，而这些
    /// 相册在本插件里只会得到空列表（我们只取静帧图片）。"隐藏"相册同理不列——
    /// 用户把照片藏起来就是不希望它出现在别处。
    private static let smartSubtypes: [PHAssetCollectionSubtype] = [
        .smartAlbumUserLibrary,  // 最近项目（等同于整个图库）
        .smartAlbumFavorites,  // 个人收藏
        .smartAlbumScreenshots,  // 截屏
        .smartAlbumLivePhotos,  // 实况照片（取其中的关键静帧）
    ]

    private init() {}

    func albums() -> [AlbumAlbumRef] {
        var refs: [AlbumAlbumRef] = []
        for subtype in Self.smartSubtypes {
            let fetched = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil)
            for index in 0..<fetched.count {
                if let ref = Self.ref(from: fetched.object(at: index), isSmart: true) {
                    refs.append(ref)
                }
            }
        }

        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        var userRefs: [AlbumAlbumRef] = []
        for index in 0..<userAlbums.count {
            if let ref = Self.ref(from: userAlbums.object(at: index), isSmart: false) {
                userRefs.append(ref)
            }
        }
        // 用户相册按标题排序：PhotoKit 的返回序没有文档承诺，列表每次打开都换位置
        // 会让人怀疑自己选错了。
        userRefs.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        refs.append(contentsOf: userRefs)
        return refs
    }

    func albumTitle(forIdentifier identifier: String) -> String? {
        PHAssetCollection
            .fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
            .firstObject?
            .localizedTitle
    }

    func items(inAlbum identifier: String, limit: Int) -> [AlbumItemRef] {
        guard let collection = PHAssetCollection
            .fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
            .firstObject
        else { return [] }

        let options = PHFetchOptions()
        // 新的在前：与照片.app 的默认序一致，也让"最近项目"这个最常用的来源
        // 一打开就是最近拍的。
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = limit

        let assets = PHAsset.fetchAssets(in: collection, options: options)
        var refs: [AlbumItemRef] = []
        refs.reserveCapacity(assets.count)
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            refs.append(
                AlbumItemRef.photosAsset(
                    identifier: asset.localIdentifier, capturedAt: asset.creationDate))
        }
        return refs
    }

    func asset(identifier: String) -> AlbumItemRef? {
        guard let asset = PHAsset
            .fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            .firstObject
        else { return nil }
        // 视频不显示：单张来源如果指向一段视频，与其给它一个空块，不如按"来源不可用"
        // 提示用户重选。
        guard asset.mediaType == .image else { return nil }
        return AlbumItemRef.photosAsset(
            identifier: asset.localIdentifier, capturedAt: asset.creationDate)
    }

    func image(forAsset identifier: String, maxPixel: CGFloat) async -> CGImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        // 只要最终那一帧：默认的 opportunistic 会先交一张降级图再交高质量图，
        // 回调被调多次而 continuation 只能 resume 一次。选单帧模式就不用做
        // "只认最后一帧"的过滤，也不用为了取消去维护请求 id 的状态机。
        options.deliveryMode = .highQualityFormat
        // 精确尺寸而非 `.fast`（后者把 targetSize 当"提示"，可能交付大得多的图）：
        // 内存上界要可预测，这是缓存按字节计价的立论基础。
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let target = CGSize(width: maxPixel, height: maxPixel)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(
                    returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private static func ref(from collection: PHAssetCollection, isSmart: Bool) -> AlbumAlbumRef? {
        let estimated = collection.estimatedAssetCount
        // 估算为 0 的相册直接不列：选它只会得到一个空块。`NSNotFound` 表示
        // 系统没给出快速估算（不等于空），照常列出。
        if estimated == 0 { return nil }
        guard let title = collection.localizedTitle, !title.isEmpty else { return nil }
        return AlbumAlbumRef(
            id: collection.localIdentifier,
            title: title,
            assetCount: estimated == NSNotFound ? nil : estimated,
            isSmart: isSmart)
    }
}
