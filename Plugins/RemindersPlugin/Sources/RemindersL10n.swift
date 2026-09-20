import Foundation
import NotchCenterKit

// MARK: - 本地化辅助（宿主与各插件同款：en 为开发基准语言，zh-Hans 在 Resources/）

func L(_ key: String) -> String {
    L10n.string(key, bundle: Bundle(for: RemindersPlugin.self))
}

/// 带参数文案。本体必须是**本模块内**的 `String(format:)`：Kit 的 `L10n.string`
/// 刻意不提供变参重载（跨镜像转发 va_list 在测试环境偶发段错误，见 `L10n.swift`）。
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key, bundle: Bundle(for: RemindersPlugin.self)), arguments: args)
}
