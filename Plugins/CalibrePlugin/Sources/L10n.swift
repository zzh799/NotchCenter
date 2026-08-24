import Foundation
import NotchCenterKit

// 本插件本地化辅助：运行时 bundle 即组装后的 .bundle（Scripts/build.sh 已把 SPM 资源包里的 lproj 复制进其 Contents/Resources），Bundle(for:) 直接命中。
func L(_ key: String) -> String {
    L10n.string(key, bundle: Bundle(for: CalibrePlugin.self))
}

/// 带格式化参数（strings 值用 printf 风格占位符 %@、%d 等）。
func LF(_ key: String, _ args: CVarArg...) -> String {
    // 格式化在调用方模块内完成：不要把 CVarArg 变参跨动态库边界转发。
    String(format: L10n.string(key, bundle: Bundle(for: CalibrePlugin.self)), arguments: args)
}
