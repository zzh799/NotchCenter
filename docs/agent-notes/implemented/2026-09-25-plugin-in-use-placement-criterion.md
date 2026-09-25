# Agent Note:插件「使用中」判据与停用即弃摆放——徽章、二次确认、启动清理

status: implemented
date: 2026-09-25
deciders: zhouzihang
replaces: [2026-09-11-invalid-component-visibility](2026-09-11-invalid-component-visibility.md)
superseded-by: <无>

## Context(背景与约束)

- 需求原文：「给设置-插件-插件列表增加标识：使用中」。
- 现状：插件页列表行只有「内置/用户」与条件性的「不兼容」两枚徽章（`PluginManagerWindow.swift` 的 `pluginRow`），没有任何"这个插件现在到底有没有在用"的表达；`PluginEntry` 上只有 `isEnabled`（行末开关）与 `instance`（是否加载），**没有**"是否被摆到界面上"的判据。
- 关键事实（决定了判据口径）："被摆放"在布局里有两处——抽屉网格 `drawerBlocks` 与刘海紧凑带 `compactSlots`（后者既可放块、也可放快捷动作，两者都以 `pluginID` 记名）。引擎侧已有 `isLivePlacement`（走注入的 `placementLiveness`，宿主侧三态判据是 `NotchPanelController.placementAvailability`），`invalidPlacementCount()` / `purgeInvalidPlacements()` 与它同源。
- 09-11 已定：**停用不算失效**（`placementLiveness` 对"已发现但未加载"返回 true），失效清理只走「设置 → 调试 → 删除无效组件」手动触发且 `#if DEBUG` 才可见。
- 明确不做：不动 `validate()` 的 `.unknownBlock` 语义；不给详情区与「组件」页加同款徽章；不改插件列表排序。

## Decision(决策)

### D1 「使用中」= 该插件至少有一条**可用**的摆放

`LayoutEngine.inUsePluginIDs: Set<String>`：遍历 `drawerBlocks` + `compactSlots`（去 Optional），用 `isLivePlacement` 过滤后收 `pluginID`。判据与 `invalidPlacementCount()` / `purgeInvalidPlacements()` **同源**——失效摆放渲染成「组件已失效」占位，把它算作"使用中"是自相矛盾。

- **不是** `isEnabled`：那是行末 Toggle 已经表达的事，徽章会变成纯冗余。
- 列表视图**一次算完**再传给每行（`pluginList` 里 `let inUse = layoutEngine.inUsePluginIDs`），避免 N 行做 N 次全量遍历。

### D2 呈现：插件名后加绿色「使用中」徽章

位置紧跟「内置/用户」徽章、与红色「不兼容」并列，复用列表行既有的 `badge(_:tint:)`；配色 `NotchTokens.Semantic.accentGreen`（行内唯一的正向色，与灰徽章、红「不兼容」构成三级语义）。英文 `In Use`（键 `manager.badge.inUse`）。

### D3 停用即弃摆放：确认后连带移除（**取代** 09-11 的「停用保留摆放」）

插件的 Toggle 关向时，若该插件确有**正在使用**的摆放，先弹 `NSAlert` 二次确认（第一按钮「取消」、第二「停用」——破坏性动作不做默认按钮，与卸载确认的按钮序刻意相反），正文列前 3 个组件名 + 总数；若还有失效残骸，追加一句说明它们会被一并清除。

- 组件名解析：`pluginManager.block(pluginID:blockID:)?.displayName` → `quickActionStore.action(id:)?.displayName` → 回退 `blockID`。
- 取消时显式回滚 Toggle：`@State` 影子值 `enabledOverride`——不能指望"真值没变、SwiftUI 自己会把开关拨回去"，开关已经动过了。
- **与 09-11 的关系**：09-11 的"停用可逆、摆放要留着"作为**文件格式层**的不变量仍然成立（`placementLiveness` 对 `.pluginDisabled` 依旧返回 true，从外部改回来的"停用但仍被摆放"不自动清理）；被推翻的只是"UI 上停用插件时摆放一律保留"这一条——现在它是用户**确认过**的显式放弃。
- 执行落在 `NotchPanelController.disablePlugin(pluginID:)`，顺序刻意是**先通知再停用**：`placementWasRemoved` 要靠 `entry.instance` 才送得出去，停用会把实例置 nil，之后再通知到不了插件，各放置实例在 `placementStore` 里的数据会变成孤儿文件。移除后调 `refreshAfterEdit()`——摆放数量变了抽屉自然高度就变，只 `rebuildContent` 会留一截空白。

### D4 启动清理：release 自动、debug 手动

`LaunchMaintenance`（新类型）：`purgesInvalidPlacements`（`#if DEBUG` false / release true）与 `run(layoutEngine:purgeInvalidPlacements:)`（>0 时 NSLog，静默不弹窗）。调用点在 `NotchPanelController.init()` 的 `restoreEnabledState` **之后**、`refreshCompactGeometry()` **之前**——早于前者会把未注册的快捷动作槽误判失效，晚于后者要自己补一次刷新。清理口径 = 现有 `.missing`（插件已卸载 / 块定义消失），**不含停用**。

抽成独立类型而不是内联 `#if DEBUG`，是因为编译期常量让同一个测试进程只能验证一半，内联会把 release 那条最需要回归的路径放进盲区。

### D5 顺带修复：紧凑槽位的批量删除会换列

`purgeInvalidPlacements()` 原先用 `model.compactSlots.filter { … }` 删失效槽位。数组下标决定左右分列（`CompactSlotOrder.screenOrder` 只依赖总数），长度一变映射就变——被删项之后的图标会**整体换列**（屏幕上"删一个、其余跳边"），与 `setCompactSlot(_:nil)` 走 `CompactSlotOrder.removing` 的既有语义不一致。新增 `CompactSlotOrder.removingAll(_:where:)`（屏幕序列里批量摘除、一次重映射），`purgeInvalidPlacements()` 与新 API 都走它。

### D6 摆放在哪、插件就在哪被通知

新增 `LayoutEngine.placements(ofPluginID:)`（只读清单，带 `blockID` + `placementID`），与 `removePlacements(forPluginID:)`（按 pluginID 连失效残骸一起删，返回删除数）配对。**引擎只负责删，逐个补 `placementWasRemoved` 是调用方的义务**——与 `removeDrawerPage` 同款约定，见 `docs/agents/插件开发约定.md`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 徽章 = `isEnabled` | 零新增判据 | 与行末 Toggle 完全重复，无信息量 | 否 |
| 徽章 = `instance != nil` | 能顺带暴露"启用但加载失败" | 与"被摆上了"这个用户语义无关；启用了但没摆的插件也会亮 | 否 |
| 徽章 = 纯摆放命中（不过滤失效） | 实现最短 | 把渲染成「组件已失效」的僵尸摆放算作"使用中" | 否 |
| 停用保留摆放 + 徽章叠加运行判据 | 完全不触碰 09-11 | 徽章与 Toggle 会在"停用"上打架，残留长期累积 | 否 |
| 停用保留摆放 + 纯摆放判据 | 改动最小 | Toggle 已关、徽章仍绿，同屏自相矛盾 | 否 |
| 确认后连带移除摆放（采纳） | 与"使用中"的语义闭环 | 推翻 09-11 一条、不可逆 | **采用** |
| 把"移除摆放"并入 `purgeInvalidPlacements`（泛化成闭包 API） | 一个入口 | "清理失效"与"用户主动放弃"是两个动机，合并会让"停用不算失效"的口径变含糊 | 否 |
| 启动清理内联 `#if DEBUG` | 少一个类型 | release 路径永远无测试覆盖 | 否 |
| 停用时忽略 `placementWasRemoved` | 少几行 | 各放置实例的持久化数据变成孤儿文件 | 否 |

## Consequences(影响)

- `LayoutEngine.swift`：新增 `inUsePluginIDs`、`placements(ofPluginID:)`；`placementLiveness` 文档补一句"停用即弃摆放是 UI 动作、不是本判据的结论"。
- `LayoutEngineMutation.swift`：新增 `removePlacements(forPluginID:)`；`purgeInvalidPlacements()` 改走 `removingAll`（D5）。
- `NotchGeometry.swift`：`CompactSlotOrder.removingAll(_:where:)`。
- `LaunchMaintenance.swift`（新）：启动清理策略。
- `NotchPanelController.swift` / `NotchPanelContent.swift`：init 插入启动清理；新增 `disablePlugin(pluginID:)`；`showPluginManager()` 改为把控制器交给窗口。
- `PluginManagerWindow.swift`：`PluginManagerView` 改由 `controller` 构造（同时观察 `pluginManager` 与 `layoutEngine`）、行内徽章、停用二次确认与连带移除、`enabledOverride` 影子值。
- `SettingsWindow.swift`：插件页构造参数调整。
- 双语 `Localizable.strings`：新增 `manager.badge.inUse`、`manager.disable.confirmTitle/confirmBody/confirmBodyTruncated/confirmStale/confirmAction`、`common.listSeparator`（两语种键集合必须一致，`LocalizationTests` 校验）。
- 领域文档：`docs/agents/布局引擎与网格.md` 补启动清理策略、`removingAll` 与"判据单一"；`docs/agents/插件开发约定.md` 补"停用即弃摆放"对插件作者的含义。
- 09-11 note 补 `superseded-by` 指回本 note；它仍留在 `implemented/`——三态判据、占位渲染、调试页手动删依旧有效，只有"清理只走手动"被扩展。
- 回归：`LayoutEngineTests` 新增「使用中判据与按插件移除摆放」一节（含两例紧凑顺序保证）；`LaunchMaintenanceTests`（新）覆盖策略开/关与"停用不算失效"。

## Changelog
- v1.0.0:初稿（使用中 = 可用摆放；停用二次确认并连带移除摆放；release 启动自动清理；顺带修紧凑槽批量删除换列）。
