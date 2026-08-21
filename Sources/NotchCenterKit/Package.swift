// swift-tools-version: 6.0
// NotchCenterKit — 宿主与官方/第三方插件共享的动态 framework（见 docs/NotchCenter 架构设计文档.md §2.2）。
// 独立包以便宿主与插件以「产品」方式动态链接同一份代码。

import PackageDescription

let package = Package(
    name: "NotchCenterKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NotchCenterKit", type: .dynamic, targets: ["NotchCenterKit"])
    ],
    targets: [
        .target(
            name: "NotchCenterKit",
            path: ".",
            exclude: ["Package.swift"]
        )
    ]
)