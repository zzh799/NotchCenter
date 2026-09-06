# Tuist 使用指南

> 构建体系自 2026-09 起由 SwiftPM 迁移到 Tuist（版本经 `mise.toml` 固定）。本文是日常操作手册：环境准备、常用命令、插件开发流程与常见问题。构建体系的设计背景见 [宿主开发约定](agents/宿主开发约定.md)。

## 1. Tuist 在本项目的角色

- **源真相**：根目录 `Project.swift` 描述全部 target（宿主 .app、NotchCenterKit / LaunchdControlKit 动态库、全部插件动态库、测试），Xcode 工程文件由 `tuist generate` 生成，**不入库**（已 gitignore）。
- **插件自动发现**：插件的唯一登记处仍是各插件的 `Plugins/<Name>/Plugin.plist`。Project.swift 求值时扫描 `Plugins/` 动态生成 target，新增插件零清单改动。
- **build.sh 是日常入口**：`scripts/build.sh` 封装 `tuist generate + xcodebuild`，覆盖构建、测试、组装、发布全流程；直接敲 `tuist` 只在需要 IDE/调清单时用到。

## 2. 环境准备

```bash
mise install            # 按 mise.toml 安装固定版本的 Tuist
tuist version           # 校验（首次需保证 mise shim 在 PATH 上）
```

未装 mise 时也可 `brew install tuist`，但版本以 `mise.toml` 为准，升级需同步 PR。

## 3. 日常命令

```bash
./scripts/build.sh dev [debug|release]   # 构建 + 组装插件 bundle 进产物 .app（默认增量：内容未变跳过构建复用上次产物）
./scripts/build.sh dev [debug|release] --full   # 强制全量构建（跳过增量指纹判断，重新 generate + build）
./scripts/build.sh run [debug|release]   # dev 之后立即启动宿主 .app 内部二进制（同支持 --full/-f）
./scripts/build.sh test [<filter>]       # 全量测试；<filter> 定向复验（套件或 套件/用例）
./scripts/build.sh package [-i] [-g]     # 发布通用 .app + zip + sha256（-i 安装，-g 发 Release）
./scripts/build.sh clean                 # 清理 .build 与 dist.noindex
```

说明：

- `dev`/`run` 默认是**增量构建**：对构建输入（Project.swift、mise.toml、`Sources/`、`Plugins/`、`Resources/`、`Vendor/`）做内容指纹，与上次成功构建的指纹比对；内容未变化且产物在位时直接跳过 `tuist generate + xcodebuild` 复用上次产物（秒级返回）。指纹状态存于 `.build/dev-state/`，`clean` 时一并清除。`--full`/`-f` 强制全量构建（Tuist 升级、Xcode 升级、构建环境变化后建议使用）。
- `dev` 的产物是真实 `.app`（位于 `.build/xcode/Build/Products/<config>/NotchCenter.app`），插件 bundle 组装进它的 `Contents/PlugIns/`，开发态与打包态目录布局完全一致。
- `run` 直接 exec `.app` 内部二进制，终端可见 stdout，`NOTCHCENTER_LAYOUT_FILE` 等环境变量覆盖照常生效。
- `test` 的 `<filter>` 等价旧 `swift test --filter`：`./scripts/build.sh test ResizeHysteresisTests` 跑一个套件，`./scripts/build.sh test ResizeHysteresisTests/testXxx` 跑单个用例。

## 4. IDE 工作流

```bash
tuist generate           # 生成并自动打开 NotchCenter.xcworkspace（脚本场景加 --no-open）
tuist edit               # 在 Xcode 里编辑 Project.swift 等清单（带补全）
```

- 生成的显式 scheme `NotchCenter` 一次构建全部 target，并挂好测试（NotchCenterTests）与运行动作；⌘R 直接跑宿主。
- 新增/删除源文件后**不需要**重新 generate（文件引用用同步组），但改 `Project.swift`、增删 target、增删插件后需要重跑。
- `.build`、`Derived/`、`*.xcodeproj`、`*.xcworkspace` 都是再生制品，随时可删。

## 5. 新增插件

1. 建目录 `Plugins/<Name>/`，写 `Plugin.plist`（必填 PluginID / Version / DisplayName / Description）与 `Sources/`、`Resources/`（en + zh-Hans 的 Localizable.strings）。
2. 不改任何清单或脚本，直接 `./scripts/build.sh dev`：build.sh 会 touch `Project.swift` 强制 Tuist 重扫清单，新 target 自动出现。
3. 需要额外依赖（默认只隐式注入 NotchCenterKit）时，在 Project.swift 的 `knownExtraDependencies` 白名单登记，并在 `extraDependency(_:)` 补映射。

## 6. Target 与产物布局速查

| Target | 类型 | 产物 |
| --- | --- | --- |
| NotchCenter | .app | `Contents/MacOS/NotchCenter` + Resources（lproj 内嵌） |
| NotchCenterKit | .dynamicLibrary | `libNotchCenterKit.dylib`（Xcode 自动嵌入 .app/Frameworks） |
| LaunchdControlKit | .dynamicLibrary | `libLaunchdControlKit.dylib`（宿主不直接链接，build.sh 补进 Frameworks） |
| 各插件 | .dynamicLibrary | `lib<Name>.dylib`（build.sh 组装为 `<Name>.bundle` 进 PlugIns） |
| NotchCenterTests | .unitTests | TEST_HOST 指向宿主 .app，@testable import 全部模块 |

- 所有动态库 `DYLIB_INSTALL_NAME_BASE=@rpath`；插件 rpath `@executable_path/../../../../Frameworks`，宿主 `@executable_path/../Frameworks`，开发/打包共用一套。
- 宿主 `Bundle.module` 访问器由 Tuist 合成（与 SwiftPM 同名兼容），本地化资源经 Xcode 变体组嵌入 `.app/Contents/Resources/`。

## 7. 发布

```bash
APP_VERSION=1.2.0 BUILD_NUMBER=42 ./scripts/build.sh package          # 通用 .app + zip + sha256
APP_VERSION=1.2.0 SIGN_IDENTITY="Developer ID Application: ..." \
  NOTARY_PROFILE=notary-profile ./scripts/build.sh package            # 签名 + 公证
./scripts/build.sh package -i                                         # 打包后覆盖安装到 /Applications
./scripts/build.sh package -g                                         # 发布到 GitHub Release（latest 标签覆盖式更新）
```

`package` 用 `xcodebuild clean build`（`ARCHS="arm64 x86_64"`）保证可复现的通用架构产物，流程为：构建 → 补齐 LaunchdControlKit 与插件 bundle → 注入版本号 → 生成图标 → ad-hoc/正式签名 → 校验 → zip + sha256 →（可选）公证与发布。

## 8. 常见问题

- **新增插件没被识别**：Tuist 按内容哈希缓存清单求值。build.sh 每次会 touch Project.swift；手工调 `tuist generate` 前请 `touch Project.swift`。
- **改了 Project.swift 报 target 冲突/找不到**：`rm -rf Derived/ *.xcodeproj *.xcworkspace` 后重新 `tuist generate`（全部是再生制品）。
- **为什么关闭了 debug dylib**：Xcode 16 默认在 Debug 态把代码编进 `<App>.debug.dylib`、主二进制只留壳，会破坏测试符号解析（BUNDLE_LOADER）与打包脚本的单二进制假设，Project.swift 里已显式 `ENABLE_DEBUG_DYLIB=NO`。
- **测试失败提示发现 12+ 个意外插件**：PluginManager 相关测试必须用 `makeEmptyBuiltIn()` 显式隔离内置插件目录——测试宿主是真实 .app，缺省路径会看到 build.sh 组装的真实插件。
- **vendored 依赖怎么升级**：`Vendor/swift-markdown-engine` 仍是本地 SPM 包（其 HighlighterSwift / SwiftMath 远程依赖由 Xcode 解析），升级方式与普通 SPM 包一致。

## Changelog

- v1.0.0:首次编写——Tuist 迁移落地后的环境、命令、插件流程与 FAQ。
