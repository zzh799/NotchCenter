# Agent Note:权限管理弹窗——逐条引导 + 缺权限自动弹出

status: implemented
date: 2026-09-11
deciders: 用户（形态拍板：仅弹窗、不进设置侧边栏）+ 实现代理
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 需求原文：「设置-全局-里权限管理，点击打开弹窗，需获取权限时，也显示弹窗，来逐条显示需要的权限，有按钮支持跳转，便于用户在系统设置中设置。」
- 用户已拍板形态：**仅弹窗**——不在设置侧边栏新增页、不新增 `SettingsPage` case。入口放在「设置 → 通用」页的一个 `SettingsSection`。
- 涉及权限 6 项（日历 / 提醒事项 / 摄像头 / 屏幕录制 / 辅助功能 / 定位），每项都有确定的 TCC pane，因此每项都能给出确定的跳转深链。
- 本批插件（日历、待办、天气、摄像头、截图 OCR 等）都需要这些权限，弹窗是它们的统一引导出口。
- 纪律（`docs/插件页面选题调研.md` §6 明写）：**权限要诚实**——每项都必须有清晰的授权引导与「拒绝后仍可用」的降级路径，不能因为拿不到权限就整页报错。
- 不做（out of scope）：
  - 不做「设置侧边栏权限页」（用户已否决）。
  - 不做权限的第一时间自动轮询提示（不主动打扰；只在**插件运行时真的发现缺失**或用户点击入口时弹出）。
  - 不代用户改 TCC 数据库（不可能也不需要），只做跳转引导。
  - 不做"申请即轮询直到授权"的守护逻辑（`requestAccess` 回调已够）。

## Decision(决策)

### 1 清单与状态查询落在 Kit，生产实现留在宿主

- Kit 新增 `Sources/NotchCenterKit/SystemPermission.swift`：`SystemPermission`（6 项枚举，带 `privacyPane` / `usageDescriptionKey` / `symbolName` / `requiresRelaunch`）+ `PermissionStatus`（`notDetermined`/`authorized`/`denied`/`restricted` 四态）+ `SystemSettingsURL`（**纯函数**构造 `x-apple.systempreferences:com.apple.preference.security?Privacy_<Pane>`）。
- **查询与请求拆成两个协议**：`PermissionStatusProviding`（同步、无副作用、不弹窗）与 `PermissionRequesting`（异步、会弹系统窗）。测试只注入前者即可覆盖全部状态分支，天然不可能触发真实授权窗。
- 生产实现在宿主 `Sources/NotchCenter/PermissionCenter.swift`：单一 `PermissionCenter` 同时实现两协议 + `PermissionGuidePresenting`，是宿主侧唯一权限门面。

### 2 跨进程入口走 `HostController` 协议要求（不是 extension-only）

`HostController` 新增 `permissionStatus(of:) -> PermissionStatus` 与 `presentPermissions(_ focus:)`。两者都声明为**协议要求** + extension 默认实现（默认 `.notDetermined` / 空操作）——理由与 `showActivitySummary`、`settingsView` 完全同族：宿主与插件经存在类型 `any HostController` 分发，**纯 extension 成员会被静态分发遮蔽、永远不执行**（`pluginWasDisabled` 曾整体失效）。只放 extension 的方案在本仓库有明确的历史事故记录，故不采用。

- 因此这是 Kit 对外 API 变更：`NotchCenterKitAPI.currentVersion` 1.3.0 → **1.4.0**（纯新增 + 默认实现，非破坏），并在 `docs/api-changelog/HostController.md` 追加条目。
- 同时新增独立协议 `PermissionGuidePresenting`，让「谁来弹窗」与「谁来查状态」解耦：插件只依赖 `HostController` 的两行方法，不关心弹窗怎么实现。

### 3 弹窗形态：独立 NSPanel，不复用 `BlockPopover` / `SettingPopover`

- 选择理由（**这是本 Note 最关键的取舍**）：`BlockPopover` 的 `present(anchoredTo:)` **必须锚定到一个抽屉块在宿主窗口坐标系里的 frame**，它靠"光标所在的可见窗口 + 块 frame"反算窗口原点，并订阅 `notchCenterDrawerDidCollapse` 做联动收起。
- 权限弹窗有两个入口：**设置窗口**里的「权限管理」行，和**插件运行时**的自动弹出。前者根本没有锚定块（设置窗口不是 `NotchPanel`，且设置面板可见期间抽屉可能未展开）；后者发生时抽屉前景未必在屏。硬套 `BlockPopover` 就得伪造一个锚点 frame，弹窗会飘到错误位置甚至不弹。
- 所以用独立 `NSPanel`（borderless + nonactivating + 置顶 + 跟随 App 外观），视觉**复用 Kit 的 token**（`NotchTokens.Surface.window` 近黑 + `Hairline.drawerEdge` 发丝描边 + `Radius.card` 圆角 + spring 弹出），保证与既有浮层观感一致。窗口管线（单例互斥、点击外部关闭、ESC 关闭）按 `BlockPopover` 的既有做法自建一份极薄实现。

### 4 「缺权限时自动弹窗」的触发链路

```text
插件运行时发现权限不可用
  → 块内渲染降级态（引导文案 + 「去系统设置」按钮），页面本身仍完全可用
  → 用户点击降级态的「Grant…」按钮 / 插件的 requestAccess 返回 .denied
  → context.hostController.presentPermissions([.calendar])
  → NotchPanelController.presentPermissions(_:)   （HostController 要求实现）
  → PermissionCenter.presentPermissionGuide(focus:)
  → PermissionGuidePanel.shared.present(focus:)   （独立 NSPanel，逐条列出 6 项）
  → 每行「Open Settings」按钮 → SystemSettingsURL.url(for:) → NSWorkspace.shared.open
```

- 关键点：**不是**"一启动就扫一遍弹窗"（那样会骚扰用户）。触发权在插件，弹出时机由插件在"真的需要这项权限"时决定；宿主只负责展示。
- 反过来，设置页入口是同一终点：`GeneralSettingsPage` 的「权限管理」行 → 同一个 `presentPermissionGuide(focus: [])`。

### 5 弹窗内容与「拒绝后仍可用」

- 6 项**始终全列**（逐条）：图标 + 名称 + 一句话用途 + 当前状态徽标 + 「Open Settings」按钮。`focus` 中的项高亮并排在前面，其余仍然可见（用户能顺手补齐其它权限）。
- 状态徽标四态各自配色与文案；`requiresRelaunch` 为真的项（屏幕录制 / 辅助功能）额外挂一行「授权后需重启 NotchCenter 才生效」。
- 降级纪律落成**插件侧约定**并写进 `docs/agents/系统集成与多语言.md`：权限缺失只改变块内的呈现（引导态），块仍然渲染、仍然可交互、不抛错。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 复用 `BlockPopover` 管线弹权限窗 | 零新窗口代码、外观天然一致 | 必须锚定抽屉块 frame；设置窗口入口没有锚定块，插件自动弹出时抽屉未必在屏——只能伪造锚点，弹窗会错位或不弹 | 否 |
| 设置侧边栏新增「权限」页 | 与其它设置页同构、常驻可查 | 用户已明确否决（形态就是弹窗） | 否 |
| 用 `NSAlert` 模态弹窗 | 极少代码 | 模态抢焦点 + 阻塞主线程；仓库已有前车之鉴（删页确认从 `NSAlert.runModal()` 改回内联浮窗，模态窗会在抽屉收起后悬空卡死） | 否 |
| SwiftUI `.sheet` | 代码最短 | 只能挂在某个宿主窗口上；设置窗口与抽屉窗口是两个窗，插件侧调用时没有稳定的呈现宿主 | 否 |
| `HostController` 只加 extension 默认实现 | 不改 API 版本、第三方零影响 | **踩已知坑**：宿主经 `any HostController` 分发，纯 extension 成员被静态遮蔽永不执行（`pluginWasDisabled` 同族事故） | 否 |
| `HostController` 加**协议要求** + extension 默认实现（采纳） | 存在类型分发正确；默认实现保证第三方遵守类零破坏 | 需 bump minor 并在 api-changelog 记录 | 是（与 `showActivitySummary` 一致） |
| 独立 `NSPanel`（采纳） | 两个入口都能弹；位置、层级、生命周期自己说了算；视觉仍走 `NotchTokens` | 需自建一份薄窗口管线 | 是 |
| 每条权限一个 `usageDescriptionKey` 都写进 Info.plist | 声明完整 | 屏幕录制/辅助功能的 TCC **不读**用途字符串，写了是噪音 | 否（这两项 `usageDescriptionKey` 为 nil，只做跳转） |

## Consequences(影响)

- **新增面**：Kit `SystemPermission.swift`（枚举 + 状态 + URL 纯函数 + 三个协议）；宿主 `PermissionCenter.swift`（生产实现）、`PermissionGuidePanel.swift`（独立 NSPanel + 视图）；`GeneralSettingsPage` 新增一节；`Resources/Info.plist` 新增 4 个用途键（日历/提醒/摄像头/定位，屏幕录制与辅助功能不需要）。
- **API**：`currentVersion` 1.3.0 → 1.4.0；`HostController` 新增两个协议要求（附默认实现，非破坏）；新增 `PermissionGuidePresenting` / `PermissionStatusProviding` / `PermissionRequesting` 三个可选协议。`docs/api-changelog/HostController.md` 追加条目。
- **测试**：`PermissionTests` 覆盖四态推导、URL 构造（6 项逐一断言 pane 名）、`requiresRelaunch` 与 `usageDescriptionKey` 的清单一致性、假实现驱动的"未请求/已授权/已拒绝/受限"四分支渲染决策、`focus` 高亮排序。**绝不调用真实 `PermissionRequesting`。**
- **降级**：权限缺失时弹窗本身照常打开且逐条显示（这就是它的用途）；插件块的降级态是插件侧义务，写进领域子文档。
- 落地后本 note 移入 `docs/agent-notes/implemented/`。

## Changelog

- v1.0.0:初稿（Kit 权限清单 + 四态；弹窗形态选独立 NSPanel；`HostController` 走协议要求 + 默认实现；触发链路与降级纪律）。
