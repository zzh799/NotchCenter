import Foundation
import NotchCenterKit

// MARK: - 放置实例配置（每实例单独显示偏好，共识 Q5/Q10）
//
// 全局历史仍在插件级 ClipboardHistoryStore 单例；每实例差异（显示条数）走
// placementStore 经 instanceSettingsView 编辑。参考实现：SystemMonitorPlugin
// 的 InstanceConfig（逐项容错解码 + 注册表单例缓存）。

/// 单个放置实例的显示偏好。
struct ClipboardInstanceConfig: Codable, Equatable, Sendable {
    var displayCount = 50
}

@MainActor
enum ClipboardInstanceConfigLogic {
    static let storeKey = "config.display"

    static func load(from store: StateStore?) -> ClipboardInstanceConfig {
        guard let store else { return ClipboardInstanceConfig() }
        var config = store.object(ClipboardInstanceConfig.self, forKey: storeKey) ?? ClipboardInstanceConfig()
        config.displayCount = ClipboardHistoryLogic.sanitizeDisplayCount(config.displayCount)
        return config
    }

    static func save(_ config: ClipboardInstanceConfig, to store: StateStore?) {
        var next = config
        next.displayCount = ClipboardHistoryLogic.sanitizeDisplayCount(next.displayCount)
        try? store?.setObject(next, forKey: storeKey)
    }
}

@MainActor
final class ClipboardInstanceModel: ObservableObject {
    let placementID: String
    let blockID: String
    private let store: StateStore?

    @Published private(set) var config: ClipboardInstanceConfig

    init(placementID: String, blockID: String, store: StateStore?) {
        self.placementID = placementID
        self.blockID = blockID
        self.store = store
        self.config = ClipboardInstanceConfigLogic.load(from: store)
    }

    func update(_ config: ClipboardInstanceConfig) {
        let next = ClipboardInstanceConfig(
            displayCount: ClipboardHistoryLogic.sanitizeDisplayCount(config.displayCount)
        )
        self.config = next
        ClipboardInstanceConfigLogic.save(next, to: store)
    }
}

@MainActor
final class ClipboardInstanceRegistry {
    static let shared = ClipboardInstanceRegistry()

    private var models: [String: ClipboardInstanceModel] = [:]

    /// 取（或创建）某放置实例的共享模型；stateStore 为插件级共享存储，
    /// 内部派生该实例的 placementStore（多屏同实例副本观察同一对象）。
    func model(placementID: String, blockID: String, stateStore: StateStore) -> ClipboardInstanceModel {
        if let model = models[placementID] { return model }
        let model = ClipboardInstanceModel(
            placementID: placementID,
            blockID: blockID,
            store: stateStore.placementScope(placementID: placementID)
        )
        models[placementID] = model
        return model
    }

    /// 实例被移除时丢弃内存缓存（持久化文件由插件入口另行清理）。
    func discard(placementID: String) {
        models.removeValue(forKey: placementID)
    }
}
