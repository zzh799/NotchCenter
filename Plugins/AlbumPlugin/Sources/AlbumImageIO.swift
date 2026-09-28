import AppKit
import ImageIO
import NotchCenterKit

// MARK: - 目标尺寸分档与缓存键

enum AlbumImageKey {
    /// 目标长边像素档位。块尺寸每变 1pt 就重新解码是浪费（拖拽时会连续触发），
    /// 归到档位后同一个文件在相邻尺寸间复用同一张位图。
    static let buckets = [256, 512, 1024, 2048, 4096]

    static func bucket(forPixel pixel: CGFloat) -> Int {
        guard pixel.isFinite, pixel > 0 else { return buckets[0] }
        return buckets.first { CGFloat($0) >= pixel } ?? buckets[buckets.count - 1]
    }

    static func key(for item: AlbumItemRef, bucket: Int) -> String {
        "\(item.kind.rawValue):\(item.identifier)|\(bucket)"
    }
}

// MARK: - 位图内存缓存

/// 降采样位图的内存缓存。
///
/// 三条纪律：**原图从不入内存**（进缓存的都是按显示尺寸降采样过的位图）；
/// **按字节成本计价**（`totalCostLimit` 才是真正的闸门，只限条数挡不住一张
/// 4096px 的位图）；**失败也缓存**（缺失/解码失败的键短期不再重试，目录里混着
/// 一堆坏文件时不会每次切图都去撞一次 IO）。
@MainActor
final class AlbumImageCache {
    static let shared = AlbumImageCache()

    private let images = NSCache<NSString, NSImage>()
    private let failures = NSCache<NSString, NSNull>()

    private init() {
        images.countLimit = 24
        images.totalCostLimit = 64 * 1024 * 1024
        failures.countLimit = 256
    }

    func image(forKey key: String) -> NSImage? {
        images.object(forKey: key as NSString)
    }

    func hasFailed(forKey key: String) -> Bool {
        failures.object(forKey: key as NSString) != nil
    }

    func store(_ image: NSImage, forKey key: String) {
        let rep = image.representations.first as? NSBitmapImageRep
        let cost = rep.map { $0.pixelsWide * $0.pixelsHigh * 4 }
            ?? Int(image.size.width * image.size.height * 4)
        images.setObject(image, forKey: key as NSString, cost: max(cost, 1))
        failures.removeObject(forKey: key as NSString)
    }

    func markFailed(forKey key: String) {
        failures.setObject(NSNull(), forKey: key as NSString)
    }

    /// 忘记所有失败。用户点刷新 / 换了来源时调用：文件可能已经回来了。
    func forgetFailures() {
        failures.removeAllObjects()
    }
}

// MARK: - 取图

/// 取一张图的唯一入口：先查缓存，未命中才真的解码/请求。
///
/// 本地文件走 ImageIO 的降采样（后台线程），图库资产走 `PHImageManager`
/// （它自带按 `targetSize` 的降采样）。两条路的结果都统一成 `CGImage`
/// ——它是可跨隔离域的值，`NSImage` 不是，统一成位图再回主线程包装。
@MainActor
enum AlbumImageLoader {
    /// - Parameter maxPixel: 显示长边 × 背板缩放，内部会归到档位。
    static func image(for item: AlbumItemRef, maxPixel: CGFloat) async -> NSImage? {
        let bucket = AlbumImageKey.bucket(forPixel: maxPixel)
        let key = AlbumImageKey.key(for: item, bucket: bucket)
        let cache = AlbumImageCache.shared
        if let cached = cache.image(forKey: key) { return cached }
        if cache.hasFailed(forKey: key) { return nil }

        let cgImage: CGImage?
        switch item.kind {
        case .localFile:
            cgImage = await decodeLocalFile(path: item.identifier, bucket: bucket)
        case .photosAsset:
            cgImage = await AlbumPhotoAccess.library.image(
                forAsset: item.identifier, maxPixel: CGFloat(bucket))
        }

        guard let cgImage else {
            cache.markFailed(forKey: key)
            return nil
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.store(image, forKey: key)
        return image
    }

    /// 预热（轮播切到当前张后顺手把下一张解出来，切换时就不会闪空）。
    static func prefetch(_ item: AlbumItemRef, maxPixel: CGFloat) async {
        _ = await image(for: item, maxPixel: maxPixel)
    }

    private static func decodeLocalFile(path: String, bucket: Int) async -> CGImage? {
        let url = URL(fileURLWithPath: path)
        return await Task.detached(priority: .userInitiated) {
            AlbumImageIO.downsampledImage(at: url, maxPixel: CGFloat(bucket))
        }.value
    }
}

// MARK: - ImageIO 降采样

enum AlbumImageIO {
    /// 把图片文件降采样到长边不超过 `maxPixel` 的位图（后台线程调用）。
    ///
    /// 三个选项缺一不可（同 ClipboardMediaStore 的配方）：`FromImageAlways` 忽略
    /// 文件内嵌的缩略图（那可能糊得没法看），`WithTransform` 按 EXIF 转正
    /// （否则竖拍照片会躺倒），`ThumbnailMaxPixelSize` 才是真正的降采样闸门。
    nonisolated static func downsampledImage(at url: URL, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
