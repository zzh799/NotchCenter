// NotchCenter — Tuist 清单（由 Package.swift 迁移而来）
//
// 插件的唯一登记处是各插件目录里的 Plugins/<Name>/Plugin.plist：
//   必填：PluginID / Version / DisplayName / Description
//   可选：Dependencies（额外本地依赖产品名数组，如 "MarkdownEngine"；NotchCenterKit 对所有插件隐式注入）、
//         NSPrincipalClass（缺省等于文件夹名，由 build.sh 消费）、
//         APIVersionRange（缺省 1.0..<2.0，由 build.sh 消费）
// 本清单在求值阶段扫描同一目录并动态生成 target，新增插件只需建目录 + 写 Plugin.plist。
//
// 注意两点：
// - 用 #filePath 定位项目根，不依赖清单执行时的 CWD。
// - 清单阶段报错只能用 fatalError（Tuist 会原样打印消息），所以这里给出尽量可操作的错误文案。
// - Tuist 的清单缓存键只含本文件的内容哈希，**目录扫描结果不在键内**，所以新增或删除
//   插件目录不会自动触发重扫；scripts/build.sh 构建前清掉 manifests 缓存再生成（见 run_generate）。
//
// 例外：Plugins/LidAngleKit 不含 Plugin.plist，它不是插件而是**可复用动态库**
// （盖角传感器，见 docs/agent-notes/implemented/2026-09-11-lid-angle-depth-effect.md）。
// 它在下方 targets 里显式登记，插件经 Dependencies 白名单引用；因此它不参与插件发现。

import Foundation
import ProjectDescription

func manifestFatal(_ message: String) -> Never {
    fatalError("Project.swift 插件发现失败：\(message)")
}

let manifestRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pluginsRoot = manifestRoot.appendingPathComponent("Plugins", isDirectory: true)

// 复用库白名单：这些目录是**可复用动态库**而不是插件，允许没有 Plugin.plist。
// 它们只在下方 targets 里显式登记，由插件的 Dependencies 引用。
// 用白名单而非"没有 Plugin.plist 就跳过"：后者会让漏写元数据的插件被静默漏打包，
// 正是下面那条 guard 要拦的事故。
let sharedLibraryDirNames: Set<String> = ["LidAngleKit"]

let pluginDirs: [URL] = {
    do {
        return try FileManager.default
            .contentsOfDirectory(at: pluginsRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .filter { !sharedLibraryDirNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        manifestFatal("无法读取 Plugins/ 目录：\(error.localizedDescription)")
    }
}()

if pluginDirs.isEmpty {
    manifestFatal("\(pluginsRoot.path) 下没有发现任何插件目录")
}

struct PluginMetadata {
    let name: String           // 文件夹名，也是 target 名与 CFBundleExecutable
    let dependencies: [String] // 额外本地依赖（NotchCenterKit 之外的部分）
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

    // 额外依赖必须是本项目声明的依赖；写错名字时在这里给出明确提示，
    // 而不是让构建在后续链接阶段抛出难以定位的错误。NotchCenterKit 是隐式依赖，不用列。
    let knownExtraDependencies: Set<String> = ["MarkdownEngine", "LaunchdControlKit", "LidAngleKit"]
    let dependencies = (dict["Dependencies"] as? [String]) ?? []
    for dependency in dependencies where !knownExtraDependencies.contains(dependency) {
        manifestFatal(
            "\(name) 的 Dependencies 含未知依赖 \"\(dependency)\"；"
                + "可选值：\(knownExtraDependencies.sorted().joined(separator: ", "))。"
                + "若确需新依赖，请先在本清单 packages 里声明对应包并更新此白名单"
        )
    }

    plugins.append(PluginMetadata(name: name, dependencies: dependencies))
}

let pluginNames = plugins.map(\.name)

// MARK: - 依赖映射
// 额外依赖名 -> target 依赖。MarkdownEngine 来自 vendored 本地 SPM 包（Xcode 解析其远程依赖）；
// LaunchdControlKit / LidAngleKit 是本项目的动态库 target。新增依赖且声明方式不同时在这里补分支。
func extraDependency(_ name: String) -> TargetDependency {
    switch name {
    case "MarkdownEngine":
        return .package(product: "MarkdownEngine")
    case "LaunchdControlKit":
        return .target(name: "LaunchdControlKit")
    case "LidAngleKit":
        return .target(name: "LidAngleKit")
    default:
        manifestFatal("未知额外依赖 \(name)")
    }
}

// MARK: - 目标定义

// 共享 API 动态库：宿主与插件以「同一份 dylib」方式链接（架构文档 §2.2 / §15）。
// DYLIB_INSTALL_NAME_BASE=@rpath 使 install_name 保持 @rpath/lib<Name>.dylib，
// 与原 SwiftPM 动态库产物一致，build.sh 的 Frameworks 组装与 rpath 设计不需要任何修复。
func dynamicKitTarget(name: String, path: String) -> Target {
    .target(
        name: name,
        destinations: [.mac],
        product: .dynamicLibrary,
        bundleId: "com.notchcenter.\(name)",
        deploymentTargets: .macOS("15.0"),
        infoPlist: .default,
        sources: ["\(path)/**/*.swift"],
        dependencies: [],
        settings: .settings(
            base: [
                "DYLIB_INSTALL_NAME_BASE": "@rpath",
                "LD_RUNPATH_SEARCH_PATHS": "@executable_path/../Frameworks",
            ]
        )
    )
}

// 宿主主 App：刘海交互、窗口管理、插件生命周期、布局引擎、插件管理窗口。
// 开发态即真实 .app（xcodebuild 产物），与打包态布局完全一致：
//   Contents/MacOS/NotchCenter + Contents/Frameworks/*.dylib + Contents/PlugIns/*.bundle
// 本地化资源（en / zh-Hans.lproj）由 Tuist 声明为 target 资源，直接嵌入 Contents/Resources，
// 并合成与 SPM 同名的 Bundle.module 访问器（见 Sources/NotchCenter/Localization.swift）。
let hostTarget = Target.target(
    name: "NotchCenter",
    destinations: [.mac],
    product: .app,
    bundleId: "com.notchcenter.app",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .file(path: "Resources/Info.plist"),
    sources: ["Sources/NotchCenter/**/*.swift"],
    resources: ["Sources/NotchCenter/Resources/**"],
    dependencies: [
        .target(name: "NotchCenterKit")
    ],
    settings: .settings(
        base: [
            // 打包后宿主位于 NotchCenter.app/Contents/MacOS，经 @rpath 找到 Frameworks/ 下的共享 dylib
            "LD_RUNPATH_SEARCH_PATHS": "@executable_path/../Frameworks",
            // 关闭 Xcode 16 的 debug dylib 机制（Debug 态把代码编进 <App>.debug.dylib、主二进制只留壳）：
            // 保持与 SwiftPM 产物一致的单一可执行文件，测试符号解析（BUNDLE_LOADER）与打包脚本
            // 都按单二进制约定工作。
            "ENABLE_DEBUG_DYLIB": "NO",
        ]
    )
)

// 官方插件动态库 target，由 Plugin.plist 扫描生成。
// 打包后由 build.sh 组装为 <Name>.bundle 放进 Contents/PlugIns，
// 相对宿主 Frameworks 目录需要上溯 4 级，故 rpath 为 @executable_path/../../../../Frameworks。
let pluginTargets: [Target] = pluginNames.map { name in
    var deps: [TargetDependency] = [.target(name: "NotchCenterKit")]
    for dependency in plugins.first(where: { $0.name == name })!.dependencies {
        deps.append(extraDependency(dependency))
    }
    return .target(
        name: name,
        destinations: [.mac],
        product: .dynamicLibrary,
        bundleId: "com.notchcenter.plugin.\(name)",
        deploymentTargets: .macOS("15.0"),
        infoPlist: .default,
        sources: ["Plugins/\(name)/Sources/**/*.swift"],
        dependencies: deps,
        settings: .settings(
            base: [
                "DYLIB_INSTALL_NAME_BASE": "@rpath",
                "LD_RUNPATH_SEARCH_PATHS": "@executable_path/../../../../Frameworks",
            ]
        )
    )
}

// 测试 target 依赖全部插件模块（随 Plugins/ 目录自动伸缩）。
// TEST_HOST 指向宿主 .app 内部二进制：@testable import NotchCenter 需要从宿主可执行文件解析符号。
// 复用库（如 LidAngleKit）不在插件发现结果里，需显式列出。
var testDeps: [TargetDependency] = [
    .target(name: "NotchCenter"),
    .target(name: "NotchCenterKit"),
    .target(name: "LaunchdControlKit"),
    .target(name: "LidAngleKit"),
]
testDeps += pluginNames.map { TargetDependency.target(name: $0) }

let testTarget = Target.target(
    name: "NotchCenterTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "com.notchcenter.tests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Tests/NotchCenterTests/**/*.swift"],
    dependencies: testDeps,
    settings: .settings(
        base: [
            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/NotchCenter.app/Contents/MacOS/NotchCenter",
            "BUNDLE_LOADER": "$(TEST_HOST)",
            // 插件/Kit 动态库产物位于 BUILT_PRODUCTS_DIR 根；Kit 亦在宿主 Frameworks 内
            "LD_RUNPATH_SEARCH_PATHS": "$(BUILT_PRODUCTS_DIR) @executable_path/../Frameworks",
        ]
    )
)

// 显式 scheme：一次构建覆盖全部 target（等价于原 swift build 全量语义），
// 测试动作挂 NotchCenterTests，运行动作启动宿主 .app。
// TargetReference 兼容字符串字面量（当前项目内的 target 名）。
let scheme = Scheme.scheme(
    name: "NotchCenter",
    shared: true,
    buildAction: .buildAction(
        targets: (["NotchCenter", "NotchCenterKit", "LaunchdControlKit"] + pluginNames).map(TargetReference.target)
    ),
    testAction: .targets([.testableTarget(target: "NotchCenterTests")]),
    runAction: .runAction(configuration: "Debug", executable: "NotchCenter"),
    archiveAction: .archiveAction(configuration: "Release"),
    profileAction: .profileAction(configuration: "Release", executable: "NotchCenter"),
    analyzeAction: .analyzeAction(configuration: "Debug")
)

let project = Project(
    name: "NotchCenter",
    options: .options(
        defaultKnownRegions: ["en", "zh-Hans"],
        developmentRegion: "en"
    ),
    // vendored 依赖：仅 NotesPlugin 使用；其 HighlighterSwift / SwiftMath 远程依赖由 Xcode 解析。
    packages: [
        .local(path: "Vendor/swift-markdown-engine")
    ],
    settings: .settings(
        base: [
            // 与原 swift-tools-version: 6.0 对齐：启用 Swift 6 严格并发
            "SWIFT_VERSION": "6.0",
            // 本机无开发者证书时的确定性签名（build.sh package 会按需重签）
            "CODE_SIGN_IDENTITY": "-",
            "CODE_SIGNING_REQUIRED": "NO",
        ]
    ),
    targets: [hostTarget, dynamicKitTarget(name: "NotchCenterKit", path: "Sources/NotchCenterKit"),
              dynamicKitTarget(name: "LaunchdControlKit", path: "Sources/LaunchdControlKit"),
              dynamicKitTarget(name: "LidAngleKit", path: "Plugins/LidAngleKit")]
        + pluginTargets
        + [testTarget],
    schemes: [scheme]
)
