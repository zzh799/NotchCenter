// swift-tools-version: 6.0
// NotchCenter — 刘海交互插件宿主（由 NotchNotes 重构而来，见 docs/NotchCenter 架构设计文档.md）

import PackageDescription

let package = Package(
    name: "NotchCenter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotchCenter", targets: ["NotchCenter"]),
        // 官方插件，构建后由 Scripts 组装为独立 .bundle（内置路径 Contents/PlugIns）
        .library(name: "NotesPlugin", type: .dynamic, targets: ["NotesPlugin"]),
        .library(name: "ScratchpadPlugin", type: .dynamic, targets: ["ScratchpadPlugin"]),
        .library(name: "CaffeinatePlugin", type: .dynamic, targets: ["CaffeinatePlugin"]),
        .library(name: "DshPlugin", type: .dynamic, targets: ["DshPlugin"]),
        .library(name: "CalibrePlugin", type: .dynamic, targets: ["CalibrePlugin"])
    ],
    dependencies: [
        // 共享 API 动态库：宿主与插件以「产品」方式链接同一份 Kit 代码（架构文档 §2.2 / §15）。
        .package(path: "Sources/NotchCenterKit"),
        // 仅 NotesPlugin 使用（Markdown 编辑器）。核心不再依赖任何业务组件。
        .package(path: "Vendor/swift-markdown-engine"),
        // launchd 服务管理基础库：仅 DshPlugin / CalibrePlugin 使用（纯 shell 封装，不依赖 Kit）。
        .package(path: "LaunchdControlKit")
    ],
    targets: [
        // 宿主主 App：刘海交互、窗口管理、插件生命周期、布局引擎、插件管理窗口
        .executableTarget(
            name: "NotchCenter",
            dependencies: [
                .product(name: "NotchCenterKit", package: "NotchCenterKit")
            ],
            path: "Sources/NotchCenter",
            linkerSettings: [
                // 打包后宿主位于 NotchCenter.app/Contents/MacOS，通过 @rpath 找到 Frameworks/NotchCenterKit.dylib
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        // 官方插件 bundle 目标（动态库）。打包后位于 Contents/PlugIns/<Name>.bundle/Contents/MacOS，
        // 相对宿主 Frameworks 目录需要上溯 4 级。
        .target(
            name: "NotesPlugin",
            dependencies: [
                .product(name: "NotchCenterKit", package: "NotchCenterKit"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            path: "Plugins/NotesPlugin",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"
                ])
            ]
        ),
        .target(
            name: "ScratchpadPlugin",
            dependencies: [
                .product(name: "NotchCenterKit", package: "NotchCenterKit")
            ],
            path: "Plugins/ScratchpadPlugin",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"
                ])
            ]
        ),
        .target(
            name: "CaffeinatePlugin",
            dependencies: [
                .product(name: "NotchCenterKit", package: "NotchCenterKit")
            ],
            path: "Plugins/CaffeinatePlugin",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"
                ])
            ]
        ),
        .target(
            name: "DshPlugin",
            dependencies: [
                .product(name: "NotchCenterKit", package: "NotchCenterKit"),
                .product(name: "LaunchdControlKit", package: "LaunchdControlKit")
            ],
            path: "Plugins/DshPlugin",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"
                ])
            ]
        ),
        .target(
            name: "CalibrePlugin",
            dependencies: [
                .product(name: "NotchCenterKit", package: "NotchCenterKit"),
                .product(name: "LaunchdControlKit", package: "LaunchdControlKit")
            ],
            path: "Plugins/CalibrePlugin",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "NotchCenterTests",
            dependencies: [
                .product(name: "NotchCenterKit", package: "NotchCenterKit"),
                "NotchCenter",
                "NotesPlugin",
                "ScratchpadPlugin",
                "CaffeinatePlugin",
                "DshPlugin",
                "CalibrePlugin",
                .product(name: "LaunchdControlKit", package: "LaunchdControlKit")
            ],
            path: "Tests/NotchCenterTests"
        )
    ]
)