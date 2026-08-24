import Foundation

// MARK: - 本地化辅助（多语言方案，en / zh-Hans）

/// 各模块（宿主与插件）自带 `<lang>.lproj/Localizable.strings`，通过自身 Bundle 取串。
/// 语言选择交给系统标准机制：按 App 偏好语言匹配最合适的 .lproj（宿主设置面板的
/// 「语言」项通过 AppleLanguages 覆盖，重启后生效）。
///
/// 使用方式：
/// - 宿主：`L10n.string("key", bundle: .module)`（资源经 SPM 打进 NotchCenter_NotchCenter.bundle）
/// - 插件：`L10n.string("key", bundle: Bundle(for: Self.self))`（运行时 bundle 即组装后的 .bundle，
///   build.sh 会把 SPM 资源 bundle 里的 lproj 复制进其 Contents/Resources）
///
/// 注意：本 API 故意不提供 CVarArg 变参重载。实测在测试环境下「主可执行模块把
/// 变参整体转发进本动态库再 String(format:)」会偶发段错误（va_list 跨镜像边界的
/// 寄存器保存问题）。带参数的调用方必须在自己模块内完成格式化：
/// `String(format: L10n.string(key, bundle: b), arguments: args)`。
public enum L10n {
    /// 从 bundle 的 strings 表取本地化字符串；键缺失时返回 `fallback`。
    public static func string(
        _ key: String,
        bundle: Bundle,
        table: String = "Localizable",
        fallback: String? = nil
    ) -> String {
        // value 传 fallback（缺省 key 本身）：表缺失或键缺失时原样回退，
        // 与 NSLocalizedString 的行为一致但显式可控。
        bundle.localizedString(forKey: key, value: fallback ?? key, table: table)
    }
}
