# NotchCenter 架构设计文档

> 版本：0.1  
> 日期：2026-08-21  
> 状态：已确认核心决策，待实施

---

## 1. 背景与目标

NotchCenter 是由 NotchNotes 改造而来的原生 macOS 应用，定位为**刘海交互插件宿主**。核心只负责刘海区域交互、窗口管理、插件加载/生命周期、布局引擎与状态管理等基础设施；所有具体功能（笔记、暂存、防休眠等）均以插件形式提供。

设计目标：

- 支持动态加载第三方插件，提供类似 macOS 桌面小组件的自定义布局体验。
- 将现有 NotchNotes 功能（笔记 / 暂存 / 防休眠）拆分为官方插件，与第三方插件同等地位。
- 保持原生 macOS 14+、Swift 6 严格并发、纯 Swift Package Manager 管理。
- 支持所有显示器，无刘海屏幕使用顶部中央回退。

---

## 2. 总体架构

### 2.1 核心职责

NotchCenter 核心（主 App）只承担以下基础设施：

- 刘海区域检测与窗口定位（`NotchGeometry`）
- 紧凑面板（`hotPanel`）与抽屉面板（`drawerPanel`）管理
- 插件发现、加载、启用/禁用、生命周期管理
- 插件块布局引擎（紧凑槽位 + 抽屉网格）
- 插件状态存储（`StateStore`）
- 状态栏菜单与插件管理窗口
- 全局鼠标事件与展开/收起交互
- 布局配置持久化与多显示器窗口重定位

核心**不**包含任何业务功能。笔记、暂存、防休眠均作为独立插件实现。

### 2.2 工程结构

```text
NotchCenter/
├── Package.swift
├── Sources/
│   ├── NotchCenter/               # 主 App 可执行 target
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── NotchPanelController.swift
│   │   ├── NotchGeometry.swift
│   │   ├── PluginManager.swift
│   │   ├── LayoutEngine.swift
│   │   ├── StateStore.swift
│   │   └── ...
│   └── NotchCenterKit/            # 共享 API framework（动态库）
│       ├── NotchCenterPlugin.swift
│       ├── NotchBlock.swift
│       ├── BlockContext.swift
│       ├── ActivitySummary.swift
│       ├── BlockSize.swift
│       ├── PluginSettingsContext.swift
│       └── ...
├── Plugins/                       # 官方插件源码，作为独立 bundle target
│   ├── NotesPlugin/
│   ├── ScratchpadPlugin/
│   ├── CaffeinatePlugin/
│   ├── PomodoroPlugin/
│   ├── MediaControlsPlugin/
│   └── ...
├── Vendor/                        # 可能保留 vendored 依赖（如 MarkdownEngine 供笔记插件使用）
├── Resources/
├── Tests/
└── scripts/
```

主 App target 依赖 `NotchCenterKit`，插件 target 也依赖 `NotchCenterKit`。构建时 `NotchCenterKit` 作为动态 framework 嵌入 App 的 `Frameworks/` 目录，插件 bundle 链接该 framework。

### 2.3 插件目录约定

采用双目录：

- 内置官方插件：`NotchCenter.app/Contents/PlugIns/`
- 用户第三方插件：`~/Library/Application Support/NotchCenter/PlugIns/`

宿主启动时同时扫描两个目录，所有插件（包括官方）统一走动态 bundle 加载路径。

---

## 3. 插件打包与加载

### 3.1 打包格式

- 每个插件编译为独立 `.bundle`。
- 插件通过 `Info.plist` 声明元数据，使用 `NSPrincipalClass` 指定插件主类。
- 插件主类继承 `NSObject` 并实现 `NotchCenterPlugin` 协议。

### 3.2 `Info.plist` 必需键

| 键 | 类型 | 说明 |
|---|---|---|
| `NSPrincipalClass` | String | 插件主类名 |
| `NotchCenterPluginID` | String | 插件唯一标识（反向域名） |
| `NotchCenterPluginVersion` | String | 插件自身版本 |
| `NotchCenterPluginAPIVersion` | String | 兼容的 API 版本范围（语义化） |
| `NotchCenterPluginDisplayName` | String | 用户可见名称 |
| `NotchCenterPluginDescription` | String | 可选描述 |

### 3.3 加载流程

1. 宿主扫描内置和用户插件目录中的 `.bundle`。
2. 读取每个 bundle 的 `Info.plist`，校验元数据完整性。
3. 检查 `NotchCenterPluginAPIVersion` 是否与当前核心 API 版本兼容（语义化范围校验，见 9.1）。
4. 仅对**已启用**的插件调用 `Bundle.load()` 并通过 `principalClass` 获取插件类。
5. 校验类是否符合 `NotchCenterPlugin` 协议，通过 `init()` 创建插件实例并持有。
6. 未启用插件不加载代码，仅显示元数据用于管理界面。

### 3.4 启用/禁用语义

- 未启用插件完全不加载代码，仅读取元数据。
- 启用时动态加载并实例化。
- 禁用时释放插件实例，但保持 bundle 加载（不卸载）。
- 启用/禁用即时生效，无需重启应用。
- 禁用插件后，其已放置在布局中的块**保留记录但隐藏**；重新启用后自动恢复原位。

---

## 4. 插件 API 规范

### 4.1 核心协议

所有插件 API 均标注 `@MainActor`，在 Swift 6 严格并发下保证主线程安全。

```swift
@MainActor
public protocol NotchCenterPlugin: AnyObject {
    static var blocks: [NotchBlock] { get }
    init()
}
```

插件身份信息来自 `Info.plist`，协议不再重复要求 `pluginID` 等属性。

### 4.2 块模型

```swift
@MainActor
public struct NotchBlock {
    public let id: String                     // 插件内唯一块类型 ID
    public let displayName: String            // 用户可见名称
    public let kind: BlockKind                // .compact 或 .drawer
    public let supportedSizes: Set<BlockSize> // 仅 .drawer 有效
    public let defaultSize: BlockSize?        // 仅 .drawer 有效
    public let interaction: BlockInteraction  // .expandDrawer 或 .custom（仅紧凑块有意义）
    public let makeView: @MainActor (BlockContext) -> AnyView
}
```

**枚举定义：**

```swift
public enum BlockKind { case compact, drawer }

public enum BlockSize { case small, medium, wide, large, extraLarge }

public enum BlockInteraction { case expandDrawer, custom }
```

**校验规则：**

- 紧凑块只能放入紧凑槽位，抽屉块只能放入抽屉网格。
- 抽屉块必须声明 `supportedSizes` 且包含 `defaultSize`。
- 紧凑块固定尺寸 28×28，无需声明尺寸。
- 紧凑块 `interaction` 可选；默认行为是点击展开抽屉。

### 4.3 块多实例

- 同一插件的同一块类型可以多次放置到布局中，形成不同实例。
- 每个放置实例拥有唯一的 `placementID`。
- 插件状态存储按 `(pluginID, blockID, placementID)` 隔离。
- 视图上下文携带 `placementID`，保证视图身份稳定。

### 4.4 视图生命周期

- 核心使用稳定标识 `(pluginID + blockID + placementID)` 为每个已放置块提供稳定的 SwiftUI 视图身份。
- 布局位置变化、抽屉收起/展开时尽量保留视图树。
- 插件可安全使用 `@State` 保存瞬态状态；跨启动持久化通过 `StateStore` 完成。

### 4.5 `BlockContext`

```swift
@MainActor
public struct BlockContext {
    public let pluginID: String
    public let blockID: String
    public let placementID: String
    public let stateStore: StateStore
    public let hostController: HostController
    public let layoutInfo: BlockLayoutInfo
}
```

**`HostController` 提供：**

- `expandDrawer()`
- `collapseDrawer()`
- `enterEditMode()`
- `exitEditMode()`
- `refreshCompactDisplay()`

**`BlockLayoutInfo`**：当前块在布局中的位置、尺寸、所在区域（紧凑/抽屉）等只读信息。

### 4.6 状态存储 `StateStore`

```swift
@MainActor
public final class StateStore {
    public func data(forKey key: String) -> Data?
    public func setData(_ data: Data?, forKey key: String) throws
    public func object<T: Codable>(_ type: T.Type, forKey key: String) -> T?
    public func setObject<T: Codable>(_ object: T, forKey key: String) throws
    public func removeValue(forKey key: String)
}
```

- 核心为每个插件维护隔离存储，文件位于 `~/Library/Application Support/NotchCenter/PluginData/<pluginID>/`。
- 键值对分别持久化，避免单文件过大。
- 核心保证同一插件键空间唯一，不向插件暴露底层文件路径。
- 插件实例的状态读写全部通过此 API，不直接落盘。

### 4.7 插件设置界面

插件可声明：

```swift
@MainActor
public protocol NotchCenterPlugin {
    static var blocks: [NotchBlock] { get }
    var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? { get }
    init()
}
```

`PluginSettingsContext` 包含作用域 `StateStore` 和 `HostController`。`settingsView` 统一经 Kit 的 SettingPopover 浮窗展示（布局编辑模式的齿轮按钮触发）；插件管理窗口详情区展示各插件 bundle 内的 README.md，不再内嵌设置视图。

### 4.8 状态栏菜单贡献

插件可提供最多 3 个菜单项：

```swift
@MainActor
public protocol NotchCenterPlugin {
    static var blocks: [NotchBlock] { get }
    var menuItems: [PluginMenuItem] { get }
    init()
}
```

核心在状态栏菜单中为已启用插件分组显示这些菜单项。

### 4.9 并发模型

- 所有插件 API、视图工厂方法、`StateStore`、`BlockContext` 服务均 `@MainActor`。
- 插件内部后台任务自行处理，但 UI/状态更新必须回主线程。
- 核心所有插件交互（加载、调用、布局渲染）均保证主线程执行。

### 4.10 紧凑带活动摘要（Compact Strip Activity Summary）

插件进入活动状态（计时中、正在播放等）时，经 `HostController` 提交**结构化摘要**，核心在刘海紧凑带内渲染一行「图标 + 文案 + 迷你进度」芯片——**不新建窗口、不遮挡屏幕内容区**（替代旧活动岛机制，决策见 Agent Note `2026-09-03-compact-area-activity-summary`）：

```swift
@MainActor
public struct ActivitySummary: Identifiable, Sendable, Equatable {
    public let id: String          // 活动唯一标识；同 id 重复提交 = 原位覆盖更新（新旧次序不变）
    public let title: String       // 主文案（如「正在播放」/ 曲名）
    public let subtitle: String?   // 副文案（如「12:34 剩余」「Artist — Track」）
    public let symbolName: String? // 引导图标（SF Symbol 名称）
    public let progress: Double?   // 迷你进度 0…1（沿刘海方向）；无进度概念的摘要可不传
}

extension HostController {
    func showActivitySummary(_ summary: ActivitySummary)   // 展示/更新
    func removeActivitySummary(id: String)                 // 收回
}
```

- **展示排布**：宿主按提交顺序维护摘要序列，同一时刻**每侧各一条**——`visiblePair` 最新在左、次新在右；同 id 覆盖更新不改变新旧次序；收回后回退到次新。
- **渲染位置**：芯片在刘海紧凑带内、贴刘海一侧（`CompactStripLayout` 的 `leftSummaryRect`/`rightSummaryRect`）；摘要引起的带宽变化沿镜像同步链路（`syncSummaryWidths` → `syncSummaryGeometryMirrors` → `positionCompactPanel` 非动画重摆），**不走** `refreshCompactGeometry()`/`rebuildContent()` 全量路径；带宽取两侧较大值 `sideSummaryBand`，左右面板配平保持刘海居中对称（无摘要一侧的余量落在面板外端）。
- **让位规则**：抽屉展开期间摘要整体让位，收起自动恢复；芯片纯展示、点击穿透到整条黑色带（点击 = 展开抽屉的统一语义）。
- **宽度与文案**：副文案优先于主文案截断；芯片宽度由 `SummaryChipMetrics.estimatedWidth` 估算（宁宽勿裁，上限约 180pt），视图只渲染 `title` + 可选 `subtitle`。
- **动画纪律**：出现/更新/移除的过渡动画一律发生在既有窗口**内容内**（`.transition` 进出场、进度原位刷新），窗口 frame 永不参与动画。
- **生命周期**：插件进入活动状态提交、退出/禁用时按 id 收回；`showActivitySummary` / `removeActivitySummary(id:)` 必须保持为 `HostController` **协议要求**（extension 只提供默认实现），避免存在类型分发的静态遮蔽（同 §4.7 家族坑）。
- 参考实现：`PomodoroPlugin`（会话运行中提交「阶段 + 剩余秒 + 进度」）、`MediaControlsPlugin`（播放中提交「曲名 + 艺术家 + 播放进度」，暂停置态、停止收回）。

---

### 4.11 快捷动作与快捷按钮盒（Quick Actions & Quick Button Box）

- **快捷按钮 QuickAction（统一一键入口）**：插件自报的**快捷按钮**——既可放进快速区（刘海带）也可收纳进「快捷按钮盒」，宿主以统一标准样式渲染。`NotchCenterPlugin.quickActions` 声明（图标 + 名称 + `toggle`/`action` 类别 + 可选 `requiresConfirmation` + `execute` + 开关态 `isActive`）。官方一键入口不再注册自带视图的紧凑块：动作 id **沿用旧块 id**（`caffeinate.toggle` / `pomodoro.toggle` / `notes.compact` / `scratchpad.compact` / `clipboard.tray`），紧凑槽位「先按插件块解析、缺块回退同名动作」，旧布局零迁移。`QuickAction` 是 `@MainActor` 可观察对象，插件须**缓存同一实例**（identity 稳定，宿主只存引用、不持久化）；可选 `sourceBlockID` 仅保留给第三方「块卡 + 动作」合一用例，`defaultInStrip` 供首启默认布局种子。
- **注册表生命周期**：宿主在插件启用/attach 后收集注册（`PluginManager` → `QuickActionStore`）、禁用/卸载前注销；动作 ID 全局唯一、先到先得。插件经 `HostController.quickActions()` / `quickAction(id:)` 读取（协议**要求** + 默认空实现，同 §4.10 纪律）。来源插件被禁用后：盒内对应按钮置灰保留、快速区槽位解析失败显示为空槽（编辑模式可移除）。
- **统一外观与容器**：Kit `QuickActionTile`（圆角方块 + SF Symbol，开关点亮 / 静态 / 失效置灰三层状态）是唯一外观基元——快速区槽位（`QuickActionStripCell`：点击执行、重动作确认）、快捷按钮盒格、设置目录卡片共用，同一按钮在任何落位长相一致。盒仍是普通抽屉块（官方 `QuickButtonBoxPlugin`，`quickbuttonbox.grid`，.large/.extraLarge），宿主经 `NotchCenterQuickActionSink.acceptQuickAction(_:placementID:span:)` 询问「该放置实例是否接受一次动作落位」——接受方自判容量并把有序动作 ID 持久化到 `placementStore`（键 `quickActions`），宿主零块 ID 硬编码，第三方可自建同类容器。
- **目录与拖拽分流**：组件页每个插件分区内的「快捷按钮」卡统一样式（磁贴 + 名称 + 去向小字）；单击 = 加入快速区末尾，按住拖 = 拖到快速区（插槽）或拖到可收纳容器（盒，装填动作；复用跨窗 `BlockDragCoordinator` 会话 + `.drawer` 落点虚线框套住盒实例）；纯动作卡落抽屉空白格无效（红叉），第三方组件块卡行为不变。盒块齿轮（instanceSettingsView）面板做移除/排序；收纳的是动作的**快捷方式/副本**，原件仍可留在快速区，双入口共享同一动作状态（toggle 点亮态实时同步）。
- 契约与纪律见 [`快捷按钮盒 Agent Note`](agent-notes/implemented/2026-09-05-quick-button-box.md)；注册指引见 [`插件开发指南 §3`](插件开发指南.md)。参考实现：Caffeinate / Notes / Scratchpad / ClipboardHistory / Pomodoro（动作化快捷按钮）+ Calibre / Dsh / MediaControls / OpenCodeUsage（附加动作）。

---

## 5. 布局系统

### 5.1 整体模型

- **紧凑刘海区**：槽位数不固定（0 起），随添加的紧凑图标动态伸缩，位于屏幕刘海下方，始终可见。
- **展开抽屉区**：网格布局，默认两行 4 列，可按用户设置和内容扩展。

### 5.2 紧凑区

- 槽位数**不固定**：数组长度即当前紧凑图标数，添加图标带宽随之增长、移除图标随之收缩（移除即删除元素、闭合空隙），不再固定 3 槽；也不设数量上限。
- 每个槽位固定 28×28 pt。
- 图标按添加顺序**左右均衡交替**排布：偶数索引在左、奇数在右，均从靠刘海一侧排起；两面板等宽（按较大一侧实际槽数），黑色带绕刘海左右对称，刘海中心恒为带宽中心。
- 面板水平居中于刘海下方；空槽位透明且不可交互。
- 紧凑块点击默认展开抽屉；插件可声明自定义点击行为。

### 5.3 抽屉网格

- 单元格固定大小：**150×120 pt**。
- 网格间距：**12 pt**。
- 抽屉内容内边距：**16 pt**。
- 块尺寸等级：
  - `small`：1×1
  - `medium`：2×1
  - `wide`：4×1
  - `large`：2×2
  - `extraLarge`：4×2
- 窗口宽度 = 当前列数 × 单元格宽度 + (列数-1) × 间距 + 2 × 内边距。
- 最大列数可用户配置（默认 4），上限由所有已启用显示器中最小可用宽度决定（见 7.2）。
- 窗口高度随行数增长；达到屏幕可用高度上限后，内容区域滚动。
- 总列数不随内容继续增长，超出最大列数后新增块自动换行。
- 行数不小于 `minRows`、列数不小于 `minColumns`（设置 → 布局）：块不够时以空白格补齐面板尺寸，**不改块原点**（空洞照样压实）。列下限还要被有效容量封顶一次——最大列数或屏幕宽度不足时以容量为准。

### 5.4 布局持久化

- 单一版本化 JSON 文件：`~/Library/Application Support/NotchCenter/layout.json`。
- 内容包含：
  - `schemaVersion`
  - `maxColumns`（用户设置）
  - `minRows` / `minColumns`（用户设置：最小行数 1–9 默认 1、最小列数 3–8 默认 3；默认值同时是旧文件缺该键时的回落值）
  - `compactSlots`：紧凑块引用数组，**长度即当前图标数**（空数组 = 无图标；元素均为块引用，不含 `null` 占位——旧版固定 3 槽文件加载时自动剥除空槽）
  - `drawerBlocks`：`PlacedBlock` 数组
  - `enabledPluginIDs`：已启用插件 ID 列表
`PlacedBlock` 结构：

```json
{
  "pluginID": "com.example.notes",
  "blockID": "notes.drawer",
  "placementID": "uuid",
  "originColumn": 0,
  "originRow": 0,
  "widthColumns": 2,
  "heightRows": 1
}
```
- 保存采用原子写入。
- 核心根据已放置块的最大占用列数/行数计算窗口尺寸，并检测重叠。

### 5.5 布局编辑模式

- 内联编辑：用户展开抽屉后通过按钮进入编辑模式。
- 编辑模式中：
  - 块可拖拽重排（网格内）。
  - 块可调整尺寸（在支持的尺寸等级间切换）。
  - 块可移除。
  - 通过“+ 添加块”打开块目录侧边栏，按插件分组列出可用块类型，点击添加。
  - 紧凑区槽位旁提供“+”添加紧凑块。
- 添加块后自动放置在第一个可用位置。
- 编辑完成保存布局；空槽位或空白区域在非编辑模式隐藏。

---

## 6. 用户交互

### 6.1 抽屉展开/收起

- 鼠标移入刘海区域自动展开抽屉。
- 点击紧凑块或抽屉内的钉住按钮可锁定展开；锁定时鼠标移出不收起。
- 再次点击钉住解除锁定，移出后收起。
- 额外提供全局快捷键/状态栏菜单作为展开/收起入口。

### 6.2 紧凑块点击行为

- 默认行为：展开抽屉。
- 插件可在块元数据中声明 `interaction = .custom`，此时点击不默认展开，由插件处理（例如防休眠开关直接切换状态）。

### 6.3 多显示器行为

- 支持所有显示器。
- 有刘海屏幕使用刘海几何定位。
- 无刘海屏幕使用顶部中央回退定位。
- 所有显示器共享同一份布局（见 7.1）。
- 只有一个全局面板窗口实例，始终显示在鼠标当前所在屏幕；鼠标移动时窗口重新定位。
- 窗口结构保持两个独立 `NSPanel`：`hotPanel`（紧凑）和 `drawerPanel`（展开）。

---

## 7. 多显示器与宽度约束

### 7.1 布局共享

- 所有显示器共享同一份布局，内容完全一致。
- 同一布局在任何屏幕都适配；窗口宽度不超过所有已启用显示器中最小可用宽度。

### 7.2 最大列数计算

- 用户可配置最大列数（默认 4）。
- 全局最大列数上限 = 最小分辨率屏幕可用宽度能容纳的最大列数。
- 实际最大列数 = `min(用户配置值, 屏幕最小可用宽度对应列数)`。
- 窗口宽度 = 实际列数 × 单元格宽度 + 间距/边距，确保不超过最小屏幕宽度。

### 7.3 窗口重定位

- 鼠标所在屏幕变化时，核心重新计算该屏幕的刘海几何或顶部中央回退几何，并更新两个窗口的 frame。
- 窗口层级和交互状态不变。

---

## 8. 插件管理

### 8.1 管理窗口

- 状态栏菜单提供“插件管理…”入口，打开独立管理窗口。
- 管理窗口显示所有已发现插件（内置 + 用户目录）。
- 对每个插件提供：
  - 启用/禁用开关
  - 安装/卸载（仅用户插件）
  - 插件信息（版本、API 兼容性）
  - 打开插件设置（若提供）
- 插件设置 UI 嵌入管理窗口内展示。

### 8.2 安装流程

- 用户通过管理窗口选择 `.bundle` 文件。
- 宿主将 bundle 复制到用户插件目录 `~/Library/Application Support/NotchCenter/PlugIns/`。
- 校验元数据与 API 兼容性后启用。

### 8.3 安全策略

- 第三方插件不要求代码签名或公证（按决策 A）。
- 加载前不校验签名，信任用户。
- 后续可考虑增加警告机制，但当前版本不实现。

---

## 9. 版本兼容与迁移

### 9.1 API 版本校验

- 插件 `Info.plist` 中的 `NotchCenterPluginAPIVersion` 声明兼容范围（例如 `"2.0..<3.0"`）。
- 核心当前 API 版本为 `NotchCenterKit` 中定义的 `currentVersion`。
- 核心检查当前版本是否落在插件声明范围内；不在范围内则拒绝加载并提示用户。
- 采用语义化版本范围，允许小版本兼容。

### 9.2 旧数据迁移

- **暂不迁移**旧 NotchNotes 数据（决策 C）。
- 新应用从零开始；旧数据保留在原目录，用户自行处理。
- 未来可重新评估是否提供迁移工具。

---

## 10. 后续迭代方向（非本次范围）

- 无刘海屏幕顶部中央回退的完善。
- 插件签名警告/公证支持。
- 官方插件实现（笔记、暂存、防休眠）与旧数据迁移。
- 拖拽抖动动画等编辑体验优化。
- 更丰富的插件间通信机制（如有需求）。
- 布局多屏幕独立化（目前全局共享）。

---

## 附录 A：决策记录摘要

| 编号 | 决策项 | 选择 |
|---|---|---|
| 1 | 核心职责边界 | 纯插件宿主，笔记/暂存/防休眠全部插件化 |
| 2 | 插件打包加载机制 | 动态 `.bundle` + `NSPrincipalClass` |
| 3 | 插件 UI 暴露方式 | 多块，核心布局引擎统一放置 |
| 4 | 布局模型 | 混合：紧凑动态槽位（随图标伸缩）+ 抽屉网格 |
| 5 | 插件状态管理 | 常驻实例 + 核心 `StateStore` 统一存储 |
| 6 | 块 API 形式 | SwiftUI `AnyView` 工厂 |
| 7 | 布局编辑交互 | 内联编辑模式 |
| 8 | 网格尺寸模型 | 固定单元格尺寸 + 尺寸等级 |
| 9 | 抽屉扩展行为 | 高度随内容增长，宽度随列数变化，受最小屏幕宽度约束 |
| 10 | 最大列数确定 | 用户可配置，受最小屏幕宽度约束，默认 4 |
| 11 | 单元格数值 | 150×120，间距 12，内边距 16 |
| 12 | 紧凑区槽位 | 动态槽位数（随添加图标伸缩），28×28，左右均衡交替排布，带宽自适应 |
| 13 | 布局持久化 | `PlacedBlock` 数组 + `layout.json` |
| 14 | 插件入口元数据 | `Info.plist` + `NSPrincipalClass` |
| 15 | 工程结构 | 提取 `NotchCenterKit.framework`，动态链接 |
| 16 | 沙盒 | 不启用 |
| 17 | 插件目录 | 双目录（内置 + 用户） |
| 18 | 块上下文 | `BlockContext` 包含状态、宿主服务、布局信息 |
| 19 | 多实例 | 支持，按 `placementID` 隔离 |
| 20 | 插件启用/禁用 | 即时生效，禁用保留布局记录 |
| 21 | 紧凑块点击 | 混合：默认展开，插件可自定义 |
| 22 | 抽屉展开/收起 | 混合：悬停展开 + 钉住锁定 |
| 23 | 并发模型 | 全 `@MainActor` |
| 24 | `StateStore` API | Codable + Data 键值对 |
| 25 | 插件协议 | `blocks` + `init()`，身份来自清单 |
| 26 | 块结构 | `id`, `displayName`, `kind`, `supportedSizes`, `defaultSize`, `interaction`, `makeView` |
| 27 | 视图生命周期 | 稳定身份，保留 `@State`，`StateStore` 持久化 |
| 28 | 插件管理界面 | 独立管理窗口 |
| 29 | 插件设置 UI | 可嵌入管理窗口 |
| 30 | 签名策略 | 不要求签名/公证 |
| 31 | 多显示器 | 所有显示器，无刘海回退，共享布局，单窗口跟随鼠标 |
| 32 | 菜单贡献 | 支持，最多 3 项 |
| 33 | API 版本校验 | 语义化范围兼容 |
| 34 | 添加块方式 | 编辑模式内“+ 添加块”目录侧边栏 |
| 35 | 旧数据迁移 | 暂不迁移 |

---

## 附录 B：术语表

- **NotchCenter 核心**：宿主应用，负责基础设施。
- **插件**：实现具体功能的 `.bundle`。
- **块（Block）**：插件提供的最小 UI 单元，分为紧凑块和抽屉块。
- **紧凑区**：屏幕刘海下方随图标数动态伸缩的面板（图标左右分列刘海两侧）。
- **抽屉区**：展开后的网格面板。
- **`NotchCenterKit`**：宿主与插件共享的动态 framework，包含所有公共协议和类型。
- **`StateStore`**：核心提供的插件隔离状态存储。
- **`BlockContext`**：块视图创建时获得的上下文，包含状态存储和宿主服务。
- **`placementID`**：块放置实例的唯一标识。
- **`PlacedBlock`**：布局中一个已放置块的描述（位置、尺寸、引用）。
- **`layout.json`**：布局持久化文件。

---

*本文档基于 2026-08-21 问答讨论确认，作为 NotchCenter 第一阶段实施的架构基线。*