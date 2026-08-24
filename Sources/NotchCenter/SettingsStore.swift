import Combine
import Foundation

/// 核心交互设置：触发模式（hover / click，文档 §6.1）。
/// 最大列数为布局配置，存储在 layout.json（文档 §5.4），由 LayoutEngine 管理。
@MainActor
final class SettingsStore: ObservableObject {
    enum TriggerMode: String, CaseIterable, Identifiable {
        case hover
        case click

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hover: return L("trigger.hover")
            case .click: return L("trigger.click")
            }
        }

        var systemImage: String {
            switch self {
            case .hover: return "cursorarrow.motionlines"
            case .click: return "hand.tap"
            }
        }
    }

    @Published var triggerMode: TriggerMode {
        didSet {
            UserDefaults.standard.set(triggerMode.rawValue, forKey: Self.triggerModeKey)
        }
    }

    private static let triggerModeKey = "notchCenter.triggerMode"

    // MARK: 语言覆盖（多语言方案）
    // 只写偏好，不立即生效：已加载的 bundle 在启动时完成 lproj 选择，
    // 所以切换语言后需要重启。启动入口在 main.swift 最先调 applyLanguageOverrideAtLaunch()。

    enum LanguageOverride: String, CaseIterable, Identifiable {
        case system
        case simplifiedChinese = "zh-Hans"
        case english = "en"

        var id: String { rawValue }
    }

    @Published var languageOverride: LanguageOverride {
        didSet {
            UserDefaults.standard.set(languageOverride.rawValue, forKey: Self.languageOverrideKey)
        }
    }

    /// 键名常量供 nonisolated 的启动应用逻辑读取，不能带 actor 隔离。
    nonisolated static let languageOverrideKey = "notchCenter.language"

    /// 启动时应用语言覆盖：写入 AppleLanguages 让 Bundle 的本地化查找按用户选择匹配。
    /// 选“跟随系统”时移除覆盖，恢复系统偏好顺序。
    /// nonisolated：main.swift 顶层代码（非 MainActor 隔离）在 NSApplication 初始化前同步调用，
    /// 且只操作 UserDefaults，无共享可变状态。
    nonisolated static func applyLanguageOverrideAtLaunch(defaults: UserDefaults = .standard) {
        let choice = defaults.string(forKey: languageOverrideKey).flatMap(LanguageOverride.init(rawValue:))
        switch choice {
        case .system, nil:
            defaults.removeObject(forKey: "AppleLanguages")
        case .simplifiedChinese?, .english?:
            defaults.set([choice!.rawValue], forKey: "AppleLanguages")
        }
    }

    init(defaults: UserDefaults = .standard) {
        let rawMode = defaults.string(forKey: Self.triggerModeKey) ?? ""
        triggerMode = TriggerMode(rawValue: rawMode) ?? .hover
        let rawLanguage = defaults.string(forKey: Self.languageOverrideKey) ?? ""
        languageOverride = LanguageOverride(rawValue: rawLanguage) ?? .system
    }
}