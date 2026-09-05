import Foundation
import NotchCenterKit

// MARK: - 放置实例配置（每实例单独设置的基本能力的插件侧应用）
//
// 单指标块与 All-in-one 块各自的配置持久化在该实例的 placementStore
// （<pluginData>/placements/<placementID>/）；采样数据仍来自共享的
// SystemMonitorStore（单份采集，所有实例同源）。字段解码逐项容错：
// 旧文件缺字段、未来新增字段都不至于整体失效（缺失处回退默认值）。

/// 单指标块配置。
struct SingleBlockConfig: Codable, Equatable, Sendable {
    /// 历史窗（秒），允许档位见 `InstanceConfigLogic.allowedWindows`。
    var windowSeconds = 60
    /// 黄/红阈值覆盖；nil = 用内置默认。CPU 为 0…1 占比，磁盘/网络为字节/秒。
    var yellow: Double?
    var red: Double?
    /// 吞吐单位（磁盘/网络）。
    var rateUnit = RateUnitPreference.auto
    /// 网络排除前缀覆盖；nil = 用内置默认表。
    var networkExclusions: [String]?
}

/// All-in-one（系统总览）块配置。
struct OverviewBlockConfig: Codable, Equatable, Sendable {
    var windowSeconds = 60
    /// 参与显示的指标（隐藏项自动重排，不允许全空——更新时由 Logic 兜底）。
    var enabled: Set<MetricKind> = Set(MetricKind.allCases)
}

@MainActor
enum InstanceConfigLogic {
    /// placementStore 里的两个配置键。
    static let singleStoreKey = "config.single"
    static let overviewStoreKey = "config.overview"

    /// 历史窗允许档位（共识 Q15）。
    static let allowedWindows = [30, 60, 120, 300]

    /// 生效阈值：配置覆盖优先，且保证 yellow ≤ red（用户输反时钳制）。
    static func effectiveThresholds(kind: MetricKind, config: SingleBlockConfig) -> MetricThresholds {
        let defaults = SystemMetricsLogic.defaultThresholds(for: kind)
        let yellow = max(config.yellow ?? defaults.yellow, 0)
        let red = max(config.red ?? defaults.red, yellow)
        return MetricThresholds(yellow: yellow, red: red)
    }

    /// 生效的网络排除前缀表。
    static func effectiveNetExclusions(_ config: SingleBlockConfig) -> [String] {
        config.networkExclusions ?? SystemMetricsLogic.defaultNetExclusions
    }

    /// 历史窗合法性：不在档位内的取最近档位（持久化损坏兜底）。
    static func sanitizeWindow(_ seconds: Int) -> Int {
        allowedWindows.min(by: { abs($0 - seconds) < abs($1 - seconds) }) ?? 60
    }

    /// 设置界面文本 → 排除前缀表：逗号/空白分隔，去空项。
    static func parseExclusions(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 排除前缀表 → 设置界面文本。
    static func formatExclusions(_ list: [String]) -> String {
        list.joined(separator: ", ")
    }

    // MARK: 持久化

    static func loadSingle(from store: StateStore?) -> SingleBlockConfig {
        guard let store else { return SingleBlockConfig() }
        var config = store.object(SingleBlockConfig.self, forKey: singleStoreKey) ?? SingleBlockConfig()
        config.windowSeconds = sanitizeWindow(config.windowSeconds)
        return config
    }

    static func loadOverview(from store: StateStore?) -> OverviewBlockConfig {
        guard let store else { return OverviewBlockConfig() }
        var config = store.object(OverviewBlockConfig.self, forKey: overviewStoreKey) ?? OverviewBlockConfig()
        config.windowSeconds = sanitizeWindow(config.windowSeconds)
        if config.enabled.isEmpty { config.enabled = Set(MetricKind.allCases) }
        return config
    }

    static func saveSingle(_ config: SingleBlockConfig, to store: StateStore?) {
        try? store?.setObject(config, forKey: singleStoreKey)
    }

    static func saveOverview(_ config: OverviewBlockConfig, to store: StateStore?) {
        try? store?.setObject(config, forKey: overviewStoreKey)
    }
}

// MARK: - 实例模型与进程内注册表
//
// 同一份块视图会被宿主放进每块屏的抽屉树，设置浮窗又可能同时编辑同一
// 实例——按 placementID 缓存唯一的 ObservableObject，所有副本观察同一对象
// （OpenCodeUsageInstanceRegistry 同款约束）。

@MainActor
final class SystemMonitorInstanceModel: ObservableObject {
    let placementID: String
    let blockID: String
    private let store: StateStore?

    @Published private(set) var single: SingleBlockConfig
    @Published private(set) var overview: OverviewBlockConfig

    init(placementID: String, blockID: String, store: StateStore?) {
        self.placementID = placementID
        self.blockID = blockID
        self.store = store
        self.single = InstanceConfigLogic.loadSingle(from: store)
        self.overview = InstanceConfigLogic.loadOverview(from: store)
    }

    func update(_ config: SingleBlockConfig) {
        var next = config
        next.windowSeconds = InstanceConfigLogic.sanitizeWindow(next.windowSeconds)
        single = next
        InstanceConfigLogic.saveSingle(next, to: store)
    }

    func update(_ config: OverviewBlockConfig) {
        var next = config
        next.windowSeconds = InstanceConfigLogic.sanitizeWindow(next.windowSeconds)
        if next.enabled.isEmpty {
            next.enabled = Set(MetricKind.allCases)
        }
        overview = next
        InstanceConfigLogic.saveOverview(next, to: store)
    }
}

@MainActor
final class SystemMonitorInstanceRegistry {
    static let shared = SystemMonitorInstanceRegistry()

    private var models: [String: SystemMonitorInstanceModel] = [:]

    /// 取（或创建）某放置实例的共享模型；stateStore 为插件级共享存储，
    /// 内部派生该实例的 placementStore。
    func model(placementID: String, blockID: String, stateStore: StateStore) -> SystemMonitorInstanceModel {
        if let model = models[placementID] { return model }
        let model = SystemMonitorInstanceModel(
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
