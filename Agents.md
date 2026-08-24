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
├── Package.swift                 # SPM 清单：宿主 + 官方插件 + 测试 target
├── Sources/NotchCenter/          # 宿主主 App（可执行 target）
│   ├── main.swift / AppDelegate.swift
│   ├── NotchPanelController.swift   # 核心控制器（hostController 实现）：状态中枢 + 每屏一对面板 + 展开/收起 + 几何
│   ├── NotchPanelContent.swift      # 控制器 extension：视图构建（rebuildContent/build*）+ 编辑模式两段式进入
│   ├── NotchPanelInteraction.swift  # 控制器 extension：事件监听 + 鼠标轮询 + 收起协调（handleMouseLocation/scheduleCollapse）
│   ├── NotchPanelDebugSupport.swift # 控制器 extension：调试（debugTogglePin/capturePanelsForDebug）+ 插件管理窗口
│   ├── PanelWindows.swift           # 窗口类型：NotchPanel + 3 个 HostingView + ScreenPanelPair + configurePanel
│   ├── PanelUIState.swift           # 面板 UI 状态（ObservableObject，@Published 驱动 SwiftUI 刷新）
│   ├── CompactPanelView.swift       # 刘海两侧紧凑带视图（含槽位容器）
│   ├── DrawerPanelView.swift        # 抽屉面板主体（drawerWindowSize 绑定 + 顶缘钉死 + 拖拽/缩放手势状态机）
│   ├── DrawerBlockContainer.swift   # 抽屉块容器（预览尺寸补偿 + 编辑 overlay + 缩放握把 .global 手势）
│   ├── AddBlockArea.swift            # 添加块目录条（编辑模式，上栏紧凑块/下栏抽屉块）
│   ├── HorizontalDragScroll.swift    # 横向拖动滚动容器（ScrollView 内嵌 NSScrollView 探针，滚轮之外支持按住拖动）
│   ├── ResizeHysteresis.swift        # 缩放跨度死区量化（纯函数，ResizeHysteresisTests 覆盖）
│   ├── NotchGeometry.swift          # 刘海/回退几何与紧凑带布局（左右面板绕刘海对称，图标按添加顺序左右均衡交替排布，带宽随图标数动态伸缩，28×28）
│   ├── PluginManager.swift          # 插件发现/加载/启用禁用/安装卸载（双目录）
│   ├── PluginMetadata.swift         # Info.plist 元数据（文档 §3.2）
│   ├── LayoutModel.swift            # 布局数据模型（NotchGridMetrics/CompactSlotReference/PlacedBlock/LayoutModel）
│   ├── LayoutEngine.swift           # 布局引擎核心：类声明/LayoutIssue/存储属性/init（含加载）/查询/saveToDisk/重叠几何辅助
│   ├── LayoutEngineSanitization.swift # 布局引擎 extension：sanitized(_:) 加载净化（损坏布局自愈）
│   ├── LayoutEngineMutation.swift   # 布局引擎 extension：布局修改公开 API（列数/屏幕约束/启用插件/紧凑槽位/抽屉增删移缩/提交）
│   ├── LayoutEngineArrangement.swift # 布局引擎 extension：推挤与预览算法（GridOrigin/previewArrangement/pushDownOrigins/applyOrigins/validColumnRange）
│   ├── LayoutEngineCompaction.swift # 布局引擎 extension：compactEmptyRows / compactEmptyColumns 空洞压实
│   ├── LayoutEngineGeometry.swift   # 布局引擎只读 extension：frame/内容尺寸/窗口尺寸/previewBottomRow
│   ├── LayoutEngineValidation.swift # 布局引擎只读 extension：validate() 全量健康检查
│   ├── PluginManagerWindow.swift    # 插件管理窗口
│   ├── SettingsStore.swift          # 触发模式（hover/click）
│   ├── CorePaths.swift / FileDragDetection.swift / PanelDecoration.swift
│   ├── ResizeProbeLog.swift         # 诊断日志开关（仅 DEBUG）：NOTCHCENTER_RESIZE_LOG 缩放管线事件
│   ├── ResizeProbeWindow.swift      # 复刻管线对照页（仅 DEBUG）：ResizeProbeWindowController + ResizeProbeView（NOTCHCENTER_RESIZE_PROBE）
│   ├── NotchPanelController+CollapseProbe.swift    # 控制器 extension（仅 DEBUG）：收起动画 layer 树 dump + 逐帧自拍 + 合成鼠标取屏共享辅助
│   ├── NotchPanelController+DragScrollProbe.swift  # 控制器 extension（仅 DEBUG）：目录条拖动自动化探针（NOTCHCENTER_DRAGSCROLL_AUTO）
│   ├── NotchPanelController+ResizeAutoProbe.swift  # 控制器 extension（仅 DEBUG）：缩放自动化复现探针（NOTCHCENTER_RESIZE_AUTO）
│   ├── NotchPanelController+ShrinkScrollProbe.swift # 控制器 extension（仅 DEBUG）：缩小场景滚动条逐帧诊断（NOTCHCENTER_SHRINKSCROLL_PROBE）
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
│   ├── CaffeinatePlugin/         # 防休眠（SystemSleepGuard，管理员 pmset）
│   ├── DshPlugin/                # dsh-web 服务控制卡（launchd 服务控制插件，见 docs/服务控制插件开发指南.md）
│   ├── CalibrePlugin/            # calibre-server 服务控制卡（同上）
│   └── OpenCodeUsagePlugin/      # OpenCode 用量卡（抓取 opencode.ai SSR 页，同心环用量图 + Zen 余额）
├── LaunchdControlKit/            # launchd 管理基础库（独立本地包，仅服务控制类插件使用）
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
- **紧凑区宽度动态、不固定槽位（文档 §5.2）**：`compactSlots` 数组长度即当前紧凑图标数（元素无 `null` 占位；移除即删元素闭合空隙，旧版固定 3 槽文件加载时经 `normalizedCompactSlots` 剥除空槽）。带宽 = `CompactStripLayout(slotCount:)`：图标按添加顺序**左右均衡交替**排布（偶数索引在左、奇数在右，均从靠刘海一侧排起），两面板等宽（按较大一侧实际槽数）保证黑色带绕刘海左右对称、刘海中心恒为带宽中心。视图侧必须从 `PanelUIState.compactCount` 取数量（`layout.compactStrip(slotCount: ui.compactCount)`），不得硬编码槽位数——宿主视图只在创建时设置一次 root，`layout` 是被捕获的旧值。**几何状态同步集中在 `refreshCompactGeometry()`**：把引擎计数推到各 pair 镜像（`pair.compactCount`/`pair.compactStrip`）与 `uiState.compactCount`，并按新带宽重摆热区窗口；任何增删紧凑图标（`onAddBlock`/`onRemoveBlock`）与换屏（`syncScreens` 后）的路径必须先调它、再调 `rebuildContent`（后者保持纯内容重建、无窗口副作用）。引擎计数只能经 `compactIconCount` / `compactStrip(for:)` 访问，不要在各消费点直接读 `layoutEngine.compactSlots.count`。增删紧凑块没有“槽满”概念（`AddBlockArea` 紧凑目录不再置灰、不设数量上限）。
- **抽屉动画是单一尺寸真源（参考 codex-island 的 model.size 模式）**：`PanelUIState.drawerWindowSize` 是可见面板尺寸的唯一 @Published 真源（收起 = 紧凑带尺寸），一切尺寸变化（展开/收起/编辑增高/增删块/缩放预览）必须在 `withAnimation` 里改变它；容器视图 frame 直接绑定它做 spring 变形。抽屉窗口固定满高、永不参与动画；穿透命中 = hitTest 限定可见矩形 + `window.ignoresMouseEvents` 光标跟踪双机制（缺一不可，仅 hitTest 窗口仍会抢焦点）。不要恢复 revealProgress 遮罩插值或任何“窗口跟随内容”的桥（NSAnimationContext/preference/解析 spring 均已试错，均有时钟偏差）。
- **动画容器必须顶缘钉死、收起不得无动画贴起点**：`DrawerPanelView` 绑定 `drawerWindowSize` 的容器 frame 必须 `alignment: .top`——收起过渡中抽屉内容退出布局（快照仍挂在树里淡出），VStack 与仍在收缩的容器高度不一致，默认 `.center` 会把只剩紧凑带的 VStack 顶出容器，图标随之下坠（展开方向靠 ScrollView 伸缩掩盖了同一问题）。`setDrawerRevealed` 里“无动画贴起点”只属于展开分支（贴紧凑带再 spring 长出）；收起的起点就是当前尺寸，若也无动画写成目标，收起会瞬跳且 easeOut(0.16) 动画丢失。诊断：`NOTCHCENTER_COLLAPSE_PROBE=1`（配 `NOTCHCENTER_SMOKE_TEST=1`）展开/收起各逐帧自拍抽屉窗口——注意 `cacheDisplay` 只能渲染布局终态，动画中帧必须用 `CGWindowListCreateImage` 自拍本进程窗口（免屏幕录制权限）；`NOTCHCENTER_COLLAPSE_LAYERS=1` 追加 layer 树 model/presentation 对照 dump。
- **块尺寸用 GridSpan 表达**：`BlockSize` 只是预设，真实约束是块的 `supportedSpans`（由 `supportedSizes` 派生 + `supportedGridSpans` 自由跨度）。编辑模式缩放走 `LayoutEngine.resizeBlock` 的任意跨度路径；新增尺寸能力时扩展 `supportedGridSpans` 而不是堆预设。
- **抽屉窗口单例不变量：任一时刻至多一个屏的抽屉在屏**：`collapse()` 的完成回调存在 0.43s 窗口（0.25s 延迟 + 0.18s 等收起动画），期间鼠标移到另一块屏触发跨屏展开会以“已重新展开”为由跳过旧屏的 `orderOut`，旧屏抽屉窗口永久残留——它与活动屏共享同一份 `uiState`，每次展开都渲染出一份一模一样的活抽屉（用户报告“新建笔记多出一块面板”的根因）。因此 `expand()`（含已展开分支）必须清扫 `hideOtherDrawers(keeping:)`，收起完成回调只保留“当前展开屏”而不是整体跳过，`syncScreens()` 移除 stale pair（NSScreen 身份在显示重配后更换，同一物理屏也会命中）时必须显式 orderOut 其两个窗口。不要把完成回调改回“捕获 pair + isExpanded 短路”。诊断：`NOTCHCENTER_GHOST_PROBE=1` 打印 expand/collapse/清扫决策。
- **插件块内不得让隐藏窗口复活（共享状态 × 每屏一份视图树）**：宿主把同一份 block view 塞进每块屏的抽屉树，插件里按 placementID 共享的交互状态（如 NotesPlugin 的 `EditorInteractionState`）会被**所有屏的实例并发 bind**，谁最后落地谁占有 `textView`/`containerView` 引用——隐藏屏实例赢得竞态后，任何 `makeKeyAndOrderFront`（焦点、激活）都会把已收起的抽屉窗口重新拉上屏，表现为“新建笔记时另一块屏多出一块一模一样的面板”。约束：绑定入口必须拒绝“隐藏窗口候选覆盖可见现任”（可见候选永远放行）；任何聚焦/激活调用前必须 `window.isVisible` 防护。诊断：`NOTCHCENTER_GHOST_PROBE=1` 同时打印 `[focus]` bind/focus 决策。
- **缩放握把的量化必须带死区、平移量必须在稳定坐标系度量**：`ResizeHysteresis.quantized` 只在连续位移越过当前档位半格边界 ± band 之外才换档；`DrawerBlockContainer.resizeGesture` 必须用 `coordinateSpace: .global`。不要改回朴素 `round()`、整数距离迟滞（无实际死区，边界抖动闪烁），也不要改回默认 `.local`——握把随预览增长平移一格时 local 平移量瞬间反跳一整格，死区吸收不了，形成逐像素自激振荡。诊断：`NOTCHCENTER_RESIZE_PROBE=1` 打开复刻管线对照页，`NOTCHCENTER_RESIZE_LOG=1` 打印真实管线事件（见 `ResizeHysteresisTests` / `ResizeProbeLog.swift`、`ResizeProbeWindow.swift`）。
- **拖拽推挤算法不能改回“同步 +1 行”**：`pushDownOrigins`（`previewArrangement` 的核心，缩放推挤复用同一实现）的逐块安放语义是历史 bug 的修复——旧实现让所有重叠块同步下移，相对位置不变、永不分离，靠次数上限退出并把残留重叠写盘，导致粘连块对与失控行号。改动推挤逻辑前先读 `DragReorderReproTests`；`LayoutEngine` 加载时会自动净化含重叠的损坏 layout.json，勿删除该路径。
- **编辑模式契约：不留空行 + 缩放推挤 + 面板贴合**：所有变更（移动/移除/缩放/提交）后 `compactEmptyRows` 会闭合整行空洞（下方整体上移；行内部分留白保留，加载净化的留白保护不受影响）；`resizeDrawerBlock` 扩大遇下方块不再回退而是推挤下移，预览与提交走同一算法（所见即所得）；窗口高度经 `previewBottomRow`/`refreshAfterEdit` 随内容行数按需增减。回归见 `LayoutEngineTests` 的“编辑模式契约”一节。
- **列双向扩大、行仅向下（originColumn 可为负）**：行始终顶边锚定只向下扩大（originRow 不变、非负）；列支持左右双向——块被拖出左侧时格网向左扩大（originColumn 变负，`validColumnRange` 保证合并后跨度 ≤ 容量），单右下握把只向右下扩大（无左右双握把）。渲染横坐标 = `(originColumn − gridLeft) × 步长`、宽高按占列跨度（`occupiedColumnRange`），面板绕刘海居中所以列扩大视觉上左右对称。预览期 `applyPreviewWindowSize` 必须把 `drawerWindowSize`/`drawerContentSize`/`drawerGridLeftColumn` 放进**同一次 withAnimation（与块推挤同帧，不等松手）**；`compactEmptyColumns` 会闭合负列空洞（左侧块向 0 右移，与右移对称）。回归见 `LayoutEngineTests` 的“编辑模式契约：列双向扩大（左扩）”一节与 `DragReorderReproTests` 的列跨度不变量。
- **Chicken-and-egg 初始化**：`NotchPanelController.init` 在 `super.init()` 之后才构建 `pluginManager` / `layoutEngine`（属性是 `private(set) var ...!`）。改动核心初始化顺序时注意。
- **UI 风格**：抽屉强制深色（`.environment(\.colorScheme, .dark)`），背景接近纯黑半透明，顶部圆角遮罩（`TopAttachedRoundedShape`）。改动视觉时保持“贴近刘海”的观感。
- **命名 / 语言**：源码标识符与 UI 字符串用英文；注释可用中文。保持与现有文件一致的风格（缩进、分组、注释密度）。
- **不要引入新的 SPM 远程依赖**，除非任务要求；优先复用 AppKit / SwiftUI / vendored 引擎。

## 测试

- 运行：`swift test`；单文件调试可 `swift test --filter <Name>`。
- 覆盖：`APIVersionTests`、`StateStoreTests`、`LayoutEngineTests`、`PluginManagerTests`（用纯 Info.plist fixture bundle，不加载真实代码）、`NotchGeometryTests`、`NoteStoreTests`、`FileShelfStoreTests`、`SystemSleepGuardTests`、`FileDragPasteboardTests`、`FileDropPasteboardReaderTests`、`FileDropPayloadTests`、`FileShelfSelectionTests`、`TransparentHitHostingViewTests`、`DragReorderReproTests`（随机拖拽不变量重放 / 粘连对回归 / 损坏布局自愈 / 留白保护）、`ResizeHysteresisTests`（缩放量化死区 / 边界抖动不翻转 / 跨档跳转 / 按下不缩小）、`DshPluginTests` / `CalibrePluginTests`（服务配置与 plist 模板，不触碰真实 LaunchAgent）、`OpenCodeUsageTests`（cookie 归一化 / SSR HTML 解析 / 时长短语，不发真实网络请求）、`LaunchdControlKitTests`（命令字符串构造与 plist 读写生成，不真跑 launchctl）。
- 涉及 `pmset` / 休眠的逻辑测试应确保**不真正改变系统睡眠状态**。
- 涉及 AppKit 窗口/事件的逻辑依赖 App 运行环境，注意保持 `@MainActor` 测试隔离（`setUp`/`tearDown` 是非隔离上下文，不要在里面改 @MainActor 属性）。

## 上手建议

1. 先读 `docs/NotchCenter 架构设计文档.md`，再读 `NotchCenterKit`（协议与类型）→ `Sources/NotchCenter/PluginManager.swift` → `LayoutEngine.swift` → `NotchPanelController.swift` 理解插件生命周期与面板协调。
2. 插件开发：参照 `Plugins/NotesPlugin/Sources/NotesPlugin.swift` 的入口模式（`static var blocks` + `attachServices`）。
3. launchd 服务控制类插件（DshPlugin / CalibrePlugin 模式）：按 [`docs/服务控制插件开发指南.md`](docs/服务控制插件开发指南.md) 的分层、登记清单与 workerPattern 选取规则复制扩展——launchd 探测/控制/plist 逻辑一律复用 `LaunchdControlKit`，不要在插件里另写 launchd 或 plist 处理代码。
4. UI 改动从 `CompactPanelView.swift` / `DrawerPanelView.swift` / `AddBlockArea.swift`（紧凑区/抽屉/编辑模式）入手。