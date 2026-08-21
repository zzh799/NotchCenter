import Foundation

// MARK: - 插件隔离状态存储（文档 §4.6）

/// 核心为每个插件维护的隔离键值存储，文件位于
/// `~/Library/Application Support/NotchCenter/PluginData/<pluginID>/`。
///
/// - 每个键独立持久化为单独文件（避免单文件过大），原子写入。
/// - 键名仅允许 `A-Z a-z 0-9 . _ -`，不允许以 `.` 开头，防止路径逃逸。
/// - 插件实例的状态读写全部通过此 API，不直接落盘；核心不向插件暴露底层文件路径。
/// - 所有方法均在主线程调用（`@MainActor`），插件内部后台任务更新状态时必须回到主线程
///   （文档 §4.9）。
@MainActor
public final class StateStore {
    /// 键非法（含路径分隔符等）时抛出。
    public enum StateStoreError: Error, LocalizedError {
        case invalidKey(String)

        public var errorDescription: String? {
            switch self {
            case let .invalidKey(key):
                return "Invalid StateStore key: \(key)"
            }
        }
    }

    private let rootDirectory: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - rootDirectory: 该插件的独立持久化根目录。由核心创建并持有，
    ///     插件只获得已注入实例、不感知目录位置。
    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    // MARK: Data 键值

    /// 读取键对应的原始数据；无记录时返回 nil。
    public func data(forKey key: String) -> Data? {
        guard let url = try? fileURL(forKey: key), fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// 写入键对应的原始数据；传 nil 等效于删除。
    public func setData(_ data: Data?, forKey key: String) throws {
        let url = try fileURL(forKey: key)
        guard let data else {
            try? fileManager.removeItem(at: url)
            return
        }
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: Codable 键值

    /// 读取并解码 Codable 值；无记录或解码失败返回 nil。
    public func object<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// 编码并写入 Codable 值（JSON，原子写）。
    public func setObject<T: Codable>(_ object: T, forKey key: String) throws {
        try setData(try JSONEncoder().encode(object), forKey: key)
    }

    /// 删除键。
    public func removeValue(forKey key: String) {
        guard let url = try? fileURL(forKey: key) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// 大体积二进制资源（如笔记中的图片）的命名子目录，位于该插件的数据根目录下。
    /// 仅当键值模型不适合（媒体文件）时使用；普通状态一律走键值 API。
    public func resourceDirectory(named name: String) throws -> URL {
        guard Self.isValidKey(name) else {
            throw StateStoreError.invalidKey(name)
        }
        let url = rootDirectory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 键是否合法（文档约定：不含路径分隔符等特殊字符）。
    public static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, !key.hasPrefix("."), !key.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return key.rangeOfCharacter(from: allowed.inverted) == nil
    }

    private func fileURL(forKey key: String) throws -> URL {
        guard Self.isValidKey(key) else {
            throw StateStoreError.invalidKey(key)
        }
        return rootDirectory.appendingPathComponent(key)
    }
}