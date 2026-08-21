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
            case .hover: return "Hover to Expand"
            case .click: return "Click to Expand"
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

    init(defaults: UserDefaults = .standard) {
        let rawMode = defaults.string(forKey: Self.triggerModeKey) ?? ""
        triggerMode = TriggerMode(rawValue: rawMode) ?? .hover
    }
}