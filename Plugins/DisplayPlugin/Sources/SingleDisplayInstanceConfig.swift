import Foundation
import NotchCenterKit

// MARK: - 单屏条块的放置实例配置
//
// 一实例绑定一台屏：`displayID` 为 nil 表示「跟随第一台」（新块拖出来的默认态，
// 用户拍板）；存的屏消失时视图回退第一台显示、不改写存储（避免插拔时来回跳）。
// 存取模式参照 ClipboardInstanceConfig（逐项容错解码 + 注册表单例缓存）。

/// 单个放置实例绑定的显示器（nil = 跟随第一台）。
struct SingleDisplayInstanceConfig: Codable, Equatable, Sendable {
    var displayID: UInt32?
}

@MainActor
enum SingleDisplayInstanceConfigLogic {
    static let storeKey = "config.display"

    static func load(from store: StateStore?) -> SingleDisplayInstanceConfig {
        guard let store else { return SingleDisplayInstanceConfig() }
        return store.object(SingleDisplayInstanceConfig.self, forKey: storeKey)
            ?? SingleDisplayInstanceConfig()
    }

    static func save(_ config: SingleDisplayInstanceConfig, to store: StateStore?) {
        try? store?.setObject(config, forKey: storeKey)
    }
}

@MainActor
final class SingleDisplayInstanceModel: ObservableObject {
    let placementID: String
    private let store: StateStore?

    @Published private(set) var config: SingleDisplayInstanceConfig

    init(placementID: String, store: StateStore?) {
        self.placementID = placementID
        self.store = store
        self.config = SingleDisplayInstanceConfigLogic.load(from: store)
    }

    func update(_ config: SingleDisplayInstanceConfig) {
        self.config = config
        SingleDisplayInstanceConfigLogic.save(config, to: store)
    }
}

@MainActor
enum SingleDisplayInstanceRegistry {
    private static var models: [String: SingleDisplayInstanceModel] = [:]

    /// 按 placementID 取或建该实例的内存模型（存储隔离与多副本共享的成例
    /// 见 Clipboard 插件的实例注册表实现，此处只写本实例的差异：存显示器绑定）。
    static func model(placementID: String, stateStore: StateStore) -> SingleDisplayInstanceModel {
        if let model = models[placementID] { return model }
        let model = SingleDisplayInstanceModel(
            placementID: placementID,
            store: stateStore.placementScope(placementID: placementID)
        )
        models[placementID] = model
        return model
    }

    /// 已删实例的内存模型在此忘掉，磁盘侧由插件入口清理。
    static func discard(placementID: String) {
        models.removeValue(forKey: placementID)
    }
}
