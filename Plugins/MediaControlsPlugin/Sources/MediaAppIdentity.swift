import AppKit
import Foundation

// MARK: - Now Playing 应用的可视身份

/// 当前播放应用在块里要显示的东西：本地化名字 + 应用图标。
struct MediaAppIdentity {
    let bundleIdentifier: String?
    let displayName: String
    let icon: NSImage?
}

extension MediaAppIdentity: Equatable {
    /// 只比身份与名字，图标不参与：`NSImage` 没有值语义，同一张图每轮重新取出来
    /// 也是不同实例，把它算进等值判断会让"没换应用"被误判成变化、反复触发发布。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier && lhs.displayName == rhs.displayName
    }
}

/// 应用身份解析（可注入，测试用假实现，不碰真实 `NSWorkspace`）。
@MainActor
protocol MediaAppIdentityResolving: AnyObject {
    func identity(forBundleIdentifier: String?, processIdentifier: pid_t?) -> MediaAppIdentity?
}

/// 真实实现：优先按 bundle id 找应用本体，取不到再按进程号反查运行中的应用。
///
/// 名字走 `FileManager.displayName`，得到「音乐.app」「Google Chrome.app」这类形态，
/// 与参考图一致；图标走 `NSWorkspace.icon(forFile:)`，是应用自己的图标而非通用占位图。
@MainActor
final class WorkspaceAppIdentityResolver: MediaAppIdentityResolving {
    private var cache: [String: MediaAppIdentity] = [:]

    func identity(forBundleIdentifier rawIdentifier: String?, processIdentifier: pid_t?) -> MediaAppIdentity? {
        let identifier = rawIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identifier, !identifier.isEmpty {
            if let cached = cache[identifier] { return cached }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                let identity = MediaAppIdentity(
                    bundleIdentifier: identifier,
                    displayName: FileManager.default.displayName(atPath: url.path),
                    icon: NSWorkspace.shared.icon(forFile: url.path)
                )
                // 命中才写缓存；未命中的不缓存（应用可能稍后才安装/才注册）。
                cache[identifier] = identity
                return identity
            }
        }
        // 退化路径：播放器没向系统注册 bundle id 时（桥也不给 bundleIdentifier 字段），
        // 按进程号反查。名字没有「.app」后缀，但总比退回「正在播放」有信息量。
        guard let processIdentifier, processIdentifier > 0,
              let running = NSRunningApplication(processIdentifier: processIdentifier)
        else { return nil }
        guard let name = running.localizedName, !name.isEmpty else { return nil }
        return MediaAppIdentity(
            bundleIdentifier: running.bundleIdentifier,
            displayName: name,
            icon: running.icon
        )
    }
}
