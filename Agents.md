# AGENTS.md — NotchCenter

给 AI 编程助手 / 协作者阅读的项目说明。人类开发者同样适用。

## 项目是什么

**NotchCenter** 是一款由 **NotchNotes** 重构而来的原生 macOS“刘海交互插件宿主”：把鼠标移到或点击屏幕顶部中央的刘海区域展开抽屉，抽屉里以网格布局显示各插件的“块”。核心只承担基础设施（刘海交互、窗口管理、插件加载与生命周期、布局引擎、状态存储、插件管理），所有业务功能（笔记、文件暂存、防休眠）都以第三方可同等替换的 **官方插件** 形式提供。

架构基线见 [`docs/NotchCenter 架构设计文档.md`](docs/NotchCenter%20架构设计文档.md)（版本 0.1，核心决策已确认）。

- 平台：macOS 14+，Apple Silicon + Intel 通用架构。
- 语言 / 工具链：`swift-tools-version: 6.0`，Swift 6 严格并发，纯 Swift Package Manager 管理。
- 技术栈：AppKit（浮层窗口 `NSPanel`、屏幕定位、全局鼠标监听）+ SwiftUI（面板、抽屉、插件管理窗口）+ 动态插件（`.bundle` + `NSPrincipalClass`）。
- 分发形态：`.app` 以 accessory 策略运行（无 Dock 图标），仅在状态栏显示菜单项；官方插件内置在 `Contents/PlugIns/`。

## 设计规范

UI 改动与新增界面时，请遵循 [`docs/DESIGN.md`](docs/DESIGN.md) 中汇总的视觉语言、配色、圆角、排版、间距、动效曲线、组件库与交互模型（近黑半透明、白色层级、连续圆角、spring 动效、贴近刘海的观感）。

## 工程结构（架构文档 §2.2）

```
NotchCenter/
├── Package.swift                 # SPM 清单：宿主 + 3 个官方插件 + 测试 target
├── Sources/NotchCenter/          # 宿主主 App（可执行 target）
│   ├── main.swift / AppDelegate.swift
│   ├── NotchPanelController.swift   # 核心控制器（hostController 实现）：每屏一对面板、展开/收起、鼠标轮询、编辑模式、多显示器跟随
│   ├── PanelUIState.swift           # 面板 UI 状态（ObservableObject，@Published 驱动 SwiftUI 刷新）
│   ├── HostPanelViews.swift         # 刘海两侧紧凑带 + 抽屉网格视图 + 编辑模式 + 添加块目录侧边栏
│   ├── NotchGeometry.swift          # 刘海/回退几何与紧凑带布局（左右面板绕刘海对称，左2右1共 3 槽，28×28，右端编辑“+”预留区）
│   ├── PluginManager.swift          # 插件发现/加载/启用禁用/安装卸载（双目录）
│   ├── PluginMetadata.swift         # Info.plist 元数据（文档 §3.2）
│   ├── LayoutEngine.swift           # 布局模型与持久化（layout.json、网格放置/重叠检测/列数约束/自由跨度缩放/一键重排/拖拽推挤与加载净化）
│   ├── PluginManagerWindow.swift    # 插件管理窗口
│   ├── SettingsStore.swift          # 触发模式（hover/click）
│   ├── CorePaths.swift / FileDragDetection.swift / PanelDecoration.swift
├── Sources/NotchCenterKit/       # 共享 API 动态库（**独立本地包**，宿主与插件以产品方式链接同一份代码）
│   ├── Package.swift             # 产物：NotchCenterKit 动态库
│   ├── NotchCenterPlugin.swift   # 协议：static blocks + init()；可选 settingsView / menuItems / 服务注入
│   ├── NotchBlock.swift          # NotchBlock / BlockKind / BlockSize / BlockInteraction
│   ├── BlockContext.swift        # BlockContext / BlockLayoutInfo / BlockRegion / PluginSettingsContext
│   ├── HostController.swift      # expand/collapse/编辑模式/刷新紧凑区
│   ├── StateStore.swift          # 插件隔离键值存储（PluginData/<pluginID>/，原子写）
│   └── APIVersion.swift          # SemanticVersion / APIVersionRange / currentVersion（文档 §9.1）
├── Plugins/                      # 官方插件源码（独立 bundle target，动态库）
│   ├── NotesPlugin/              # 笔记（MarkdownEngine 编辑器，StateStore 持久化）
│   ├── ScratchpadPlugin/         # 文件暂存（只保存路径引用）
│   └── CaffeinatePlugin/         # 防休眠（SystemSleepGuard，管理员 pmset）
├── Vendor/swift-markdown-engine/ # vendored 依赖，仅 NotesPlugin 使用
├── Scripts/package-app.sh        # 通用 .app + PlugIns/*.bundle + Frameworks + zip/sha256
├── Scripts/prepare-dev-plugins.sh# 开发期把插件 dylib 组装成 .bundle 到可执行文件旁 PlugIns/
├── Resources/                    # AppIcon.png、Info.plist
├── docs/                         # 官网（GitHub Pages 读取 main 分支）
└── .github/workflows/release.yml # CI：测试 → 构建 → 更新 GitHub Release
```

## 常用命令

```bash
# 本地运行（先准备插件 bundle）
./Scripts/prepare-dev-plugins.sh        # 组装 .build/.../debug/PlugIns/*.bundle
swift run NotchCenter

# 冒烟测试（开发期验证插件发现/加载/布局，1.5s 后自动退出）
# NOTCHCENTER_EDIT=1 可让首启直接进入编辑模式
NOTCHCENTER_SMOKE_TEST=1 swift run NotchCenter

# 面板截图验证（0.8s 展开抽屉，2.5s 把两个面板渲染为 PNG 到 /tmp/nc_*.png，无需屏幕录制权限）
# 布局文件可用 NOTCHCENTER_LAYOUT_FILE=/tmp/x.json 隔离（验证首启默认布局等）
NOTCHCENTER_SMOKE_TEST=1 NOTCHCENTER_SCREENSHOT=1 NOTCHCENTER_LAYOUT_FILE=/tmp/nc-layout.json swift run NotchCenter

# 仅编译 / 跑测试
swift build
swift test          # 或 swift test --filter <Name>

# 构建发布版通用 .app，并生成 zip + sha256
./Scripts/package-app.sh
open dist.noindex/NotchCenter.app
```

环境变量（构建脚本）：`APP_VERSION`（默认 1.0.0）、`BUILD_NUMBER`（默认 1）、`SIGN_IDENTITY`（默认 `-`，即临时签名）、`NOTARY_PROFILE`。

## 编码约定与注意事项（重要）

- **主线程隔离**：几乎所有 store、controller 与 Kit 公共 API 都标 `@MainActor`（文档 §4.9）。遵循 Swift 6 严格并发；插件内部后台任务自行处理，UI/状态更新必须回主线程。跨线程用 `Task.detached` / `DispatchQueue` 时需显式隔离（参考 `Plugins/NotesPlugin/Sources/NotesImageStore.swift` 的 `@unchecked Sendable` + `NSLock` 模式）。
- **动态链接是本架构的关键**：`NotchCenterKit` 必须是**唯一的动态库**，宿主与插件通过 `.product(name: "NotchCenterKit", package: "NotchCenterKit")` 链接同一份代码（协议身份一致）。不要让它退化为 target 级静态链接（SPM 同包产品依赖不支持，所以 Kit 是独立本地包）；Kit 源码通常只加公共 API。
- **插件主类必须 @objc(ClassName)**：SPM 动态库启用 library evolution，无显式 `@objc(...)` 时运行时类名会是 mangled 形式，`NSPrincipalClass` 找不到。新增插件时在类上写 `@objc(XxxPlugin)`，并在 `prepare-dev-plugins.sh` / `package-app.sh` 的元数据表里登记。
- **插件身份来自 Info.plist**（文档 §4.1）：`NotchCenterPluginID` / `NotchCenterPluginVersion` / `NotchCenterPluginAPIVersion` / `NotchCenterPluginDisplayName` / `NotchCenterPluginDescription` / `NSPrincipalClass`。Info.plist 模板按 `prepare-dev-plugins.sh` 里的结构生成（注意 `..<` 需要 XML 转义为 `&lt;`）。
- **持久化**：插件状态一律走注入的 `StateStore`（文档 §4.6）；核心布局走 `layout.json`（`LayoutEngine.saveToDisk()`，原子写）。宿主退出时 `AppDelegate.applicationWillTerminate → panelController.flush() → layoutEngine.saveToDisk()`。
- **文件暂存区只持有路径引用**：不复制、不移动、不删除用户原文件（`ScratchpadPlugin`）。新增文件操作时保持这一契约。
- **保持唤醒需要管理员权限**：`SystemSleepGuard` 通过 `osascript with administrator privileges` 调用 `pmset disablesleep`。**不要在单元测试里触发真实休眠抑制**；测试只验证命令字符串与 shell 语法（见 `SystemSleepGuardTests`）。
- **面板内容刷新走 `PanelUIState`**：透明无边框 `NSPanel` 上重新赋值 `NSHostingView.rootView` 不能保证立即重绘；宿主视图只在创建时设置一次 root，之后一律通过 `PanelUIState` 的 `@Published` 属性驱动 SwiftUI 刷新。新增面板状态时加到 `PanelUIState`，不要绕过它直接操作视图。
- **块尺寸用 GridSpan 表达**：`BlockSize` 只是预设，真实约束是块的 `supportedSpans`（由 `supportedSizes` 派生 + `supportedGridSpans` 自由跨度）。编辑模式缩放走 `LayoutEngine.resizeBlock` 的任意跨度路径；新增尺寸能力时扩展 `supportedGridSpans` 而不是堆预设。
- **缩放握把的量化必须带死区、平移量必须在稳定坐标系度量**：`ResizeHysteresis.quantized` 只在连续位移越过当前档位半格边界 ± band 之外才换档；`DrawerBlockContainer.resizeGesture` 必须用 `coordinateSpace: .global`。不要改回朴素 `round()`、整数距离迟滞（无实际死区，边界抖动闪烁），也不要改回默认 `.local`——握把随预览增长平移一格时 local 平移量瞬间反跳一整格，死区吸收不了，形成逐像素自激振荡。诊断：`NOTCHCENTER_RESIZE_PROBE=1` 打开复刻管线对照页，`NOTCHCENTER_RESIZE_LOG=1` 打印真实管线事件（见 `ResizeHysteresisTests` / `ResizeProbe.swift`）。
- **拖拽推挤算法不能改回“同步 +1 行”**：`pushDownOrigins`（`previewArrangement` 的核心，缩放推挤复用同一实现）的逐块安放语义是历史 bug 的修复——旧实现让所有重叠块同步下移，相对位置不变、永不分离，靠次数上限退出并把残留重叠写盘，导致粘连块对与失控行号。改动推挤逻辑前先读 `DragReorderReproTests`；`LayoutEngine` 加载时会自动净化含重叠的损坏 layout.json，勿删除该路径。
- **编辑模式契约：不留空行 + 缩放推挤 + 面板贴合**：所有变更（移动/移除/缩放/提交）后 `compactEmptyRows` 会闭合整行空洞（下方整体上移；行内部分留白保留，加载净化的留白保护不受影响）；`resizeDrawerBlock` 扩大遇下方块不再回退而是推挤下移，预览与提交走同一算法（所见即所得）；窗口高度经 `previewBottomRow`/`refreshAfterEdit` 随内容行数按需增减。回归见 `LayoutEngineTests` 的“编辑模式契约”一节。
- **Chicken-and-egg 初始化**：`NotchPanelController.init` 在 `super.init()` 之后才构建 `pluginManager` / `layoutEngine`（属性是 `private(set) var ...!`）。改动核心初始化顺序时注意。
- **UI 风格**：抽屉强制深色（`.environment(\.colorScheme, .dark)`），背景接近纯黑半透明，顶部圆角遮罩（`TopAttachedRoundedShape`）。改动视觉时保持“贴近刘海”的观感。
- **命名 / 语言**：源码标识符与 UI 字符串用英文；注释可用中文。保持与现有文件一致的风格（缩进、分组、注释密度）。
- **不要引入新的 SPM 远程依赖**，除非任务要求；优先复用 AppKit / SwiftUI / vendored 引擎。

## 测试

- 运行：`swift test`；单文件调试可 `swift test --filter <Name>`。
- 覆盖：`APIVersionTests`、`StateStoreTests`、`LayoutEngineTests`、`PluginManagerTests`（用纯 Info.plist fixture bundle，不加载真实代码）、`NotchGeometryTests`、`NoteStoreTests`、`FileShelfStoreTests`、`SystemSleepGuardTests`、`FileDragPasteboardTests`、`FileDropPasteboardReaderTests`、`FileDropPayloadTests`、`FileShelfSelectionTests`、`TransparentHitHostingViewTests`、`DragReorderReproTests`（随机拖拽不变量重放 / 粘连对回归 / 损坏布局自愈 / 留白保护）、`ResizeHysteresisTests`（缩放量化死区 / 边界抖动不翻转 / 跨档跳转 / 按下不缩小）。
- 涉及 `pmset` / 休眠的逻辑测试应确保**不真正改变系统睡眠状态**。
- 涉及 AppKit 窗口/事件的逻辑依赖 App 运行环境，注意保持 `@MainActor` 测试隔离（`setUp`/`tearDown` 是非隔离上下文，不要在里面改 @MainActor 属性）。

## 上手建议

1. 先读 `docs/NotchCenter 架构设计文档.md`，再读 `NotchCenterKit`（协议与类型）→ `Sources/NotchCenter/PluginManager.swift` → `LayoutEngine.swift` → `NotchPanelController.swift` 理解插件生命周期与面板协调。
2. 插件开发：参照 `Plugins/NotesPlugin/Sources/NotesPlugin.swift` 的入口模式（`static var blocks` + `attachServices`）。
3. UI 改动从 `HostPanelViews.swift`（紧凑区/抽屉/编辑模式）入手。