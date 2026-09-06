// swift-tools-version: 6.0
// NotchCenter — 刘海交互插件宿主（由 NotchNotes 重构而来，见 docs/NotchCenter 架构设计文档.md）

import Foundation
import PackageDescription

// MARK: - 插件自动发现
//
// 插件的唯一登记处是各插件目录里的 Plugins/<Name>/Plugin.plist：
//   必填：PluginID / Version / DisplayName / Description
//   可选：Dependencies（额外本地产品名数组，如 "LaunchdControlKit"；NotchCenterKit 对所有插件隐式注入）、
//         NSPrincipalClass（缺省等于文件夹名，依赖 @objc(ClassName) 与类名一致的约定）、
//         APIVersionRange（缺省 1.0..<2.0）
// 本清单在求值阶段扫描同一目录并动态生成产品与 target，新增插件只需建目录 + 写 Plugin.plist。
//
// 注意两点：
// - 清单沙箱只允许读取包目录内的文件，因此用 #filePath 定位包根，不依赖清单执行时的 CWD。
// - 清单阶段报错只能用 fatalError（SPM 会原样打印消息），所以这里给出尽量可操作的错误文案。
// - 新增插件目录后若 SPM 未重新扫描（清单按内容哈希缓存），改动本文件任意一行即可触发重新求值
//   （新增插件目录形如 Plugins/MediaControlsPlugin/，含 Plugin.plist 与 Sources/、Resources/）。
//   2026-09-05 新增 ClipboardHistoryPlugin，触发一次重扫。

func manifestFatal(_ message: String) -> Never {
    fatalError("Package.swift 插件发现失败：\(message)")
}

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pluginsRoot = packageRoot.appendingPathComponent("Plugins", isDirectory: true)

let pluginDirs: [URL] = {
    do {
        return try FileManager.default
            .contentsOfDirectory(at: pluginsRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        manifestFatal("无法读取 Plugins/ 目录：\(error.localizedDescription)")
    }
}()

if pluginDirs.isEmpty {
    manifestFatal("\(pluginsRoot.path) 下没有发现任何插件目录")
}

struct PluginMetadata {
    let name: String          // 文件夹名，也是 SPM 产品 / target 名与 CFBundleExecutable
    let dependencies: [String] // 额外本地产品依赖（NotchCenterKit 之外的部分）
}

var plugins: [PluginMetadata] = []
var seenPluginIDs = Set<String>()

for dir in pluginDirs {
    let name = dir.lastPathComponent
    let plistURL = dir.appendingPathComponent("Plugin.plist")

    // 缺元数据直接报错而非跳过：新建插件忘了写 Plugin.plist 时必须炸出来，不能静默漏打包。
    guard FileManager.default.fileExists(atPath: plistURL.path) else {
        manifestFatal("插件目录缺少 Plugin.plist：\(dir.path)")
    }

    let data: Data
    do {
        data = try Data(contentsOf: plistURL)
    } catch {
        manifestFatal("无法读取 \(plistURL.path)：\(error.localizedDescription)")
    }

    let dict: [String: Any]
    do {
        guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        dict = parsed
    } catch {
        manifestFatal("\(plistURL.path) 不是合法的 plist：\(error.localizedDescription)")
    }

    func requiredString(_ key: String) -> String {
        guard let value = dict[key] as? String, !value.isEmpty else {
            manifestFatal("\(plistURL.path) 缺少必填字段 \(key)")
        }
        return value
    }

    // 插件身份（PluginID）必须全局唯一，重复会让宿主把两个插件当成同一个。
    let pluginID = requiredString("PluginID")
    if !seenPluginIDs.insert(pluginID).inserted {
        manifestFatal("PluginID 重复：\(pluginID)（\(name) 与已发现插件冲突）")
    }
    _ = requiredString("Version")
    _ = requiredString("DisplayName")
    _ = requiredString("Description")

    // 额外依赖必须是本包声明的本地包产品；写错名字时在这里给出明确提示，
    // 而不是让 SPM 在后续解析阶段抛出难以定位的错误。NotchCenterKit 是隐式依赖，不用列。
    let knownExtraProducts: Set<String> = ["MarkdownEngine", "LaunchdControlKit"]
    let dependencies = (dict["Dependencies"] as? [String]) ?? []
    for dependency in dependencies where !knownExtraProducts.contains(dependency) {
        manifestFatal(
            "\(name) 的 Dependencies 含未知产品 \"\(dependency)\"；"
                + "可选值：\(knownExtraProducts.sorted().joined(separator: ", "))。"
                + "若确需新依赖，请先在下方 dependencies 声明对应 .package(path:) 并更新此白名单"
        )
    }

    plugins.append(PluginMetadata(name: name, dependencies: dependencies))
}

let pluginNames = plugins.map(\.name)
let dependenciesByName = Dictionary(uniqueKeysWithValues: plugins.map { ($0.name, $0.dependencies) })

// 额外依赖产品名 -> 声明在上方 dependencies 里的包引用名。
// 目前仅 vendored 的 swift-markdown-engine 目录名与产品名不一致，其余同名；
// 新增本地依赖且名字不一致时在这里补一行。
let extraPackageNameByProduct = [
    "MarkdownEngine": "swift-markdown-engine",
    "LaunchdControlKit": "LaunchdControlKit"
]

// MARK: - 包定义
// 拆成多个小表达式：整包字面量太大时编译器类型检查会超时。

var products: [Product] = [
    .executable(name: "NotchCenter", targets: ["NotchCenter"])
]
// 官方插件动态库产品，由上方 Plugin.plist 扫描生成；
// 构建后由 scripts/build.sh 组装为独立 .bundle（内置路径 Contents/PlugIns）。
for name in pluginNames {
    products.append(.library(name: name, type: .dynamic, targets: [name]))
}

let packageDependencies: [Package.Dependency] = [
    // 共享 API 动态库：宿主与插件以「产品」方式链接同一份 Kit 代码（架构文档 §2.2 / §15）。
    .package(path: "Sources/NotchCenterKit"),
    // 仅 NotesPlugin 使用（Markdown 编辑器）。核心不再依赖任何业务组件。
    .package(path: "Vendor/swift-markdown-engine"),
    // launchd 服务管理基础库：仅 DshPlugin / CalibrePlugin 使用（纯 shell 封装，不依赖 Kit）。
    .package(path: "Sources/LaunchdControlKit")
]

// 宿主主 App：刘海交互、窗口管理、插件生命周期、布局引擎、插件管理窗口
let hostTarget = Target.executableTarget(
    name: "NotchCenter",
    dependencies: [
        .product(name: "NotchCenterKit", package: "NotchCenterKit")
    ],
    path: "Sources/NotchCenter",
    // 本地化资源：en / zh-Hans 的 Localizable.strings（Bundle.module 在运行时定位）。
    resources: [
        .copy("Resources/en.lproj"),
        .copy("Resources/zh-Hans.lproj")
    ],
    linkerSettings: [
        // 打包后宿主位于 NotchCenter.app/Contents/MacOS，通过 @rpath 找到 Frameworks/NotchCenterKit.dylib
        .unsafeFlags([
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
        ]),
        // 开发态裸可执行文件没有 Info.plist，嵌入最小声明（见 Resources/Info.dev.plist 头部注释）。
        // CFBundle 的语言匹配用主可执行文件的 CFBundleLocalizations 圈定可选语言，
        // 缺了它本地化永远回退 en，设置面板切换语言在 swift run 下完全失效。
        // 用 #filePath 推导绝对路径，不依赖 swift build 的调用目录。
        .unsafeFlags([
            "-Xlinker", "-sectcreate",
            "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
            "-Xlinker", packageRoot.appendingPathComponent("Resources/Info.dev.plist").path,
        ])
    ]
)

// 官方插件 bundle 目标（动态库），由上方 Plugin.plist 扫描生成，统一 rpath linkerSettings。
// 打包后位于 Contents/PlugIns/<Name>.bundle/Contents/MacOS，
// 相对宿主 Frameworks 目录需要上溯 4 级。
let pluginTargets: [Target] = pluginNames.map { name in
    var deps: [Target.Dependency] = [.product(name: "NotchCenterKit", package: "NotchCenterKit")]
    for dependency in dependenciesByName[name]! {
        guard let pkg = extraPackageNameByProduct[dependency] else {
            manifestFatal("未知额外依赖产品 \'\(dependency)\'")
        }
        deps.append(.product(name: dependency, package: pkg))
    }
    return Target.target(
        name: name,
        dependencies: deps,
        path: "Plugins/\(name)",
        // Plugin.plist 是构建脚本消费的元数据，不是源码或资源，显式排除免得 SPM 告警。
        exclude: ["Plugin.plist"],
        // 本地化 UI 文案：每个插件自带 en / zh-Hans 的 Localizable.strings（build.sh 组装时平铺进 bundle）。
        resources: [
            .copy("Resources/en.lproj"),
            .copy("Resources/zh-Hans.lproj")
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"
            ])
        ]
    )
}

// 测试 target 依赖全部插件模块（按 target 名解析），列表随 Plugins/ 目录自动伸缩。
var testDeps: [Target.Dependency] = [
    .product(name: "NotchCenterKit", package: "NotchCenterKit"),
    "NotchCenter",
    .product(name: "LaunchdControlKit", package: "LaunchdControlKit")
]
testDeps += pluginNames.map { Target.Dependency(stringLiteral: $0) }

let testTarget = Target.testTarget(
    name: "NotchCenterTests",
    dependencies: testDeps,
    path: "Tests/NotchCenterTests"
)

let package = Package(
    name: "NotchCenter",
    // 本地化资源的基准开发语言（en）：声明了 .lproj 资源后 SPM 强制要求。
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: products,
    dependencies: packageDependencies,
    targets: [hostTarget] + pluginTargets + [testTarget]
)
