import Foundation
import NotchCenterKit

// 本插件本地化辅助：运行时 bundle 即组装后的 .bundle（scripts/build.sh 已把 SPM 资源包里的 lproj 复制进其 Contents/Resources），Bundle(for:) 直接命中。
func L(_ key: String) -> String {
    L10n.string(key, bundle: Bundle(for: ClipboardHistoryPlugin.self))
}
