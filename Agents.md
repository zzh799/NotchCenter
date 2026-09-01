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
│   ├── LayoutEngineArrangement.swift # 布局引擎 extension：推挤与预览算法（GridOrigin/previewArrangement/pushDownOrigins/placeInOrder/applyOrigins/validColumnRange；moving 拖拽为插入序安放，下移压到下方块即交换、与上移同阈值）
│   ├── LayoutEngineCompaction.swift # 布局引擎 extension：compactEmptyRows / compactEmptyColumns 空洞压实（按页分组）
│   ├── LayoutEngineGeometry.swift   # 布局引擎只读 extension：frame/内容尺寸/窗口尺寸/previewBottomRow
│   ├── LayoutEngineValidation.swift # 布局引擎只读 extension：validate() 全量健康检查
│   ├── PluginManagerWindow.swift    # 插件管理窗口（详情区展示各插件 bundle 内 README.md）+ showPluginManager 入口
│   ├── SettingsWindow.swift / SettingsPages.swift  # 设置面板（侧边栏多页：通用/组件/布局/插件）+ 各页面（拖拽到抽屉/快速区、网格指标可调）
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
├── docs/                         # 官网（GitHub Pages 读取 main 分支）
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

## 编码约定与注意事项（重要）

- **主线程隔离**：几乎所有 store、controller 与 Kit 公共 API 都标 `@MainActor`（文档 §4.9）。遵循 Swift 6 严格并发；插件内部后台任务自行处理，UI/状态更新必须回主线程。跨线程用 `Task.detached` / `DispatchQueue` 时需显式隔离（参考 `Plugins/NotesPlugin/Sources/NotesImageStore.swift` 的 `@unchecked Sendable` + `NSLock` 模式）。
- **动态链接是本架构的关键**：`NotchCenterKit` 必须是**唯一的动态库**，宿主与插件通过 `.product(name: "NotchCenterKit", package: "NotchCenterKit")` 链接同一份代码（协议身份一致）。不要让它退化为 target 级静态链接（SPM 同包产品依赖不支持，所以 Kit 是独立本地包）；Kit 源码通常只加公共 API。
- **插件主类必须 @objc(ClassName)**：SPM 动态库启用 library evolution，无显式 `@objc(...)` 时运行时类名会是 mangled 形式，`NSPrincipalClass` 找不到。新增插件时在类上写 `@objc(XxxPlugin)`；插件的唯一登记处是 `Plugins/<Name>/Plugin.plist`（Package.swift 与 build.sh 都从 Plugins/ 自动发现，不要在任何脚本或清单里手工维护插件列表）。
- **插件身份来自 Info.plist**（文档 §4.1）：`NotchCenterPluginID` / `NotchCenterPluginVersion` / `NotchCenterPluginAPIVersion` / `NotchCenterPluginDisplayName` / `NotchCenterPluginDescription` / `NSPrincipalClass`。这些字段由 build.sh 从各插件的 `Plugins/<Name>/Plugin.plist`（必填 PluginID/Version/DisplayName/Description，可选 Dependencies/NSPrincipalClass/APIVersionRange）生成进 bundle 的 Info.plist（注意 `..<` 需要 XML 转义为 `&lt;`）。
- **持久化**：插件状态一律走注入的 `StateStore`（文档 §4.6）；核心布局走 `layout.json`（`LayoutEngine.saveToDisk()`，原子写）。宿主退出时 `AppDelegate.applicationWillTerminate → panelController.flush() → layoutEngine.saveToDisk()`。
- **文件暂存区只持有路径引用**：不复制、不移动、不删除用户原文件（`ScratchpadPlugin`）。新增文件操作时保持这一契约。
- **保持唤醒需要管理员权限**：`SystemSleepGuard` 通过 `osascript with administrator privileges` 调用 `pmset disablesleep`。**不要在单元测试里触发真实休眠抑制**；测试只验证命令字符串与 shell 语法（见 `SystemSleepGuardTests`）。
- **面板内容刷新走 `PanelUIState`**：透明无边框 `NSPanel` 上重新赋值 `NSHostingView.rootView` 不能保证立即重绘；宿主视图只在创建时设置一次 root，之后一律通过 `PanelUIState` 的 `@Published` 属性驱动 SwiftUI 刷新。新增面板状态时加到 `PanelUIState`，不要绕过它直接操作视图。
- **紧凑区宽度动态、不固定槽位（文档 §5.2）**：`compactSlots` 数组长度即当前紧凑图标数（元素无 `null` 占位；移除即删元素闭合空隙，旧版固定 3 槽文件加载时经 `normalizedCompactSlots` 剥除空槽）。带宽 = `CompactStripLayout(slotCount:)`：图标按添加顺序**左右均衡交替**排布（偶数索引在左、奇数在右，均从靠刘海一侧排起），两面板等宽（按较大一侧实际槽数）保证黑色带绕刘海左右对称、刘海中心恒为带宽中心。视图侧必须从 `PanelUIState.compactCount` 取数量（`layout.compactStrip(slotCount: ui.compactCount)`），不得硬编码槽位数——宿主视图只在创建时设置一次 root，`layout` 是被捕获的旧值。**几何状态同步集中在 `refreshCompactGeometry()`**：把引擎计数推到各 pair 镜像（`pair.compactCount`/`pair.compactStrip`）与 `uiState.compactCount`，并按新带宽重摆热区窗口；任何增删紧凑图标（`onAddBlock`/`onRemoveBlock`）与换屏（`syncScreens` 后）的路径必须先调它、再调 `rebuildContent`（后者保持纯内容重建、无窗口副作用）。引擎计数只能经 `compactIconCount` / `compactStrip(for:)` 访问，不要在各消费点直接读 `layoutEngine.compactSlots.count`。增删紧凑块没有“槽满”概念（紧凑块从设置组件页拖入，不设数量上限）。
- **抽屉动画是单一尺寸真源（参考 codex-island 的 model.size 模式）**：`PanelUIState.drawerWindowSize` 是可见面板尺寸的唯一 @Published 真源（收起 = 紧凑带尺寸），一切尺寸变化（展开/收起/编辑增高/增删块/缩放预览）必须在 `withAnimation` 里改变它；容器视图 frame 直接绑定它做 spring 变形。抽屉窗口固定满高、永不参与动画；穿透命中 = hitTest 限定可见矩形 + `window.ignoresMouseEvents` 光标跟踪双机制（缺一不可，仅 hitTest 窗口仍会抢焦点）。不要恢复 revealProgress 遮罩插值或任何“窗口跟随内容”的桥（NSAnimationContext/preference/解析 spring 均已试错，均有时钟偏差）。
- **动画容器必须顶缘钉死、收起不得无动画贴起点**：`DrawerPanelView` 绑定 `drawerWindowSize` 的容器 frame 必须 `alignment: .top`——收起过渡中抽屉内容退出布局（快照仍挂在树里淡出），VStack 与仍在收缩的容器高度不一致，默认 `.center` 会把只剩紧凑带的 VStack 顶出容器，图标随之下坠（展开方向靠 ScrollView 伸缩掩盖了同一问题）。`setDrawerRevealed` 里“无动画贴起点”只属于展开分支（贴紧凑带再 spring 长出）；收起的起点就是当前尺寸，若也无动画写成目标，收起会瞬跳且 easeOut(0.16) 动画丢失。
- **块尺寸用 GridSpan 表达**：`BlockSize` 只是预设，真实约束是块的 `supportedSpans`（由 `supportedSizes` 派生 + `supportedGridSpans` 自由跨度）。编辑模式缩放走 `LayoutEngine.resizeBlock` 的任意跨度路径；新增尺寸能力时扩展 `supportedGridSpans` 而不是堆预设。
- **抽屉窗口单例不变量：任一时刻至多一个屏的抽屉在屏**：`collapse()` 的完成回调存在 0.43s 窗口（0.25s 延迟 + 0.18s 等收起动画），期间鼠标移到另一块屏触发跨屏展开会以“已重新展开”为由跳过旧屏的 `orderOut`，旧屏抽屉窗口永久残留——它与活动屏共享同一份 `uiState`，每次展开都渲染出一份一模一样的活抽屉（用户报告“新建笔记多出一块面板”的根因）。因此 `expand()`（含已展开分支）必须清扫 `hideOtherDrawers(keeping:)`，收起完成回调只保留“当前展开屏”而不是整体跳过，`syncScreens()` 移除 stale pair（NSScreen 身份在显示重配后更换，同一物理屏也会命中）时必须显式 orderOut 其两个窗口。不要把完成回调改回“捕获 pair + isExpanded 短路”。
- **插件块内不得让隐藏窗口复活（共享状态 × 每屏一份视图树）**：宿主把同一份 block view 塞进每块屏的抽屉树，插件里按 placementID 共享的交互状态（如 NotesPlugin 的 `EditorInteractionState`）会被**所有屏的实例并发 bind**，谁最后落地谁占有 `textView`/`containerView` 引用——隐藏屏实例赢得竞态后，任何 `makeKeyAndOrderFront`（焦点、激活）都会把已收起的抽屉窗口重新拉上屏，表现为“新建笔记时另一块屏多出一块一模一样的面板”。约束：绑定入口必须拒绝“隐藏窗口候选覆盖可见现任”（可见候选永远放行）；任何聚焦/激活调用前必须 `window.isVisible` 防护。
- **缩放握把的量化必须带死区、平移量必须在稳定坐标系度量**：`ResizeHysteresis.quantized` 只在连续位移越过当前档位半格边界 ± band 之外才换档；`DrawerBlockContainer.resizeGesture` 必须用 `coordinateSpace: .global`。不要改回朴素 `round()`、整数距离迟滞（无实际死区，边界抖动闪烁），也不要改回默认 `.local`——握把随预览增长平移一格时 local 平移量瞬间反跳一整格，死区吸收不了，形成逐像素自激振荡。
- **拖拽推挤算法不能改回“同步 +1 行”**：`pushDownOrigins`（`previewArrangement` 的核心，缩放推挤复用同一实现）的逐块安放语义是历史 bug 的修复——旧实现让所有重叠块同步下移，相对位置不变、永不分离，靠次数上限退出并把残留重叠写盘，导致粘连块对与失控行号。改动推挤逻辑前先读 `DragReorderReproTests`；`LayoutEngine` 加载时会自动净化含重叠的损坏 layout.json，勿删除该路径。
- **编辑模式契约：不留空行 + 缩放推挤 + 面板贴合**：所有变更（移动/移除/缩放/提交）后 `compactEmptyRows` 会闭合整行空洞（下方整体上移；行内部分留白保留，加载净化的留白保护不受影响）；`resizeDrawerBlock` 扩大遇下方块不再回退而是推挤下移，预览与提交走同一算法（所见即所得）；窗口高度经 `previewBottomRow`/`refreshAfterEdit` 随内容行数按需增减。回归见 `LayoutEngineTests` 的“编辑模式契约”一节。
- **列双向扩大、行仅向下（originColumn 可为负）**：行始终顶边锚定只向下扩大（originRow 不变、非负）；列支持左右双向——块被拖出左侧时格网向左扩大（originColumn 变负，`validColumnRange` 保证合并后跨度 ≤ 容量），单右下握把只向右下扩大（无左右双握把）。渲染横坐标 = `(originColumn − gridLeft) × 步长`、宽高按占列跨度（`occupiedColumnRange`），面板绕刘海居中所以列扩大视觉上左右对称。预览期 `applyPreviewWindowSize` 必须把 `drawerWindowSize`/`drawerContentSize`/`drawerGridLeftColumn` 放进**同一次 withAnimation（与块推挤同帧，不等松手）**；`compactEmptyColumns` 会闭合负列空洞（左侧块向 0 右移，与右移对称）。回归见 `LayoutEngineTests` 的“编辑模式契约：列双向扩大（左扩）”一节与 `DragReorderReproTests` 的列跨度不变量。
- **最小行数 / 最小列数只夹尺寸、不动块原点**：`layout.json` 的 `minRows`（可选项 1–9，默认 1）与 `minColumns`（3–8，默认 3）是网格行列下限，块不够时面板补空白格到该尺寸；**默认值同时是旧文件缺键的回落值**，所以升级后抽屉至少 3 列宽（自定义 `init(from:)` 不跑成员式 init 的夹紧——新字段必须在解码处各自夹，且 `CodingKeys` 漏加会被合成编码器静默丢弃）。生效下限的唯一出口是 `LayoutEngine.minimumRowCount()` / `minimumColumnCount()`：后者再夹一次有效容量——最大列数只有 2 或窄屏时最小列数退化为“面板恒为满宽”，但绝不宽出 `drawerFrame` 的定宽窗口而被裁；列下限**不回改存量值**（`setUserMinColumns` 在最大列数小于可选项下界时忽略写入，把最大列数调回去时原设置仍然生效）。两条同源铁律：网格容器高度（`DrawerGridGeometry.bottomRow`/`contentHeight`）与窗口高度（`DrawerLayoutMetricsResolver`）必须按**同一份** `minimumRows` 夹紧，且 `uiState.drawerGridMinRows`/`drawerGridMinColumns` 必须与 `drawerContentSize` 在**同一次** `rebuildContent` 里写——漏任何一处就是落在留白格里的块与占位框被 ScrollView 裁掉。`compactEmptyRows`/`compactEmptyColumns`、推挤、落点夹紧与校验一律看不到这个下限。回归见 `LayoutEngineTests` 的“配置项：最小行数 / 最小列数”一节与 `MinimumGridSizePersistenceTests`。
- **抽屉多页面：显示序列可排序、索引恒为身份、算法页内隔离**：页面持久化为 `LayoutModel.drawerPages`（**保序**去重、必含主页 0；数组顺序 = 顶栏胶囊从左到右的次序，空页面也必须持久化）。`normalizedPages` **绝不排序**——排一次序就把用户的拖动排序抹掉了。**索引是身份不是位置**：拖动排序只改数组顺序，块上的 `page`（旧 JSON 缺省视为 0）永不重编号；新页索引只在既有**权值**外侧生成（左 = `min−1`、右 = `max+1`），乱序下拿 `drawerPages.first/last` 当极值会撞出重复索引、把块挂到错的页上。页面可以**删除**（`removeDrawerPage` 连页内块一起删并返回被删块，调用方逐个补 `placementWasRemoved`；主页恒在不可删）——块与页必须**同一次写盘**里消失，否则加载净化的"收编块引用散页"会把刚删的页复活；非空页删除前须二次确认（块里可能装着用户笔记）。页面可以**改名**：`drawerPageTitles` 按索引的字符串形式为键（Int 键会被合成的 `encode(to:)` 写成数组、与自定义解码不对称），显示名唯一解析点是 `LayoutModel.pageDisplayName`（标题优先、否则序列 1-based 序号），胶囊 tooltip 与确认框共用它。所有网格算法（重叠/推挤/压实/几何/净化/校验）只作用于**同一页内**的块——新增页内操作时必须按页过滤 others；压实按页分组执行且不得改变块在 `drawerBlocks` 数组中的相对顺序（ForEach 稳定性）。激活页是运行时状态（`uiState.drawerActivePage`，不落盘），`rebuildContent` 按它过滤块元素与几何，设置面板拖入 / 快捷添加落位也落在激活页。**滑动切页的相邻页按序列位置取**（`neighborPage` 用 `firstIndex(of:) ± 1`，不比索引大小）。分页控件（`DrawerPageCapsule`）是**每页一颗定宽独立胶囊** + **胶囊行首尾两颗常驻加号**（在胶囊外，封顶 `LayoutModel.maxDrawerPageCount` 后隐形且不吞点击）；胶囊主体**不得是 `Button`**（按钮会在 AppKit 层接管按下，鼠标拖动的中间事件直到松手才回流给祖先手势，真机上表现为整行只在松开那一瞬才动），点击切页与拖动排序共用同一条 `DragGesture(minimumDistance: 0)`、按横向位移越阈分类（与 Kit `blockPopoverTrigger` 同一实测结论），非编辑模式只认点击；落点数学见 `DrawerPagePillLayout`——**被拖胶囊的基座钉在原槽位**（跟手量才是纯 offset），其让位预览 `displayIndex` 必须与引擎 `moveDrawerPage`（remove + insert）逐位同解，且**先提交再清预览**（清预览那两行须显式 `withAnimation(DrawerAnimation.spring)`，与 `rebuildContent(animated:)` 的换序同曲线），否则松手一次回弹；**胶囊行自身（`DrawerPageCapsule.body`）不得挂任何 `.animation(value:)`**——`targetIndex` 每越过半格边界变一次，行级隐式动画就把同一帧里被拖胶囊的跟手位移一起 spring 化，真机上胶囊落后于光标（与滑动切页"跟手不加动画"同源），让位动画只挂在各胶囊自己的 `shift` 上；胶囊**命中框比胶囊高一档**（`rowHeight`），编辑模式的重命名/删除角标必须落在框内——探出框外时指针一移到角标上 `onHover` 就翻回 false，角标当场消失、永远点不到。回归见 `DrawerPageTests`（含对着真引擎穷举的"预览 == 提交"）与 `DrawerPagePillLayoutTests`。
- **抽屉左右滑动切页：两条输入、一份判据、跟手滑入**：判据全在 `DrawerPageSwipe`（方向门槛 / 横纵压比 / 跟手位移与橡皮筋 / 落位阈值与速度 / 冷却），触控板轻扫与背景拖拽共用——不要在视图里各写一份，手感会漂移且无法重放。**判定与会话住在控制器**（`handleDrawerScroll` + `beginDrawerSwipe`/`updateDrawerSwipe`/`endDrawerSwipe`），`NotchPanel` 只经 `onScrollEvent` 转发滚轮事件（与既有 `onMouseEvent` 同族）——窗口不知道页宽、块矩形和切页守卫。触控板通路三条铁律：**必须过滤 `momentumPhase`**（一次猛扫的惯性尾巴足以再翻一页；写 `momentumPhase.isEmpty`，**不能写 `== .none`**——`NSEvent.MomentumPhase` 没有 `none` 成员，`.none` 会被解析成 `Optional.none` 并隐式提升比较，恒为 false，真机上表现为轻扫全部失效）、**必须不消费事件**（块浮窗、笔记编辑器、文件架都靠派发下去）、**光标落在块上的让路判据是插件声明**（格 → 屏幕走 `drawerElement(at:)` + `drawerScreenMapper`）：只有 `BlockScrollUsage = .horizontal`（块内真有横向可滚动区，如文件架）的块才让路，`.none`/静态卡片上滑动照常切页（"在不使用滑动的组件上滑动时触发页面滑动"）；未声明的第三方块默认 `.horizontal` 兼容旧行为。宿主无法内省 SwiftUI 视图树——曾经用"沿 superview 找文档视图宽于视口的 `NSScrollView`"判定，**真机实测 SwiftUI 的 ScrollView 在命中链上根本拿不到 `NSScrollView`，那条件永不成立**，勿改回探针方案。官方块声明：Notes 笔记本 / Pomodoro / Dsh / Calibre / OpenCode 用量为 `.none`，Scratchpad 文件架为 `.horizontal`。滑动是**跟手**的：`pageSlide` 里两层构成一条**刚性相邻的页带**（预览层横坐标 = `offset + gap`，`gap` 在 `beginDrawerSwipe` 按两侧页宽一次算出并冻结——**不得在视图里现算 `ui.drawerContentSize.width`**，落位动画途中当前页尺寸会换，现算就让两层错开一条缝），跟手期只改 `uiState.drawerSwipe.offset`，**面板尺寸随同一份进度插值**（`updateDrawerSwipe` 把 `drawerWindowSize`/`drawerContentSize` 在会话起止两端间线性插值：滑动推进 → 面板同步向目标页所需大小长/缩，往回滑 → 进度归零、尺寸恢复，进度 = `|offset| / |gap|`，见 `DrawerPageSwipe.progress`/`interpolatedSize`）。插值的两端（`startWindowSize`/`startContentSize`/目标两尺寸）与位移上限（`limit`）**全在会话里冻结**——`drawerContentSize` 在插值，位移换算/橡皮筋若现读它就逐帧漂移（`handleDrawerScroll`/`drawerSwipeDrag` 一律取 `session.limit`）；`DrawerPanelView.grid` 的网格层宽度也必须冻结为 `startContentSize.width`——容器随插值收窄时网格层 bounds 跟着收窄，其右裁缘会与预览层左缘（按当前页宽起排）错开一条缝。同一份 `progress` 也是胶囊高光层的进度源：`DrawerPageCapsule` 在激活/目标两颗胶囊间线性插值**悬浮高光组件**（独立 `PagePillHighlight`，`DrawerPagePillLayout.highlightX` 定左缘），会话期激活胶囊的静态高亮让位（`isActive` 传 `false` 即可，**基础底衬保留**——0.055 填充/0.06 描边照常渲染，滑动时胶囊行不消失；曾用 `suppressesCapsule` 把全部胶囊压到 0 不透明度，真机表现为"滑动时胶囊边框全消失"，已删）——高光必须是**悬浮组件**观感：填充/描边 0.24（显著实于 0.055 底衬，盖住底下底衬、吞掉胶囊/间隙交界处的明暗变化）+ 投影阴影（`highlightShadow*` 常量，把高光从底衬平面抬起；不做这两点就是"同平面第二颗胶囊"，叠加/断裂的衔接问题复现）——胶囊内**内容亮度**（图标/文本）同一来源同步插值：`contentActivation` = 激活槽 (1 − p) 渐暗、目标页 p 渐亮、其余 0（`activationWeight`，与高光互补呼应）。高光必须用 `.offset` 定位、**不能用 `.position`**（`.position` 布局尺寸恒等于父容器提案，会把胶囊行 ZStack 撑满整行、行对齐把胶囊钉到容器左边，真机报告过）；落位 spring 期间高光随 offset 同曲线收敛，`rebuildContent` 清会话后静态激活样式恰好落在新激活胶囊上、无跳变。落位门槛取 `min(页宽 × 0.28, 90pt)` + **速度判据**（`shouldCommit` 的 `velocity:`/`predictedOffset:` 两条通路：触控板经 `DrawerPageScrollTracker` 的样本窗口（0.12s）估即时速度、拖拽经 `DragGesture.predictedEndTranslation` 折成预测位移——≥ `commitVelocity`(800pt/s) 且与位移同向即落位，慢推/往回甩不触发），越界按 0.35 阻尼橡皮筋，提交只在松手/抬指（`onEnded` / `.ended` → `finish`），一次手势至多一页。**提交分两拍，顺序不可合并**：第一拍 spring 把位移推到 `arrivalOffset = −gap`（预览层正好落到 x=0 全覆盖），**同一拍内把两个尺寸写进同一条 spring 的目标值**——线性弹簧对两个终点的中间帧是同一仿射解，"尺寸进度 ≡ 位移进度"延续到落位动画全程；第二拍 `landDrawerSwipe` 在**同一帧、无动画**地换页（网格换成目标页真实例 + 位移归零——这一帧两层像素完全重合、尺寸已到目标、整帧保持非动画帧，交接全靠这一点藏住），随后 `rebuildContent(animated: true)` 写入与当前相同的尺寸（无可见动画）。绝不允许在松手那一帧撤层 + `selectDrawerPage`：那会把撤层、位移归零与换页挤进同一条 spring，真机表现为目标页原地淡出、新页内容再从反方向滑一遍。配套两条禁令：`grid` 上跟随 `drawerElements` 身份/位置的两条 `.animation(value:)` **在会话挂载期必须为 nil**（否则退场页在 x=0 上重影淡出）；`isLanding` 期间新手势整个忽略，且 `beginDrawerSwipe` 的早退**不得**走"清掉会话层"那条分支（会把滑到一半的层凭空抹掉）。页带几何的成立条件：网格层宽度冻结在会话起点值 + 预览层宽度 = 目标页宽 + 容器宽度随插值——两侧宽度差不会撕开条缝，滑入全程无裸露边缘（旧版"末帧露当前页边缘、靠落位后尺寸 spring 收场"的代价已随插值消失）。**预览层必须走 `isPreview` 契约**：`buildDrawerElements(page:isPreview:true)` 造的是只读副本，插件的共享交互状态绑定与生命周期副作用必须为它短路（NotesPlugin 已在 `EditorFocusBinder.bind`、`onAppear` 的选区恢复/聚焦、`onDisappear` 的 `unregisterPlacement` 上挡掉）——`bind` 是 `makeNSView`/`updateNSView` 无条件触发的，而 `textView`/`containerView` 是 weak，预览层落地后整层消失会把在屏实例的引用顶成悬空（与"多屏同实例"同一族事故，参见隐藏窗口复活那条）。拖拽层仍只挂在 `grid` 的 `.background` **兄弟层**（`highPriorityGesture` 只为压过外层 ScrollView 对鼠标拖动的接管，与 `SettingsPages` 同一结论）：**不得改挂到 `content` 或任何祖先上**（块靠 `DrawerBlockContainer` 无条件的 `contentShape(Rectangle())` 认领自己的矩形，背景层因此只收得到真空隙上的按下）。滑动**不自动建页**、越界无动作（`LayoutModel.neighborPage`，按显示序列取相邻）；编辑模式禁用（块拖拽/缩放预览按激活页计算，中途切页会把预览提交到错的页），可切性守卫集中在 `NotchPanelContent.canSwitchDrawerPage`/`canSwipeDrawerPage`，胶囊与两条滑动通路共用。回归见 `DrawerPageSwipeTests`（含速度判定、进度/尺寸插值与预测终点落位）与 `DrawerPagePillLayoutTests`（高亮层平移）。
- **Chicken-and-egg 初始化**：`NotchPanelController.init` 在 `super.init()` 之后才构建 `pluginManager` / `layoutEngine`（属性是 `private(set) var ...!`）。改动核心初始化顺序时注意。
- **UI 风格**：抽屉强制深色（`.environment(\.colorScheme, .dark)`），背景接近纯黑半透明，顶部圆角遮罩（`TopAttachedRoundedShape`）。改动视觉时保持“贴近刘海”的观感。抽屉块的卡片壳一律用 Kit 的 `BlockCard`（底色/发丝描边/可选悬停），长按浮窗触发一律用 `.blockPopoverTrigger`——不要在插件里自绘背景描边或手写 frame 追踪与长按手势。
- **标准编辑快捷键依赖隐藏主菜单**：accessory 应用没有可见菜单栏，程序化启动也没有带 Edit 菜单的默认主菜单，⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 属于菜单键等价物——分发路径是 `keyWindow.performKeyEquivalent` → `NSApp.mainMenu` → nil-target 动作沿响应链落到 NSTextView。`EditMenuInstaller.install()` 在启动时安装这份不可见菜单（应用菜单保留 ⌘Q/⌘H），不要删除或改成给某个具体视图固定 target；否则笔记编辑器等文本输入的复制/粘贴快捷键整体失效（普通输入不受影响，回归见 `EditMenuInstallerTests`）。
- **触发器手势不要改回 TapGesture + simultaneous 长按**：`blockPopoverTrigger` 内部由单个 `DragGesture(minimumDistance: 0, .global)` + `.task(id: pressStartDate)` 定时器驱动（分类阈值见 `BlockTapClassifier`）。旧实现是 `.onTapGesture { guard !isPressing … }` 配 simultaneous `LongPressGesture`——真机上点击回调不触发，「点击开网页」（DSH/Calibre）整体失效；HID 合成点击对照实验确认裸 `TapGesture` 与该组合均不回调，而 DragGesture 管线可靠。长按后的松手必须被抑制（`longPressFired`），否则松手瞬间误触 onTap。
- **命名 / 语言**：源码标识符与 UI 字符串用英文；注释可用中文。保持与现有文件一致的风格（缩进、分组、注释密度）。
- **多语言（en / zh-Hans）**：所有面向用户的字符串一律走本地化表，不许硬编码。机制是 Apple 原生 `.lproj` + `Localizable.strings`，每个模块自带翻译：宿主用 `L()`/`LF()`（`Sources/NotchCenter/Localization.swift`，资源经 SPM 打进 `NotchCenter_NotchCenter.bundle`）；插件用各自 Sources 里的 `L()`/`LF()`（基于 Kit 的 `L10n.string` + `Bundle(for:)`）；插件的显示名/描述双语写在各 `Plugin.plist` 的 `DisplayNameLocales` / `DescriptionLocales` 字典（build.sh 生成 InfoPlist.strings）。en 是基准键集，zh-Hans 必须保持键集合一致（`LocalizationTests` 强制校验）。语言跟随系统，设置面板可覆盖（写 AppleLanguages，重启生效）。品牌名（DSH、Calibre、OpenCode、Zen）不翻译。注意 `L10n.string` 故意没有 CVarArg 变参重载：带参数的格式化必须在调用方自己模块内完成（`String(format:arguments:)`），变参跨动态库镜像转发会偶发段错误。
- **每实例状态是 Kit 基本能力，不要在插件里自造**：同一块类型的多个放置实例需要单独设置/状态时，一律走三件套——`BlockContext.placementStore`（派生自 `StateStore.placementScope(placementID:)`，落在 `<pluginData>/placements/<placementID>/`，非法 placementID 返回 nil）；`NotchBlock.instanceSettingsView`（编辑模式块齿轮触发，宿主优先于插件级 `settingsView`，context 携带 placementID / placementStore / 插件级 settingsContext）；`NotchCenterPluginServices.placementWasRemoved(blockID:placementID:)`（抽屉/紧凑两条删除路径回调，插件借此清理该实例持久化数据）。共享数据（如 OpenCodeUsage 的抓取缓存）仍放插件级 store，不要按实例复制轮询；多屏同实例的视图副本必须观察同一个 ObservableObject（按 placementID 注册表缓存）。参考实现：OpenCodeUsagePlugin（显示样式 + 峰谷倒计时开关按实例设置）。注意：这两个服务钩子必须保持为协议**要求**（extension 只提供默认实现），否则宿主经存在类型调用时遵守类的重写会被静态分发遮蔽、永不执行（pluginWasDisabled 曾因此整体失效，回归见 `PluginServicesHookTests`）。
- **活动岛是固定窗口 + 内容内动画 + 双机制穿透（文档 §4.10）**：插件活动状态（如番茄钟计时中）经 `HostController.showActivityIsland` / `removeActivityIsland(id:)` 提交/收回 `ActivityIslandContent`（id 覆盖更新，宿主按提交顺序在刘海下方堆叠）。岛窗口**固定尺寸、只 orderIn/orderOut**，全部进出/紧凑-展开动画发生在窗口内容内（窗口 frame 参与动画 = 裁剪 spring 变形，与抽屉同一教训）；可见尺寸由 SwiftUI 侧经 `uiState.islandVisibleSize` 逐帧回写，`IslandHostingView.hitTest`（顶缘起 + 水平居中矩形）与 `updateIslandMouseEvents` 的 `ignoresMouseEvents` 光标跟踪缺一不可。抽屉展开期间岛内容清空让位（可见尺寸归零 → 全穿透），收起自动恢复；`removeActivityIsland` 清空后延迟 0.32s 才 orderOut（等退出动画）。`IslandPanel` 永不成为 key/main 窗口（点击岛不抢焦点）。showActivityIsland/removeActivityIsland 必须保持为 HostController **协议要求**（extension 只给默认实现），否则经存在类型分发会被静态遮蔽（同 settingsView 家族坑）。回归见 `IslandHitTestingTests`。
- **不要引入新的 SPM 远程依赖**，除非任务要求；优先复用 AppKit / SwiftUI / vendored 引擎。

## 测试

- 运行：`swift test`；单文件调试可 `swift test --filter <Name>`。
- 覆盖：`APIVersionTests`、`StateStoreTests`（含 placementScope 实例作用域隔离）、`LayoutEngineTests`、`PluginManagerTests`（用纯 Info.plist fixture bundle，不加载真实代码）、`NotchGeometryTests`、`NoteStoreTests`、`FileShelfStoreTests`、`SystemSleepGuardTests`、`FileDragPasteboardTests`、`FileDropPasteboardReaderTests`、`FileDropPayloadTests`、`FileShelfSelectionTests`、`TransparentHitHostingViewTests`、`DragReorderReproTests`（随机拖拽不变量重放 / 粘连对回归 / 损坏布局自愈 / 留白保护）、`DragUnificationTests`（占位框落点 == 提交落点 / 预览 == 提交逐块严格相等）、`ResizeHysteresisTests`（缩放量化死区 / 边界抖动不翻转 / 跨档跳转 / 按下不缩小）、`DrawerGestureMathTests`（拖拽位移→格 / 缩放位移→候选跨度 / 补偿偏移）、`DrawerGridGeometryTests`（坐标互逆往返 / 容量夹紧 / 分数步长容差 / 容器高度按最小行数兜底）、`DrawerDropPolicyTests`（落点区域判定）、`DrawerLayoutMetricsTests`（尺寸指标 / 左列约束 / 屏幕封顶 / 最小行列夹紧同源）、`MinimumGridSizePersistenceTests`（最小行列写盘与解码夹紧、旧 JSON 缺键回落）、`DrawerInteractionStateTests`（阶段迁移 / 松手顺序 / 真引擎 200 步随机拖拽预览==提交）、`DrawerPageTests`（抽屉多页面：显示序列增长/封顶/持久化 / 拖动排序（含对着真引擎穷举的"预览 == 提交"）/ 页面改名与默认名回落 / 删页连块清理与不复活 / 页内算法隔离（放置/推挤/压实/重排/校验/净化）/ 旧版 layout.json 兼容解码）、`DrawerPageSwipeTests`（滑动切页判据：方向门槛与横纵压比 / 跟手位移与越界橡皮筋 / 落位阈值取比例与绝对距离中较严者 / 速度判据：够猛且同向才落位、慢推与回甩不触发、速度窗口只取近段样本 / 进度与尺寸插值：`progress` 与 `interpolatedSize` 两端与线性性 / 页带几何：gap 按两侧页宽相邻、落位终点使预览层正好落到 x=0 且必然越过门槛 / 一次手势只翻一页 / 冷却后重放行 / 方向反转重算 / 无手势边界设备越线即提交 / 相邻页按序列位置解析）、`DrawerPagePillLayoutTests`（胶囊行定宽落点：位移→槽位 / 半格抖动不换槽 / 两端夹紧 / 让位预览双向平移且逐对穷举为双射 / 高亮层随进度在槽位间线性平移并夹紧）、`DrawerStayConditionsTests`（收起守卫逐字段）、`DshPluginTests` / `CalibrePluginTests`（服务配置与 plist 模板，不触碰真实 LaunchAgent）、`OpenCodeUsageTests`（cookie 归一化 / SSR HTML 解析 / 时长短语；另有 `OpenCodeUsageAppearanceTests`：每实例外观默认值 / 容错解码 / placementStore 持久化与实例隔离，均不发真实网络请求）、`PluginServicesHookTests`（服务钩子经存在类型分发到遵守类重写的回归）、`LaunchdControlKitTests`（命令字符串构造与 plist 读写生成，不真跑 launchctl）、`EditMenuInstallerTests`（隐藏主菜单接线：标准编辑快捷键的 nil-target 条目与键等价物）、`ReadmeMarkdownTests`（插件管理窗口插件文档：Markdown 块级解析 / bundle 内 README 读取与缺失兜底）、`BlockCardTriggerTests`（浮窗触发器手势分类阈值）、`BlockPopoverTests`（浮窗几何：同心叠加窗口定位 + 屏幕可见区钳制）、`DrawerHitTestingTests`（抽屉窗口穿透 hitTest）、`IslandHitTestingTests`（活动岛窗口穿透 hitTest）、`PeakClockLogicTests`（OpenCodeUsage 峰谷倒计时逻辑）、`PomodoroEngineTests`（番茄钟状态机：阶段转移 / 随机提醒微休息 / 专注剩余冻结恢复 / 暂停跳过 / 倒计时格式）、`PomodoroConfigLogicTests`（设置净化：越界钳制 / min ≤ max / 未知音效回退）。
- 涉及 `pmset` / 休眠的逻辑测试应确保**不真正改变系统睡眠状态**。
- 涉及 AppKit 窗口/事件的逻辑依赖 App 运行环境，注意保持 `@MainActor` 测试隔离（`setUp`/`tearDown` 是非隔离上下文，不要在里面改 @MainActor 属性）。

## 上手建议

1. 先读 `docs/NotchCenter 架构设计文档.md`，再读 `NotchCenterKit`（协议与类型）→ `Sources/NotchCenter/PluginManager.swift` → `LayoutEngine.swift` → `NotchPanelController.swift` 理解插件生命周期与面板协调。
2. 插件开发：先读 [`docs/插件开发指南.md`](docs/插件开发指南.md)（入口协议、Plugin.plist 登记、构建验证），再参照 `Plugins/NotesPlugin/Sources/NotesPlugin.swift` 的入口模式（`static var blocks` + `attachServices`）。
3. launchd 服务控制类插件（DshPlugin / CalibrePlugin 模式）：按 [`docs/服务控制类插件开发指南.md`](docs/服务控制类插件开发指南.md) 的分层、五件套与 workerPattern 选取规则复制扩展——launchd 探测/控制/plist 逻辑一律复用 `LaunchdControlKit`，不要在插件里另写 launchd 或 plist 处理代码。
4. UI 改动从 `CompactPanelView.swift` / `DrawerPanelView.swift`（紧凑区/抽屉/编辑模式）入手。