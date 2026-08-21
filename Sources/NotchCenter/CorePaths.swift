import Foundation

/// 核心路径约定（文档 §2.3 / §4.6 / §5.4）。
enum CorePaths {
    /// `~/Library/Application Support/NotchCenter`
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("NotchCenter", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("NotchCenter", isDirectory: true)
    }

    /// 内置插件目录：`NotchCenter.app/Contents/PlugIns`（开发期回退为可执行文件旁 `PlugIns`）。
    static var builtInPlugInsDirectory: URL {
        let bundleURL = Bundle.main.bundleURL
        let root = bundleURL.pathExtension == "app"
            ? bundleURL.appendingPathComponent("Contents", isDirectory: true)
            : (bundleURL.pathExtension.isEmpty ? bundleURL : bundleURL.deletingLastPathComponent())
        return root.appendingPathComponent("PlugIns", isDirectory: true)
    }

    /// 用户第三方插件目录：`~/Library/Application Support/NotchCenter/PlugIns`。
    static var userPlugInsDirectory: URL {
        supportDirectory.appendingPathComponent("PlugIns", isDirectory: true)
    }

    /// 插件数据目录（文档 §4.6）：`PluginData/<pluginID>`。
    static func pluginDataDirectory(for pluginID: String) -> URL {
        let safeID = pluginID.replacingOccurrences(of: "/", with: "_")
        return supportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(safeID, isDirectory: true)
    }

    /// 布局持久化文件（文档 §5.4）：`~/Library/Application Support/NotchCenter/layout.json`。
    /// 支持 `NOTCHCENTER_LAYOUT_FILE` 环境变量覆盖（开发/截图验证用）。
    static var layoutFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["NOTCHCENTER_LAYOUT_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appendingPathComponent("layout.json")
    }
}