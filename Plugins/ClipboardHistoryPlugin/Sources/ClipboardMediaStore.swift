import AppKit
import CryptoKit
import Foundation
import NotchCenterKit
import UniformTypeIdentifiers

/// 剪贴板富媒体的磁盘存储：原图 + 缩略图。
///
/// 目录是 `<pluginData>/Media/`（经 `StateStore.resourceDirectory(named:)`），扁平一层。
/// 命名 `<uuid>.<ext>`（原图，**原始字节不重编码**）与 `<uuid>.<ext>.thumb.png`（缩略图）。
/// 缩略图文件名以原图名为前缀，是为了让"孤儿对账"能用同一个引用键同时覆盖两个文件。
///
/// **为什么不要 manifest**：笔记的 `NotesImageStore` 需要它，是因为
/// `EmbeddedImageRequest` 只带 id / name、必须反向查 displayName 与原路径；剪贴板条目
/// 自己持有 `storedMediaName`，没有反向查找需求，清单只会多一份要跟着同步的状态。
///
/// **为什么缩略图单独落盘**（决策记录 `2026-09-20-clipboard-media-types` 的 D5）：
/// 列表渲染时现解码原图会让抽屉直接卡死——`LazyVStack` 一次物化十来行，每行解一张
/// 数 MB 的 PNG。缩略图走 `CGImageSource` 的降采样接口，不解全图。
///
/// 线程约定：目录 URL 在 init（主线程）取好，之后文件 IO 全在锁保护下进行，
/// 允许后台线程调用——与 `NotesImageStore` 的 `@unchecked Sendable` + `NSLock` 同款。
final class ClipboardMediaStore: @unchecked Sendable {
    /// 缩略图长边像素。
    ///
    /// 定在 **512** 是为了覆盖预览卡最大显示边长（256pt）在 Retina 下的 2× 需求：列表行
    /// （32×20）、长按预览、悬浮预览共用这一份，原图只在写回时被读。调小它预览就会发软，
    /// 调大只是白占磁盘与内存（决策记录 2026-09-20-clipboard-hover-preview 的 D5）。
    static let thumbnailMaxPixelSize = 512

    /// 缩略图文件名后缀（与原图共用一个引用键）。
    static let thumbnailSuffix = ".thumb.png"

    /// 未知格式的兜底扩展名：宁可存成 `.bin` 也不猜。
    private static let fallbackExtension = "bin"

    private let directoryURL: URL
    private let lock = NSLock()

    /// 仅在主线程创建（`resourceDirectory(named:)` 是 `@MainActor`）。
    init(stateStore: StateStore) throws {
        directoryURL = try MainActor.assumeIsolated {
            try stateStore.resourceDirectory(named: "Media")
        }
    }

    // MARK: 写入

    /// 落盘原始字节并生成缩略图；返回条目要记的 `storedMediaName`，失败返回 nil。
    ///
    /// 先写原图再写缩略图：缩略图失败不算致命（列表退化成占位图），原图失败才放弃
    /// ——那意味着写回时拿不到数据，条目留着也是废的。
    func store(data: Data, uti: String?) -> String? {
        // 与同文件其它 IO 一致加锁：本方法现在从轮询专用队列调用，与主线程的
        // 读取/写回/对账并发（决策见 2026-09-28-plugin-audit-backlog-fixes）。
        lock.lock()
        defer { lock.unlock() }
        let name = "\(UUID().uuidString).\(Self.fileExtension(for: uti, data: data))"
        do {
            try data.write(to: originalURL(forStoredName: name), options: .atomic)
        } catch {
            return nil
        }
        if let thumbnail = Self.thumbnailPNG(from: data) {
            try? thumbnail.write(to: thumbnailURL(forStoredName: name), options: .atomic)
        }
        return name
    }

    // MARK: 读取与删除

    func data(forStoredName name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: originalURL(forStoredName: name))
    }

    /// 原图路径。纯字符串拼接、不碰文件系统，因此不加锁：视图层在每次 body 求值时
    /// 逐行取它，校验存在性会变成每行一次 syscall（缺失由读取缓存记账兜住）。
    func originalURL(forStoredName name: String) -> URL {
        directoryURL.appendingPathComponent(name)
    }

    func thumbnailURL(forStoredName name: String) -> URL {
        directoryURL.appendingPathComponent(name + Self.thumbnailSuffix)
    }

    /// 删除原图与缩略图（幂等）。传空集直接返回，避免无谓的加锁与系统调用。
    func remove(storedNames: Set<String>) {
        guard !storedNames.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for name in storedNames {
            try? FileManager.default.removeItem(at: originalURL(forStoredName: name))
            try? FileManager.default.removeItem(at: thumbnailURL(forStoredName: name))
        }
    }

    /// 启动孤儿对账：删掉不在 `referenced` 里的所有文件。
    ///
    /// 为什么需要它：只靠"条目被删时顺带删文件"兜不住"写完文件、还没 persist 条目
    /// 就崩"的窗口期，留下的孤儿永远不会被任何人引用。一次目录扫描的成本可以忽略，
    /// 而漏掉它意味着数据目录只增不减。
    func reconcile(referenced: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            let name = url.lastPathComponent
            let owner = name.hasSuffix(Self.thumbnailSuffix)
                ? String(name.dropLast(Self.thumbnailSuffix.count))
                : name
            guard !referenced.contains(owner) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: 内容哈希

    /// 图片条目的去重身份：原始字节的 SHA256 十六进制串。
    ///
    /// 放在这里而不是 `ClipboardHistoryLogic`：那个文件刻意不依赖平台哈希库，
    /// 以保证纯逻辑层在无 CryptoKit 的环境里也能编译与单测。
    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 内部

    /// 扩展名优先由 UTI 反查，其次嗅探魔数；两者都不认时用 `bin`。
    ///
    /// 不做"统一转成 png"这类格式收敛：写回的契约是把用户当时复制的东西原样放回，
    /// 重编码既毁契约又会让 JPEG 来源的图片膨胀。
    private static func fileExtension(for uti: String?, data: Data) -> String {
        if let uti, let type = UTType(uti), let ext = type.preferredFilenameExtension {
            return ext
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "tiff"
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: Array("GIF8".utf8)) { return "gif" }
        return fallbackExtension
    }

    /// 长边降到 `thumbnailMaxPixelSize` 的 PNG。
    ///
    /// `WithTransform` 让 EXIF 方向生效（手机拍的照片否则会躺倒）；
    /// `FromImageAlways` 保证即便原图内嵌了缩略图也重新降采样，避免拿到糊的旧图。
    private static func thumbnailPNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
    }
}
