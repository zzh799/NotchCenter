// swift-tools-version: 6.0
// LaunchdControlKit — 纯 launchd / shell 封装基础库（独立本地包）。
//
// 只依赖 Foundation，对宿主体系零感知：探测（LaunchdProbe）、副作用操作
// （LaunchdControl）、plist 读写生成（LaunchdPlist）三层刻意分离，
// 让调用方一眼判断代码会不会改系统状态。所有 API 同步阻塞，调用方负责
// 丢到后台线程执行。

import PackageDescription

let package = Package(
    name: "LaunchdControlKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LaunchdControlKit", type: .dynamic, targets: ["LaunchdControlKit"])
    ],
    targets: [
        .target(
            name: "LaunchdControlKit",
            path: ".",
            exclude: ["Package.swift"]
        )
    ]
)
