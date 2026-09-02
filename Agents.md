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
│   ├── EditMenuInstaller.swift      # 隐藏主菜单（accessory 无菜单栏）：承载 ⌘C/⌘V 等标准编辑快捷键的 nil-target 动作
│   ├── NotchPanelController.swift   # 核心控制器（hostController 实现）：状态中枢 + 每屏一对面板 + 展开/收起 + 几何
│   ├── NotchPanelContent.swift      # 控制器 extension：视图构建（rebuildContent/build*）+ 编辑模式两段式进入
│   ├── NotchPanelInteraction.swift  # 控制器 extension：事件监听 + 鼠标轮询 + 收起协调（shouldKeepExpanded 守卫）
│   ├── NotchPanelController+DrawerEdit.swift # 控制器 extension：applyDrawerDrag / applyDrawerResize（抽屉内拖拽/缩放预览与提交的唯一出口）
│   ├── PanelWindows.swift           # 窗口类型：NotchPanel + 3 个 HostingView + ScreenPanelPair + configurePanel
│   ├── PanelUIState.swift           # 面板 UI 状态（ObservableObject，@Published 驱动 SwiftUI 刷新）
│   ├── CompactPanelView.swift       # 刘海两侧紧凑带视图（含槽位容器）
│   ├── ActivityIslandPanel.swift    # 活动岛面板（文档 §4.10）：固定尺寸窗口 + IslandHostingView 双机制穿透 + 多岛堆叠渲染 + HostController 活动岛实现
│   ├── DrawerPanelView.swift        # 抽屉面板主体（drawerWindowSize 绑定 + 顶缘钉死 + 拖拽/缩放）
│   ├── DrawerPageCapsule.swift      # 抽屉分页胶囊行（顶栏居中：每页一颗独立胶囊（⌂/序号/自定义名，定宽截断）+ 胶囊外两颗常驻加号；编辑模式可拖动排序、悬停改名/删除；含 DrawerPagePillLayout 槽位数学）
│   ├── DrawerPageSwipe.swift        # 滑动切页判据（方向门槛 + 横纵压比纯函数 / 跟手位移与落位阈值 / 触控板轻扫累加器，注入时钟可重放）
│   ├── DrawerScrollProbe.swift      # 滑动切页让路探针（窗口 contentView 向下子树枚举 NSScrollView/NSClipView，判"光标在内 ∧ 横向溢出"；命中链 walk 禁用，反向推断仅 macOS 15+，NOTCHCENTER_SCROLL_PROBE_LOG 诊断）
│   ├── DrawerBlockContainer.swift   # 抽屉块容器（预览尺寸补偿 + 编辑 overlay + 缩放握把 .global 手势）
│   ├── DrawerInteractionState.swift # 拖拽/缩放手势状态机（phase + previewOrigins + 可注入 Bridge）
│   ├── DrawerGestureMath.swift      # 手势数学纯函数（DragTargetResolver / ResizeSpanResolver / ResizeCompensation / DrawerResizeLimits）
│   ├── DrawerGridGeometry.swift     # 坐标换算三层（GridMetrics / GridCell / DrawerGridGeometry 格↔内容px / DrawerScreenMapper 内容↔屏幕，互逆由结构保证）
│   ├── DrawerDropPolicy.swift       # 落点区域判定（紧凑带/顶栏/网格/面板外，纯几何）
│   ├── DrawerLayoutMetrics.swift    # 面板尺寸指标（contentSize / windowSize / leftColumn: Int?，纯计算）
│   ├── DrawerStayConditions.swift   # 收起守卫（展开态保持条件的值快照 + 纯函数判定）
│   ├── GridMetrics.swift            # 网格指标值快照（NotchGridMetrics 转发源，步长/内容尺寸唯一公式）
│   ├── ResizeHysteresis.swift       # 缩放跨度死区量化（纯函数，ResizeHysteresisTests 覆盖）
│   ├── NotchGeometry.swift          # 刘海/回退几何与紧凑带布局（左右面板绕刘海对称，图标按添加顺序左右均衡交替排布，带宽随图标数动态伸缩，28×28）
│   ├── PluginManager.swift          # 插件发现/加载/启用禁用/安装卸载（双目录）
│   ├── PluginMetadata.swift         # Info.plist 元数据（文档 §3.2）
│   ├── LayoutModel.swift            # 布局数据模型（NotchGridMetrics/CompactSlotReference/PlacedBlock/LayoutModel；块带 page 字段，页面集合 drawerPages）
│   ├── LayoutEngine.swift           # 布局引擎核心：类声明/LayoutIssue/存储属性/init（含加载）/查询/saveToDisk/重叠几何辅助
│   ├── LayoutEngineSanitization.swift # 布局引擎 extension：sanitized(_:) 加载净化（损坏布局自愈）
│   ├── LayoutEngineMutation.swift   # 布局引擎 extension：布局修改公开 API（列数/屏幕约束/启用插件/紧凑槽位/抽屉增删移缩/增页/提交）
│   ├── LayoutEngineArrangement.swift # 布局引擎 extension：推挤与预览算法（GridOrigin/previewArrangement/pushDownOrigins/placeInOrder/applyOrigins/validColumnRange；moving 拖拽为插入序安放，下移压到下方块即交换、与上移同阈值；容量缩小越界重排 repairCapacityOverflow）
│   ├── LayoutEngineCompaction.swift # 布局引擎 extension：compactEmptyRows / compactEmptyColumns 空洞压实（按页分组）
│   ├── LayoutEngineGeometry.swift   # 布局引擎只读 extension：frame/内容尺寸/窗口尺寸/previewBottomRow
│   ├── LayoutEngineValidation.swift # 布局引擎只读 extension：validate() 全量健康检查
│   ├── PluginManagerWindow.swift    # 插件管理窗口（详情区展示各插件 bundle 内 README.md）+ showPluginManager 入口
│   ├── SettingsWindow.swift / SettingsPages.swift  # 设置面板（侧边栏多页：通用/组件/布局/插件）+ 各页面（拖拽到抽屉/快速区、网格指标可调）
│   ├── ColumnRangeSlider.swift       # 设置-布局「列数」双游标滑条（最小/最大列数共轨；量化档变即回调 → refreshAfterLayoutChange 逐档生效，ColumnRangeSliderMath 纯函数可单测）
│   ├── GridMetricsStore.swift       # 抽屉网格指标存储（单元宽/高/间距/内边距，UserDefaults 持久化 + 变更通知）
│   ├── BlockDragCoordinator.swift   # 跨窗口拖拽协调器：设置面板 → 抽屉/快速区（跟随光标的预览浮窗 + 落点命中 + 落位）
│   ├── BlockDropTargeting.swift     # 控制器 extension：拖拽落点命中测试（dropZone）+ 落位执行（performBlockDrop/addBlock）+ 落点高亮写入 uiState
│   ├── ReadmeMarkdownView.swift     # 轻量 Markdown 块解析渲染（ReadmeMarkdownTests）
│   ├── SettingsStore.swift          # 触发模式（hover/click）+ 开机自启 + 语言覆盖
│   ├── LaunchAtLogin.swift          # 开机自启（SMAppService，幂等设置 + 状态同步）
│   ├── Localization.swift           # 宿主 L()/LF() 本地化辅助（资源打进 NotchCenter_NotchCenter.bundle）
│   ├── CorePaths.swift / FileDragDetection.swift / PanelDecoration.swift
├── Sources/NotchCenterKit/       # 共享 API 动态库（**独立本地包**，宿主与插件以产品方式链接同一份代码）
│   ├── Package.swift             # 产物：NotchCenterKit 动态库
│   ├── NotchCenterPlugin.swift   # 协议：static blocks + init()；可选 settingsView / menuItems / 服务注入
│   ├── NotchBlock.swift          # NotchBlock / BlockKind / BlockSize / BlockInteraction
│   ├── BlockContext.swift        # BlockContext / BlockLayoutInfo（含 `isPreview`：只读预览副本，插件须为其让出共享交互状态）/ BlockRegion / PluginSettingsContext
│   ├── ActivityIsland.swift      # ActivityIslandContent：活动岛内容（插件活动状态的专属 UI，文档 §4.10）
│   ├── BlockPopover.swift        # 长按浮窗基础组件：单例互斥生命周期 / 叠在块上方 / 统一外观 / spring 弹出动画 / 收回抽屉自动消失
│   ├── SettingPopover.swift      # 设置浮窗 SettingPopover：所有插件设置的统一浮层展示（标题行+分隔线+插件设置视图），窗口管线复用 BlockPopover
│   ├── BlockCard.swift           # 块卡片壳 BlockCard（统一底色/发丝描边/可选悬停，纯视觉零手势）+ .blockPopoverTrigger（浮窗触发器：点击/长按均回调锚点 frame，长按 0.2s、按压增亮、长按抑制点击）
│   ├── HostController.swift      # expand/collapse/编辑模式/刷新紧凑区
│   ├── StateStore.swift          # 插件隔离键值存储（PluginData/<pluginID>/ + placements/<placementID>/ 实例作用域，原子写）
│   ├── L10n.swift                # 跨模块本地化基座 L10n.string（故意不提供 CVarArg 变参重载，见文件头注释）
│   └── APIVersion.swift          # SemanticVersion / APIVersionRange / currentVersion（文档 §9.1）
├── Sources/LaunchdControlKit/    # launchd 管理基础库（**独立本地包**，仅服务控制类插件使用；不在 NotchCenterKit 内）
│   ├── Package.swift             # 产物：LaunchdControlKit 动态库
│   └── LaunchdProbe.swift / LaunchdControl.swift / LaunchdPlist.swift / Shell.swift
├── Plugins/                      # 官方插件源码（独立 bundle target，动态库）
│   ├── NotesPlugin/              # 笔记（MarkdownEngine 编辑器，StateStore 持久化）
│   ├── ScratchpadPlugin/         # 文件暂存（只保存路径引用）
│   ├── CaffeinatePlugin/         # 防休眠（SystemSleepGuard，管理员 pmset）
│   ├── PomodoroPlugin/           # 番茄钟（专注/休息循环 + 随机提示音微休息；运行时经活动岛常驻刘海下方，参考 JokerQianwei/Focus）
│   ├── DshPlugin/                # dsh-web 服务控制卡（launchd 服务控制插件，见 docs/服务控制类插件开发指南.md）
│   ├── CalibrePlugin/            # calibre-server 服务控制卡（同上）
│   └── OpenCodeUsagePlugin/      # OpenCode 用量卡（抓取 opencode.ai SSR 页，同心环用量图 + Zen 余额）
├── Vendor/swift-markdown-engine/ # vendored 依赖，仅 NotesPlugin 使用
├── Scripts/build.sh              # 统一构建脚本：dev / run / package（发布 .app，可选 -i 安装、-g 发 GitHub Release）/ clean
├── Resources/                    # AppIcon.png、Info.plist（打包态）、Info.dev.plist（开发态嵌入二进制的最小声明，见 Package.swift linkerSettings）
├── docs/                         # 官网（GitHub Pages 读取 main 分支）；agents/ 子目录是本文件的领域子文档
└── .github/workflows/release.yml # CI：测试 → 构建 → 更新 GitHub Release
```

## 常用命令

```bash
# 本地运行（先准备插件 bundle）
./Scripts/build.sh dev [debug|release]  # 组装 .build/<config>/PlugIns/*.bundle
./Scripts/build.sh run [debug|release]  # 等价于 dev 后立即启动 NotchCenter

# 仅编译 / 跑测试
swift build
swift test          # 或 swift test --filter <Name>

# 构建发布版通用 .app，并生成 zip + sha256
./Scripts/build.sh package
open dist.noindex/NotchCenter.app
# package 可选：-i/--install 打包后覆盖安装到 /Applications；-g/--github 把 zip 发布到 GitHub Release（latest 标签覆盖式更新，需已登录 gh CLI）

# 清理构建产物（.build 与 dist.noindex）
./Scripts/build.sh clean
```

环境变量（构建脚本）：`APP_VERSION`（默认 1.0.0）、`BUILD_NUMBER`（默认 1）、`SIGN_IDENTITY`（默认 `-`，即临时签名）、`NOTARY_PROFILE`。

## 编码约定与红线

各领域的完整机制、历史事故与回归测试清单拆分在 [`docs/agents/`](docs/agents/) 下；这里只保留单行结论。**改到对应领域前先读对应子文档**——只凭单行结论动手，容易把已修复的坑改回去。

### 通用

- **主线程隔离**：几乎所有 store、controller 与 Kit 公共 API 都标 `@MainActor`（文档 §4.9）。遵循 Swift 6 严格并发；插件内部后台任务自行处理，UI/状态更新必须回主线程。跨线程用 `Task.detached` / `DispatchQueue` 时需显式隔离（参考 `Plugins/NotesPlugin/Sources/NotesImageStore.swift` 的 `@unchecked Sendable` + `NSLock` 模式）。
- **持久化**：插件状态一律走注入的 `StateStore`（文档 §4.6）；核心布局走 `layout.json`（`LayoutEngine.saveToDisk()`，原子写）。宿主退出时 `AppDelegate.applicationWillTerminate → panelController.flush() → layoutEngine.saveToDisk()`。
- **命名 / 语言**：源码标识符与 UI 字符串用英文；注释可用中文。保持与现有文件一致的风格（缩进、分组、注释密度）。
- **多语言（en / zh-Hans）**：所有面向用户的字符串一律走本地化表，不许硬编码；en 是基准键集，zh-Hans 键集合必须一致（`LocalizationTests` 强制校验）。机制与 `L10n` 变参限制见 [`docs/agents/系统集成与多语言.md`](docs/agents/系统集成与多语言.md)。
- **不要引入新的 SPM 远程依赖**，除非任务要求；优先复用 AppKit / SwiftUI / vendored 引擎。
- **Chicken-and-egg 初始化**：`NotchPanelController.init` 在 `super.init()` 之后才构建 `pluginManager` / `layoutEngine`（属性是 `private(set) var ...!`）。改动核心初始化顺序时注意。

### 插件开发 → [`docs/agents/插件开发约定.md`](docs/agents/插件开发约定.md)

- `NotchCenterKit` 必须是**唯一动态库**（宿主与插件链接同一份代码），不得退化为 target 级静态链接。
- 插件主类必须 `@objc(XxxPlugin)`；插件唯一登记处是 `Plugins/<Name>/Plugin.plist`，不要在任何脚本或清单里手工维护插件列表。
- 文件暂存区只持有路径引用：不复制、不移动、不删除用户原文件。
- 抽屉块卡片壳一律用 Kit 的 `BlockCard`，长按浮窗触发一律用 `.blockPopoverTrigger`；触发器是 DragGesture 管线，不要改回 TapGesture + 长按组合。
- 每实例状态走 `placementStore` + `instanceSettingsView` + `placementWasRemoved` 三件套；服务钩子必须保持为协议**要求**（extension 默认实现会被存在类型静态分发遮蔽）。

### 面板与抽屉 → [`docs/agents/面板与抽屉.md`](docs/agents/面板与抽屉.md)

- 面板内容刷新一律走 `PanelUIState` 的 `@Published`，不要绕过它直接操作视图。
- `rebuildContent` 的块视图走**复用键缓存**（`BlockViewCacheKey`）：makeView 可观察输入（身份/frame/origin 跨度/isEditing/isPreview/entry 身份）逐项相等就复用上一次的视图值；新增 `BlockLayoutInfo` 字段或插件读到新的 makeView 输入时**必须同步扩键**；插件启用/禁用/安装/卸载路径必须整体失效两份缓存（`onEnabledPluginIDsChanged` 已统一清理）。
- 抽屉动画单一尺寸真源：一切尺寸变化必须在 `withAnimation` 里改 `PanelUIState.drawerWindowSize`；不要恢复 revealProgress 遮罩或任何“窗口跟随内容”的桥；动画容器顶缘钉死（`alignment: .top`），收起不得无动画贴起点。
- 抽屉窗口单例：任一时刻至多一个屏的抽屉在屏——`expand()`（含已展开分支）必须清扫 `hideOtherDrawers(keeping:)`，收起完成回调只保留“当前展开屏”，`syncScreens()` 移除 stale pair 必须显式 orderOut。
- 插件块不得让隐藏窗口复活：绑定入口必须拒绝“隐藏窗口候选覆盖可见现任”，任何聚焦/激活调用前必须 `window.isVisible` 防护。
- 抽屉强制深色、近黑半透明、顶部圆角遮罩，保持“贴近刘海”观感。

### 抽屉分页与滑动切页 → [`docs/agents/抽屉分页与滑动切页.md`](docs/agents/抽屉分页与滑动切页.md)

- 页面**索引恒为身份、显示序列可排序**：`normalizedPages` 绝不排序；新页索引只在既有权值外侧生成；块与页的增删必须同一次写盘；所有网格算法只作用于同一页内的块。
- 滑动切页判据全在 `DrawerPageSwipe`、判定与会话住在控制器；触控板通路必须过滤 `momentumPhase`（写 `.isEmpty`）且不消费事件；**提交分两拍**（spring 落位 → 同帧无动画换页），预览层在落位帧就地撤除并走 `isPreview` 契约。

### 布局引擎与网格 → [`docs/agents/布局引擎与网格.md`](docs/agents/布局引擎与网格.md)

- 推挤算法 `pushDownOrigins` **不能改回“同步 +1 行”**；`placeInOrder` 的落点查找是**禁放区间跳跃**（与旧逐行 +1 逐位等价，每帧路径的热点）；缩放握把量化必须带 `ResizeHysteresis` 死区且用 `.global` 坐标——三者都是历史事故/性能基线的产物，改前先读对应回归测试。
- 行仅向下扩大、列双向（`originColumn` 可为负）；最大列数缩小走 `repairCapacityOverflow` 越界重排（不能用 `applyOrigins`/`validColumnRange` 修）。
- 最小行/列数只夹尺寸、不动块原点；网格容器高度与窗口高度必须按**同一份** `minimumRows` 夹紧，且与 `drawerContentSize` 在同一次 `rebuildContent` 里写。
- 编辑模式契约：不留空行 + 缩放推挤 + 面板贴合；块尺寸用 `GridSpan` 表达，新增尺寸能力扩展 `supportedGridSpans` 而不是堆预设。

### 紧凑区与活动岛 → [`docs/agents/紧凑区与活动岛.md`](docs/agents/紧凑区与活动岛.md)

- 紧凑区宽度动态、不固定槽位：几何同步集中在 `refreshCompactGeometry()`（先于 `rebuildContent`）；引擎计数只经 `compactIconCount` / `compactStrip(for:)` 读，不得硬编码槽位数。
- 活动岛是固定窗口 + 内容内动画 + hitTest/ignoresMouseEvents 双机制穿透；`showActivityIsland` / `removeActivityIsland` 必须保持为 HostController 协议要求。

### 系统集成 → [`docs/agents/系统集成与多语言.md`](docs/agents/系统集成与多语言.md)

- ⌘C/⌘V 等标准编辑快捷键依赖 `EditMenuInstaller` 安装的隐藏主菜单，不要删除或改成固定 target。
- 保持唤醒经 `osascript with administrator privileges` 调 `pmset`；**单元测试不得真实触发休眠抑制**。

## 测试

- 运行：`swift test`；单文件调试可 `swift test --filter <Name>`。
- 全量测试 target 覆盖清单见 [`docs/agents/测试指南.md`](docs/agents/测试指南.md)。
- 涉及 `pmset` / 休眠的测试不真正改变系统睡眠状态；AppKit 窗口/事件测试保持 `@MainActor` 隔离（`setUp`/`tearDown` 是非隔离上下文，不要在里面改 @MainActor 属性）。

## 上手建议

1. 先读 `docs/NotchCenter 架构设计文档.md`，再读 `NotchCenterKit`（协议与类型）→ `Sources/NotchCenter/PluginManager.swift` → `LayoutEngine.swift` → `NotchPanelController.swift` 理解插件生命周期与面板协调。
2. 改到某个领域（面板/分页/布局/插件/紧凑区/系统集成）前，先读 [`docs/agents/`](docs/agents/) 下对应子文档——那里有完整机制与历史教训。
3. 插件开发：先读 [`docs/插件开发指南.md`](docs/插件开发指南.md)（入口协议、Plugin.plist 登记、构建验证），再参照 `Plugins/NotesPlugin/Sources/NotesPlugin.swift` 的入口模式（`static var blocks` + `attachServices`）。
4. launchd 服务控制类插件（DshPlugin / CalibrePlugin 模式）：按 [`docs/服务控制类插件开发指南.md`](docs/服务控制类插件开发指南.md) 的分层、五件套与 workerPattern 选取规则复制扩展——launchd 探测/控制/plist 逻辑一律复用 `LaunchdControlKit`，不要在插件里另写 launchd 或 plist 处理代码。
5. UI 改动从 `CompactPanelView.swift` / `DrawerPanelView.swift`（紧凑区/抽屉/编辑模式）入手。
