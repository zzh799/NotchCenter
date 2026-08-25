import Foundation
import ServiceManagement

/// 开机自启（macOS 13+ SMAppService，文档 §6.1 设置项）。
/// 仅对打包后的 .app 有效；开发态（swift run 裸二进制）注册会抛错，由调用方展示。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 幂等设置：已处于目标状态时直接返回成功。
    static func setEnabled(_ enabled: Bool) throws {
        switch (enabled, SMAppService.mainApp.status) {
        case (true, .enabled), (false, .notRegistered):
            return
        case (true, _):
            try SMAppService.mainApp.register()
        case (false, _):
            try SMAppService.mainApp.unregister()
        }
    }

    /// 状态与用户期望不一致时（如系统设置里被手动关闭），同步回真实状态。
    static func syncStatus() -> Bool {
        // daemon / notFound 等异常态一律视为未启用。
        isEnabled
    }
}
