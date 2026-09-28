import Foundation
import UniformTypeIdentifiers

// MARK: - 目录扫描结果

/// 扫描一个本地文件夹的三种结局。三者必须分开，因为块的呈现完全不同：
/// "空文件夹"提示换目录，"来源丢失"提示重选，"读不了"要指向 TCC 放行。
enum AlbumFolderOutcome: Equatable, Sendable {
    case found([AlbumItemRef])
    case missing
    case unreadable
}

// MARK: - 本地文件夹来源

enum AlbumFolderScan {
    /// 一个目录最多取多少张。上限是内存与枚举耗时的闸门，不是"用户不该有更多
    /// 照片"：按默认 8s 一轮，500 张也要一小时才走完。
    static let maxFiles = 500

    /// 扫描目录（**在后台任务里调用**：这是逐条目的文件系统 IO）。
    ///
    /// 只读目录条目的名字与扩展名，不读文件内容、不碰文件大小/时间等元数据——
    /// 图片判定走 `UTType` 的内存查表，逐文件 stat 在大目录上是纯粹的浪费。
    /// 递归模式的错误处理是"尽力而为"：读不出的子树被跳过，其余照常返回。
    nonisolated static func scan(folderPath: String, recursive: Bool) -> AlbumFolderOutcome {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missing
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return .unreadable }
            var urls: [URL] = []
            for case let url as URL in enumerator {
                urls.append(url)
                if urls.count >= maxFiles * 4 { break }
            }
            return .found(selectImages(from: urls))
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            return .found(selectImages(from: urls))
        } catch {
            // 目录确实存在却列不出来：典型是 TCC 拒了对 Desktop/Documents/Downloads
            // 的访问。这不是照片图库的权限问题，提示语不能混淆两者。
            return .unreadable
        }
    }

    /// 筛出可显示的图片、按文件名排序、截断到上限。纯函数，是单测的主入口。
    static func selectImages(from urls: [URL], limit: Int = maxFiles) -> [AlbumItemRef] {
        let sorted = urls
            .filter { isImageFile($0) }
            // `localizedStandardCompare` = Finder 的排序口径（"2" 排在 "10" 前）。
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        return sorted.prefix(max(limit, 0)).map {
            AlbumItemRef.localFile(path: $0.path, title: $0.lastPathComponent)
        }
    }

    /// 按扩展名判定是否为图片。
    ///
    /// 不看文件内容是有意的取舍：判错的少数边缘情况（没有扩展名的图片、伪造了
    /// 图片扩展名的文件）会落到"解码失败"的负缓存上，代价只是一个降级态；
    /// 换来的是大目录里不产生任何逐文件 syscall。
    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

// MARK: - 本地单张来源

/// 单张来源是否还在原位。
enum AlbumSingleSourceState: Equatable, Sendable {
    case ready
    case missing
}

enum AlbumFileProbe {
    nonisolated static func state(ofFileAt path: String) -> AlbumSingleSourceState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .missing : .ready
    }
}
