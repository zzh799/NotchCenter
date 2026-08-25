import Foundation
import NotchCenterKit

// MARK: - 放置实例外观（每块单独设置的基本能力的插件侧应用）
//
// 同一块类型可以在抽屉里放多个实例，每个实例经 Kit 的 placementStore
// （<pluginData>/placements/<placementID>/）持有互不干扰的外观配置；
// 用量数据仍来自共享的 OpenCodeUsageStore（单份抓取，所有实例同源）。

/// 组件显示样式。
enum OpenCodeUsageDisplayStyle: String, Codable, Sendable, CaseIterable {
    /// 余量环：外/中/内三环同心用量图。
    case rings
    /// 余量表：三个用量窗口的横向条形量表（标签 + 进度条 + 百分比）。
    case meters
    /// 峰谷时钟：24 小时表盘 + 阶段信息。
    case peakClock

    var localizationKey: String {
        switch self {
        case .rings: return "style.rings"
        case .meters: return "style.meters"
        case .peakClock: return "style.clock"
        }
    }
}

/// 单个放置实例的持久化外观配置。解码逐字段容错：旧文件缺字段、未来
/// 新增字段都不至于整体失效（缺失处回退默认值）。
struct OpenCodeUsageAppearance: Codable, Equatable, Sendable {
    var style: OpenCodeUsageDisplayStyle = .rings
    /// 是否显示峰/谷阶段剩余倒计时。
    var showsPhaseCountdown: Bool = true

    static let `default` = OpenCodeUsageAppearance()

    enum CodingKeys: String, CodingKey {
        case style
        case showsPhaseCountdown
    }

    init(style: OpenCodeUsageDisplayStyle = .rings, showsPhaseCountdown: Bool = true) {
        self.style = style
        self.showsPhaseCountdown = showsPhaseCountdown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(OpenCodeUsageDisplayStyle.self, forKey: .style) ?? .rings
        showsPhaseCountdown = try container.decodeIfPresent(Bool.self, forKey: .showsPhaseCountdown) ?? true
    }
}

@MainActor
enum OpenCodeUsageAppearanceLogic {
    /// placementStore 里外观对象的键。
    static let storeKey = "appearance"

    /// 从实例存储读取；无记录 / 存储不可用 / 解码失败一律回退默认值。
    static func load(from store: StateStore?) -> OpenCodeUsageAppearance {
        guard let store else { return .default }
        return store.object(OpenCodeUsageAppearance.self, forKey: storeKey) ?? .default
    }

    /// 持久化到实例存储；store 不可用时静默放弃（仅影响持久化，不影响本次会话）。
    static func save(_ appearance: OpenCodeUsageAppearance, to store: StateStore?) {
        try? store?.setObject(appearance, forKey: storeKey)
    }
}

// MARK: - 实例外观模型与进程内注册表
//
// 宿主把同一份块视图放进每块屏的抽屉树（多屏多份），设置浮窗又可能同时
// 编辑同一实例——按 placementID 缓存唯一的 ObservableObject，让所有副本
// 观察同一对象：改一处全体同步（沿用插件内共享状态 × 每屏一份视图树的约束）。

@MainActor
final class OpenCodeUsageInstanceModel: ObservableObject {
    let placementID: String
    private let store: StateStore?

    @Published private(set) var appearance: OpenCodeUsageAppearance

    init(placementID: String, store: StateStore?) {
        self.placementID = placementID
        self.store = store
        self.appearance = OpenCodeUsageAppearanceLogic.load(from: store)
    }

    func update(_ appearance: OpenCodeUsageAppearance) {
        self.appearance = appearance
        OpenCodeUsageAppearanceLogic.save(appearance, to: store)
    }
}

@MainActor
final class OpenCodeUsageInstanceRegistry {
    static let shared = OpenCodeUsageInstanceRegistry()

    private var models: [String: OpenCodeUsageInstanceModel] = [:]

    /// 取（或创建）某放置实例的共享模型。stateStore 是插件级共享存储，
    /// 内部派生出该实例的 placementStore。
    func model(placementID: String, stateStore: StateStore) -> OpenCodeUsageInstanceModel {
        if let model = models[placementID] { return model }
        let model = OpenCodeUsageInstanceModel(
            placementID: placementID,
            store: stateStore.placementScope(placementID: placementID)
        )
        models[placementID] = model
        return model
    }

    /// 实例被移除时丢弃内存缓存（持久化文件由调用方另行删除）。
    func discard(placementID: String) {
        models.removeValue(forKey: placementID)
    }
}
