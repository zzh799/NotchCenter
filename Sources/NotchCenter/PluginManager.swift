import Combine
import Foundation
import NotchCenterKit

/// 单个已发现插件的状态条目（元数据 + 启用/加载状态）。
@MainActor
final class PluginEntry: ObservableObject, Identifiable {
    let metadata: PluginMetadata

    @Published private(set) var isEnabled: Bool
    @Published private(set) var instance: (any NotchCenterPlugin)?
    @Published private(set) var stateStore: StateStore?
    @Published private(set) var loadError: String?

    nonisolated var id: String { metadata.pluginID }

    init(metadata: PluginMetadata, isEnabled: Bool) {
        self.metadata = metadata
        self.isEnabled = isEnabled
    }

    /// 已加载插件的块清单（需要先启用并加载，文档 §3.3 第 4 步）。
    var blocks: [NotchBlock] {
        guard let instance else { return [] }
        return type(of: instance).blocks
    }

    /// 当前加载的插件主类。
    var pluginClass: NotchCenterPlugin.Type? {
        instance.map { type(of: $0) }
    }

    func markEnabled(_ enabled: Bool, error: String? = nil) {
        isEnabled = enabled
        loadError = error
        if !enabled {
            instance = nil
            stateStore = nil
        }
    }

    func markLoaded(instance: any NotchCenterPlugin, stateStore: StateStore) {
        self.instance = instance
        self.stateStore = stateStore
        loadError = nil
        isEnabled = true
    }
}

/// 插件发现、加载与生命周期管理（文档 §3）。
///
/// - 双目录扫描：内置 `Contents/PlugIns` + 用户 `~/Library/Application Support/NotchCenter/PlugIns`
/// - 未启用插件不加载代码，仅读取元数据（文档 §3.3 / §3.4）
/// - 禁用时释放插件实例但保持 bundle 加载（不卸载）
@MainActor
final class PluginManager: ObservableObject {
    enum PluginManagerError: Error, LocalizedError {
        case notFound(pluginID: String)
        case apiIncompatible(pluginID: String, declared: String, current: String)
        case failedToLoad(pluginID: String, reason: String)
        case invalidPrincipalClass(pluginID: String)
        case notUserPlugin(pluginID: String)
        case installFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case let .notFound(pluginID):
                return LF("pluginManager.error.notFound", pluginID)
            case let .apiIncompatible(pluginID, declared, current):
                return LF("pluginManager.error.apiIncompatible", pluginID, declared, current)
            case let .failedToLoad(pluginID, reason):
                return LF("pluginManager.error.failedToLoad", pluginID, reason)
            case let .invalidPrincipalClass(pluginID):
                return LF("pluginManager.error.invalidPrincipalClass", pluginID)
            case let .notUserPlugin(pluginID):
                return LF("pluginManager.error.notUserPlugin", pluginID)
            case let .installFailed(reason):
                return LF("pluginManager.error.installFailed", reason)
            }
        }
    }

    @Published private(set) var entries: [PluginEntry] = []
    @Published private(set) var invalidBundles: [URL] = []

    /// 启用状态变化回调（核心用于同步 layout.json 的 enabledPluginIDs）。
    var onEnabledPluginIDsChanged: ((Set<String>, Set<String>) -> Void)?

    private let hostController: any HostController
    private let fileManager: FileManager
    private let builtInDirectoryOverride: URL?
    private let userDirectoryOverride: URL?

    /// 快捷动作注册表（文档 §4.11）：启用即入册、禁用即注销。宿主控制器与
    /// 编辑目录经它取动作；初始化注入以便宿主与测试共享同一实例。
    let quickActionStore: QuickActionStore

    init(
        hostController: any HostController,
        fileManager: FileManager = .default,
        builtInDirectory: URL? = nil,
        userDirectory: URL? = nil,
        quickActionStore: QuickActionStore = QuickActionStore()
    ) {
        self.hostController = hostController
        self.fileManager = fileManager
        self.builtInDirectoryOverride = builtInDirectory
        self.userDirectoryOverride = userDirectory
        self.quickActionStore = quickActionStore
        rescan()
    }

    private var builtInDirectory: URL {
        builtInDirectoryOverride ?? CorePaths.builtInPlugInsDirectory
    }

    private var userDirectory: URL {
        userDirectoryOverride ?? CorePaths.userPlugInsDirectory
    }

    // MARK: - 查询

    func entry(for pluginID: String) -> PluginEntry? {
        entries.first { $0.id == pluginID }
    }

    func block(pluginID: String, blockID: String) -> NotchBlock? {
        entry(for: pluginID)?.blocks.first { $0.id == blockID }
    }

    var builtInPluginIDs: Set<String> {
        Set(entries.filter { $0.metadata.isBuiltIn }.map(\.id))
    }

    /// 状态栏菜单贡献（按插件分组，文档 §4.8）。
    func menuContributions() -> [(pluginID: String, displayName: String, items: [PluginMenuItem])] {
        entries
            .filter { $0.isEnabled && $0.instance != nil }
            .compactMap { entry in
                let items = entry.instance?.menuItems ?? []
                guard !items.isEmpty else { return nil }
                return (entry.id, entry.metadata.displayName, items)
            }
            .sorted { $0.displayName < $1.displayName }
    }

    // MARK: - 扫描（文档 §3.3 第 1–3 步）

    func rescan() {
        let builtInURLs = bundleURLs(in: builtInDirectory)
        let userURLs = bundleURLs(in: userDirectory)

        var entriesByID: [String: PluginEntry] = [:]
        var invalid: [URL] = []

        for url in builtInURLs {
            if let metadata = parseMetadata(from: url, isBuiltIn: true) {
                entriesByID[metadata.pluginID] = PluginEntry(metadata: metadata, isEnabled: false)
            } else {
                invalid.append(url)
            }
        }
        // 用户目录后扫：相同 pluginID 时用户版本覆盖内置版本。
        for url in userURLs {
            if let metadata = parseMetadata(from: url, isBuiltIn: false) {
                entriesByID[metadata.pluginID] = PluginEntry(metadata: metadata, isEnabled: false)
            } else {
                invalid.append(url)
            }
        }

        entries = entriesByID.values.sorted { $0.metadata.displayName < $1.metadata.displayName }
        invalidBundles = invalid
    }

    private func bundleURLs(in directory: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "bundle" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func parseMetadata(from bundleURL: URL, isBuiltIn: Bool) -> PluginMetadata? {
        let bundle = Bundle(url: bundleURL)
        guard let info = bundle?.infoDictionary else { return nil }
        return try? PluginMetadata(bundleURL: bundleURL, infoDictionary: info, isBuiltIn: isBuiltIn)
    }

    // MARK: - 启用 / 禁用（文档 §3.4）

    /// 启用/禁用插件，即时生效。启用失败（API 不兼容、加载失败等）时抛出并保持禁用。
    func setEnabled(_ enabled: Bool, pluginID: String) throws {
        guard let entry = entry(for: pluginID) else {
            throw PluginManagerError.notFound(pluginID: pluginID)
        }
        guard entry.isEnabled != enabled else { return }

        if enabled {
            try load(entry)
        } else {
            (entry.instance as? any NotchCenterPluginServices)?.pluginWasDisabled()
            quickActionStore.unregister(pluginID: pluginID)
            entry.markEnabled(false)
        }

        let newSet = Set(entries.filter(\.isEnabled).map(\.id))
        onEnabledPluginIDsChanged?([pluginID], newSet)
    }

    /// 恢复布局中记录（layout.json enabledPluginIDs）的启用状态：仅加载已启用插件（文档 §3.3 第 4 步）。
    /// 加载失败的条目保持禁用并记录错误。
    ///
    /// 内置插件默认启用（决策：官方插件随 app 分发，应开箱即用）：不在
    /// enabledPluginIDs 里的内置插件自动加载并追加到持久化集合；第三方
    /// 插件仍需用户在管理窗口手动启用。
    func restoreEnabledState(from enabledIDs: Set<String>) {
        var effectiveIDs = enabledIDs
        for entry in entries where entry.metadata.isBuiltIn && !enabledIDs.contains(entry.id) {
            do {
                try load(entry)
                effectiveIDs.insert(entry.id)
            } catch {
                // 加载失败保持禁用，不写入持久化集合（下次启动重试）。
            }
        }
        for entry in entries where enabledIDs.contains(entry.id) {
            guard !entry.isEnabled else { continue }
            do {
                try load(entry)
            } catch {
                entry.markEnabled(false, error: error.localizedDescription)
            }
        }
        if effectiveIDs != enabledIDs {
            onEnabledPluginIDsChanged?([], effectiveIDs)
        }
    }

    private func load(_ entry: PluginEntry) throws {
        let bundleURL = entry.metadata.bundleURL

        guard entry.metadata.isAPICompatible else {
            let declared = entry.metadata.apiVersion
            let current = NotchCenterKitAPI.currentVersion.description
            entry.markEnabled(false, error: PluginManagerError.apiIncompatible(
                pluginID: entry.id,
                declared: declared,
                current: current
            ).localizedDescription)
            throw PluginManagerError.apiIncompatible(pluginID: entry.id, declared: declared, current: current)
        }

        guard let bundle = Bundle(url: bundleURL) else {
            entry.markEnabled(false, error: PluginManagerError.failedToLoad(
                pluginID: entry.id,
                reason: "bundled bundle not found"
            ).localizedDescription)
            throw PluginManagerError.failedToLoad(pluginID: entry.id, reason: "bundle not found")
        }

        guard bundle.load() else {
            let reason = bundle.principalClass == nil
                ? "Bundle.load() failed"
                : "Bundle.load() returned false"
            entry.markEnabled(false, error: PluginManagerError.failedToLoad(
                pluginID: entry.id,
                reason: reason
            ).localizedDescription)
            throw PluginManagerError.failedToLoad(pluginID: entry.id, reason: reason)
        }

        guard let pluginClass = bundle.principalClass as? NotchCenterPlugin.Type else {
            entry.markEnabled(false, error: PluginManagerError.invalidPrincipalClass(
                pluginID: entry.id
            ).localizedDescription)
            throw PluginManagerError.invalidPrincipalClass(pluginID: entry.id)
        }

        let instance = pluginClass.init()
        let stateStore = StateStore(
            rootDirectory: CorePaths.pluginDataDirectory(for: entry.id)
        )
        if let services = instance as? any NotchCenterPluginServices {
            services.attachServices(stateStore: stateStore, hostController: hostController)
        }
        entry.markLoaded(instance: instance, stateStore: stateStore)
        // 启用即入册：动作实例缓存于插件实例上，宿主只存引用（文档 §4.11）。
        quickActionStore.register(pluginID: entry.id, actions: instance.quickActions)
    }

    // MARK: - 安装 / 卸载（文档 §8.2）

    /// 安装用户插件 bundle：先校验元数据与 API 兼容性，通过后复制到用户插件目录并启用。
    func installBundle(from selectedURL: URL) throws -> PluginEntry {
        let sourceIsBundle = selectedURL.pathExtension == "bundle"
        let sourceURL = sourceIsBundle ? selectedURL : selectedURL.appendingPathExtension("bundle")
        let sourceBundle = Bundle(url: sourceURL)
        guard let info = sourceBundle?.infoDictionary else {
            throw PluginManagerError.installFailed(reason: "not a loadable bundle")
        }

        let metadata: PluginMetadata
        do {
            metadata = try PluginMetadata(
                bundleURL: sourceURL,
                infoDictionary: info,
                isBuiltIn: false
            )
        } catch {
            throw PluginManagerError.installFailed(reason: error.localizedDescription)
        }

        guard metadata.isAPICompatible else {
            throw PluginManagerError.apiIncompatible(
                pluginID: metadata.pluginID,
                declared: metadata.apiVersion,
                current: NotchCenterKitAPI.currentVersion.description
            )
        }

        let destination = userDirectory
            .appendingPathComponent(metadata.pluginID + ".bundle", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw PluginManagerError.installFailed(reason: error.localizedDescription)
        }

        rescan()
        guard let entry = entry(for: metadata.pluginID) else {
            throw PluginManagerError.installFailed(reason: "installed bundle could not be discovered")
        }

        do {
            try setEnabled(true, pluginID: entry.id)
        } catch {
            // 启用失败时回滚安装，避免留下已知不可用的插件。
            try? fileManager.removeItem(at: destination)
            rescan()
            throw error
        }
        return entry
    }

    /// 卸载用户插件（内置插件不可卸载）。
    func uninstall(pluginID: String) throws {
        guard let entry = entry(for: pluginID) else {
            throw PluginManagerError.notFound(pluginID: pluginID)
        }
        guard !entry.metadata.isBuiltIn else {
            throw PluginManagerError.notUserPlugin(pluginID: pluginID)
        }

        if entry.isEnabled {
            (entry.instance as? any NotchCenterPluginServices)?.pluginWasDisabled()
            quickActionStore.unregister(pluginID: pluginID)
        }
        let bundleURL = entry.metadata.bundleURL
        try? fileManager.removeItem(at: bundleURL)
        rescan()
        onEnabledPluginIDsChanged?([], Set(entries.filter(\.isEnabled).map(\.id)))
    }
}