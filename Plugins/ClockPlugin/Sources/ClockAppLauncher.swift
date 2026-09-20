import AppKit

// MARK: - 打开时钟.app

@MainActor
enum ClockAppLauncher {
    /// 时钟.app 的 bundle id（macOS 15 起随系统提供）。
    static let bundleIdentifier = "com.apple.clock"

    /// 解析失败时的兜底路径：系统应用的标准位置。时钟.app **未注册任何
    /// URL scheme**（`CFBundleURLTypes` 不存在），写不出日历那种 `ical://`
    /// 式的深链兜底，只能退回路径直开。
    static let fallbackPath = "/System/Applications/Clock.app"

    /// 经 `NSWorkspace` 打开时钟.app。按 bundle id 解析路径而不硬编码系统位置
    /// （版本无关），解析不到再退兜底路径；两者都不成立时静默返回。
    static func open() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open(appURL)
            return
        }
        let fallback = URL(fileURLWithPath: fallbackPath)
        guard FileManager.default.fileExists(atPath: fallback.path) else { return }
        NSWorkspace.shared.open(fallback)
    }
}
