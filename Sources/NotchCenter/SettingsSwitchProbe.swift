import Foundation

// MARK: - 设置面板切页诊断

/// 设置面板切页冻结定位：`NOTCHCENTER_SETTINGS_SWITCH_LOG=1`（仅 DEBUG 构建
/// 输出；Release 为内联空实现，调用点零开销）时输出编辑模式进出 / 内容重建 /
/// 网格指标通知等关键路径耗时（毫秒），归因「组件页 → 布局页」卡顿
/// （stopEditMode 全量块视图重建 vs 布局页首帧 vs 滑杆逐格重建）。
enum SettingsSwitchProbe {
    #if DEBUG
    static let isEnabled =
        ProcessInfo.processInfo.environment["NOTCHCENTER_SETTINGS_SWITCH_LOG"] == "1"

    /// 测量同步闭包耗时并输出；返回闭包结果。
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        NSLog("[switch] %@ = %.1fms", label, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        return result
    }

    /// 条件日志（@autoclosure：探针关闭时不构造消息）。
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[switch] %@", message())
    }
    #else
    @inline(__always)
    static func measure<T>(_ label: String, _ body: () -> T) -> T { body() }

    @inline(__always)
    static func log(_ message: @autoclosure () -> String) {}
    #endif
}
