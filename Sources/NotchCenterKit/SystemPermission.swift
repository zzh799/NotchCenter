import AppKit
import Foundation

// MARK: - 系统权限清单（决策见 Agent Note 2026-09-11-permission-management-panel）

/// NotchCenter 可能需要的**系统隐私权限**清单。每项都有一个对应的
/// 「系统设置 → 隐私与安全性」面板，因此每项都能给出确定的跳转 URL。
///
/// 清单刻意保持"少而准"：只有真有官方插件使用、且能在 TCC 里找到对应面板的
/// 权限才在册。新增一项时**必须**同时确认：TCC pane 名、`Resources/Info.plist`
/// 里的用途字符串键（无用途字符串的权限填 nil）、以及状态查询方式。
public enum SystemPermission: String, CaseIterable, Sendable, Hashable, Codable {
    /// 日历（EventKit）。用途字符串 `NSCalendarsFullAccessUsageDescription`。
    case calendar
    /// 提醒事项（EventKit）。用途字符串 `NSRemindersFullAccessUsageDescription`。
    case reminders
    /// 摄像头（AVFoundation）。用途字符串 `NSCameraUsageDescription`。
    case camera
    /// 屏幕录制（ScreenCaptureKit）。TCC **不带**用途字符串，只能跳转引导。
    case screenRecording
    /// 辅助功能（AXUIElement）。同上，TCC 不带用途字符串。
    case accessibility
    /// 定位（CoreLocation，天气用）。用途字符串 `NSLocationUsageDescription`。
    case location

    /// 「系统设置 → 隐私与安全性」面板名（`x-apple.systempreferences:` URL 的锚点）。
    public var privacyPane: String {
        switch self {
        case .calendar: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .camera: return "Privacy_Camera"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .location: return "Privacy_LocationServices"
        }
    }

    /// 用途字符串所在的 Info.plist 键；TCC 不要求用途字符串的权限返回 nil
    /// （屏幕录制 / 辅助功能），此时弹窗只做跳转引导、不展示"用途声明"。
    public var usageDescriptionKey: String? {
        switch self {
        case .calendar: return "NSCalendarsFullAccessUsageDescription"
        case .reminders: return "NSRemindersFullAccessUsageDescription"
        case .camera: return "NSCameraUsageDescription"
        case .screenRecording: return nil
        case .accessibility: return nil
        case .location: return "NSLocationUsageDescription"
        }
    }

    /// 引导图标（SF Symbol 名称）。
    public var symbolName: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .camera: return "camera"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .location: return "location"
        }
    }

    /// 授权后是否需要**重启 App** 才生效。
    ///
    /// TCC 的屏幕录制授权走独立进程（`replayd`）缓存，已运行进程拿到新授权
    /// 前必须重启；辅助功能的 AX API 同理有进程级缓存。两者都要在 UI 里明说，
    /// 否则用户会以为"授权了但没生效"。
    public var requiresRelaunch: Bool {
        switch self {
        case .screenRecording, .accessibility: return true
        case .calendar, .reminders, .camera, .location: return false
        }
    }
}

// MARK: - 权限状态

/// 一项权限的当前状态（四态，与 TCC 的实际语义对齐）。
public enum PermissionStatus: String, Sendable, Hashable, Codable {
    /// 尚未请求过（TCC 无记录）。请求会弹系统授权窗。
    case notDetermined
    /// 已授权。
    case authorized
    /// 用户明确拒绝。TCC **不会**再次弹窗，只能去系统设置手改——这正是
    /// 权限弹窗要引导的路径。
    case denied
    /// 受限：被家长控制 / MDM 策略禁止，用户自己改不了。
    case restricted

    /// 是否可直接使用对应能力。
    public var isUsable: Bool { self == .authorized }

    /// 是否还能通过"请求"弹系统窗拿到授权（`.denied`/`.restricted` 只能走系统设置）。
    public var canRequest: Bool { self == .notDetermined }
}

// MARK: - 跳转 URL（纯函数，可单测）

/// 系统设置跳转 URL 的构造。**纯函数**，不触碰 `NSWorkspace`，便于单测。
public enum SystemSettingsURL {
    /// `x-apple.systempreferences:` scheme 的 security 面板前缀。
    public static let securityPanePrefix = "x-apple.systempreferences:com.apple.preference.security"

    /// 某权限对应的「系统设置 → 隐私与安全性」深链。
    public static func url(for permission: SystemPermission) -> URL {
        // 面板名全部是 ASCII 标识符，不需要百分号编码；仍然显式构造失败兜底，
        // 避免调用点处理 Optional。
        URL(string: "\(securityPanePrefix)?\(permission.privacyPane)")
            ?? URL(string: securityPanePrefix)!
    }

    /// 深链的字符串形式（测试与日志用）。
    public static func string(for permission: SystemPermission) -> String {
        url(for: permission).absoluteString
    }
}

// MARK: - 状态查询抽象（可注入，测试用假实现）

/// 权限状态的**查询**接口。生产实现读真实 TCC 状态，测试注入假实现——
/// 单测绝不触发真实系统授权弹窗（`requestAccess` 会弹系统窗，测试里禁止调用）。
@MainActor
public protocol PermissionStatusProviding: AnyObject {
    /// 查询某项权限的当前状态（同步、无副作用、不弹任何窗）。
    func status(of permission: SystemPermission) -> PermissionStatus
}

/// 请求授权的结果。
public enum PermissionRequestOutcome: Sendable, Hashable {
    /// 已授权。
    case authorized
    /// 用户拒绝。
    case denied
    /// 受限，用户无法自行更改。
    case restricted
    /// 请求失败（框架不可用 / 出错），附原因。
    case failed(String)
}

/// 权限**请求**接口。与查询分开：请求会弹系统窗，只有用户显式点击"授权"
/// 按钮时才允许调用。
@MainActor
public protocol PermissionRequesting: AnyObject {
    /// 请求某项权限。`.denied`/`.restricted` 状态下系统不会再弹窗，
    /// 实现应直接返回对应结果（调用方据此改走"跳系统设置"引导）。
    func request(_ permission: SystemPermission) async -> PermissionRequestOutcome
}

// MARK: - 权限引导展示通道

/// 「权限管理」弹窗的对外入口。宿主提供生产实现，插件在发现权限缺失时
/// 经 `HostController.presentPermissions(_:)` 请求展示。
@MainActor
public protocol PermissionGuidePresenting: AnyObject {
    /// 弹出权限管理弹窗，逐条显示（并在需要时高亮）指定权限。
    /// - Parameter focus: 需要用户关注的权限；nil/空 = 展示完整清单。
    func presentPermissionGuide(focus: [SystemPermission])
}
