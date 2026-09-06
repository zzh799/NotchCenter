import Foundation
import NotchCenterKit

// MARK: - 宿主本地化辅助
// 资源（<lang>.lproj/Localizable.strings）在 Project.swift 里声明为宿主 target 资源，
// 由 Xcode 以本地化变体组形式嵌入 .app 的 Contents/Resources（开发态与打包态一致）。
// Bundle.module 访问器由 Tuist 在生成期合成（与 SwiftPM 同名兼容）。
//
// 语言匹配的前提：主可执行文件必须声明 CFBundleLocalizations（CFBundle 把用户偏好语言与
// 该清单求交集）。该声明由 Resources/Info.plist 提供——宿主 target 直接使用它作为
// INFOPLIST_FILE，开发态与打包态不再有清单差异。

/// 取宿主本地化字符串；键缺失时回退键名本身。
func L(_ key: String) -> String {
    L10n.string(key, bundle: .module)
}

/// 带格式化参数的宿主本地化字符串（strings 值用 printf 风格占位符 %@、%d 等）。
/// 格式化必须在调用方模块内完成：不要把 CVarArg 变参跨动态库边界转发
/// （见 Kit L10n 注释里的段错误说明）。
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key, bundle: .module), arguments: args)
}
