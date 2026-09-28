import AppKit
import AVFoundation
import EventKit
import Foundation
import NotchCenterKit
import Photos

// MARK: - 权限中心（宿主侧唯一权限门面）

/// 宿主对 `HostController` 权限通道的生产实现：查询真实 TCC 状态、按需发起
/// 授权请求、并把「权限管理」弹窗拉起来。
///
/// 查询与请求**刻意分开**（`PermissionStatusProviding` / `PermissionRequesting`）：
/// 查询无副作用，任何时刻、任何线程语义下都安全；请求会弹系统授权窗，只在
/// 用户显式点「授权」时调用。单测注入假实现，绝不走这里。
///
/// 决策与取舍见 Agent Note 2026-09-11-permission-management-panel。
@MainActor
final class PermissionCenter: PermissionStatusProviding, PermissionRequesting, PermissionGuidePresenting {
    static let shared = PermissionCenter()

    /// `EKEventStore` 未标 `Sendable`，但它的 `requestFullAccessTo*` 是
    /// 系统保证线程安全的异步授权调用（EventKit 内部串行化）。宿主侧只在
    /// 主执行者上创建并访问它，跨 `await` 的"发送"告警是 Swift 6 的保守判定，
    /// 这里显式豁免——不共享到其它隔离域，也不并发访问。
    nonisolated(unsafe) private let eventStore = EKEventStore()

    private init() {}

    // MARK: 状态查询

    func status(of permission: SystemPermission) -> PermissionStatus {
        switch permission {
        case .calendar:
            return Self.map(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.map(EKEventStore.authorizationStatus(for: .reminder))
        case .camera:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .screenRecording:
            // 屏幕录制没有 AVFoundation 式的授权查询 API；`CGPreflightScreenCaptureAccess`
            // 是唯一公开路径（首次调用不弹窗，只回报当前状态）。
            return CGPreflightScreenCaptureAccess() ? .authorized : .denied
        case .accessibility:
            // AXIsProcessTrusted 同样只读；注意"未授权"与"已拒绝"在 API 层面
            // 不可区分，统一报 .denied 由弹窗引导去系统设置（用户能自行判断）。
            return AXIsProcessTrusted() ? .authorized : .denied
        case .location:
            // 定位状态由 CoreLocation 的异步授权流管理，宿主未接 CoreLocation
            // 委托中心；此处按"未请求"上报（天气插件默认走手填城市，零权限）。
            return .notDetermined
        case .photos:
            // 只读图库用 `.readWrite` 档：PhotoKit 没有"纯读"授权级别，
            // 读图库就是 readWrite 档（addOnly 只够写入，读不了）。
            return Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
    }

    /// EventKit / AVFoundation 的授权状态 → Kit 的四态。
    private static func map(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// AVFoundation 的授权状态 → Kit 的四态。
    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// PhotoKit 的授权状态 → Kit 的四态。
    ///
    /// `.limited`（用户只授权了部分照片）并入 `.authorized`：Kit 的四态里没有
    /// "受限选集"这一档，而受限选集**确实可读**——判成不可用会让块错误地退回
    /// 引导态，把能用的功能锁死。用户选中的那些照片正常显示，没选中的取不到
    /// 图时由插件侧落到"取图失败"降级态（不报错、不留空洞）。
    private static func map(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .limited: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: 请求授权

    func request(_ permission: SystemPermission) async -> PermissionRequestOutcome {
        // 已拒绝/受限时系统不会再弹窗，直接回结果让调用方改走系统设置引导。
        let current = status(of: permission)
        if !current.canRequest {
            switch current {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: break
            }
        }

        switch permission {
        case .calendar:
            return await requestEvents()
        case .reminders:
            return await requestReminders()
        case .camera:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        case .screenRecording:
            // 公开 API 的"请求"就是 `CGRequestScreenCaptureAccess()`：它会弹一次
            // 系统引导，但授权本身要用户在系统设置里手动勾选 + 重启 App。
            let granted = CGRequestScreenCaptureAccess()
            return granted ? .authorized : .denied
        case .accessibility:
            // 辅助功能没有请求 API，只能把系统引导窗拉起来。
            // 选项键是 `kAXTrustedCheckOptionPrompt` 的字面量值（"AXTrustedCheckOptionPrompt"）：
            // 那个全局 var 在 Swift 6 严格并发下被判定为共享可变状态，不能直接引用。
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            return trusted ? .authorized : .denied
        case .location:
            // 宿主不持有 CoreLocation 授权流（见 status(of:) 的说明）。
            return .failed(L("permission.error.locationUnsupported"))
        case .photos:
            // 请求是 async 非抛出（SDK 的 `NS_SWIFT_ASYNC` 导入），所以没有
            // `.failed` 分支可走。结果复用 status 的四态口径——请求完仍是
            // `.notDetermined` 只可能是系统没给出结论，按"没拿到授权"处理。
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            switch Self.map(granted) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .denied
            }
        }
    }

    private func requestEvents() async -> PermissionRequestOutcome {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            return granted ? .authorized : .denied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func requestReminders() async -> PermissionRequestOutcome {
        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            return granted ? .authorized : .denied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: 弹窗引导

    func presentPermissionGuide(focus: [SystemPermission]) {
        PermissionGuidePanel.shared.present(focus: focus)
    }
}
