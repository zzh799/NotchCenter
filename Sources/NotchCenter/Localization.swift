import Foundation
import NotchCenterKit

// MARK: - 宿主本地化辅助
// 资源（<lang>.lproj/Localizable.strings）经 SPM 打进 NotchCenter_NotchCenter.bundle，
// Bundle.module 在开发态定位二进制旁的该 bundle，打包态由 build.sh 复制进 Contents/Resources。
//
// 语言匹配的前提：主可执行文件必须声明 CFBundleLocalizations（CFBundle 把用户偏好语言与
// 该清单求交集）。打包态由 Resources/Info.plist 提供；开发态靠链接进二进制的
// Resources/Info.dev.plist（见 Package.swift linkerSettings），缺了它永远回退英文、
// 设置面板切语言无效。

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
