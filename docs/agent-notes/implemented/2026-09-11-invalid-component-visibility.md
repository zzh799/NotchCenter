# Agent Note:不可用组件的可见性与清理——停用要看得见，失效要能一键删除

status: implemented
date: 2026-09-11
deciders: zhouzihang
replaces: <无>
superseded-by: [2026-09-25-plugin-in-use-placement-criterion](2026-09-25-plugin-in-use-placement-criterion.md)（仅"清理只走手动"与"停用一律保留摆放"两条被取代；三态判据、占位渲染、调试页手动删依旧有效）

## Context(背景与约束)

- 需求原文两条：「设置调试中，增加：删除无效组件」；「组件上显示被禁」。
- 现状：抽屉构建块元素时，只要 `pluginManager.entry(for:)` 查不到、`entry.isEnabled == false`、块解析不到或 `stateStore` 为空，就**静默 `continue`**，宿主卡片里只留一格空白（`NotchPanelContent.buildDrawerElements`）；紧凑带同款，落到 `CompactElement(view: nil)`。用户看到的是"洞"，无从判断是插件被停用、插件被卸载，还是块定义没了。
- 关键事实（决定了删除的边界）：`PluginEntry.markEnabled(false)` 会把 `instance` 置 nil，于是**停用**插件的块同样解析不到 → 现有 `validate()` 的 `.unknownBlock` 把"停用"与"已卸载"混为一谈。照它删，会把用户只是停用掉的插件摆放一并删光，而这是不可逆的。
- 明确不做：不动 `validate()` 的 `.unknownBlock` 语义（那是布局校验口径，改动会波及冒烟输出与既有测试）；不清理紧凑带的空槽之外的其它布局问题（重叠/越界仍属校验范畴）。

## Decision(决策)

### D1 失效判据：插件在（不论停用）即视为仍有效

宿主侧唯一判据 `NotchPanelController.placementAvailability(pluginID:blockID:)`，三态：

| 情形 | 判定 |
|------|------|
| 插件不在发现清单里（已卸载/删除） | `.missing` |
| 插件已发现但**未加载**（= 停用中） | `.live`（**保留**，停用可逆） |
| 插件已加载，且声明里有这个块 | `.live` |
| 插件已加载，但块不存在、且不是注册表中的快捷动作 | `.missing` |

第三行覆盖快捷动作槽位：动作 id 以 `blockID` 名义入槽、合法绕过块注册表（见 `LayoutEngineTests.testQuickActionSlotInsertAndAppendBypassBlockRegistry`），不查动作注册表就会把用户的快捷按钮当失效删掉。

引擎侧只接收一个注入的布尔判据（`LayoutEngine.placementLiveness`），默认退回"块解析器能查到即有效"，测试与未接宿主的路径不受影响。

### D2 停用要看得见：抽屉与紧凑带渲染占位，不再静默留白

- 抽屉：解析不到真视图的放置项改为**追加占位元素**（带原 placement 的 frame 与当前
  跨度），按 D1 三态取文案——停用给「插件已停用」，失效给「组件已失效」。占位不可缩放。
- 紧凑带：`view: nil` 的分支改为占位视图（同一套文案/图标，尺寸取槽位 frame）。
- 文案沿用既有 `panel.page.unavailable.*` 的措辞风格（"…在插件设置中重新启用"）。

### D3 调试页加「删除无效组件」

`DebugSettingsPage`（设置 → 调试）新增一节：显示当前失效放置项数量 + 一键删除按钮（数量为 0 时禁用）。删除走引擎新 API `purgeInvalidPlacements()`（抽屉块 + 紧凑槽），删后压实空洞并落盘。**仅调试构建可见**（`#if DEBUG`，与同页 Size Lab 同款）。按钮文案与计数口径必须与 D1 完全同源，否则会出现"显示 N 个却只删掉 M 个"。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 按 `validate()` 的 `.unknownBlock` 删 | 零新判据 | 把"停用"当"失效"，删掉可逆状态下的用户摆放 | 否 |
| B 只删插件已卸载的，不管块定义消失 | 最保守 | 插件更新换掉块 id 后残留的格子永远清不掉 | 否 |
| C 三态判据 + 占位显示 + 调试页一键删（采纳） | 停用可见可逆、失效可清、口径单一 | 需给引擎注入判据 | **采用** |
| D 停用也一并删 | 抽屉立刻干净 | 用户点一下停用就丢摆放，不可逆 | 否 |

## Consequences(影响)

- `Sources/NotchCenter/LayoutEngineMutation.swift`：新增 `placementLiveness` 注入点、
  `isLivePlacement`、`invalidPlacementCount()`、`purgeInvalidPlacements()`。
- `Sources/NotchCenter/NotchPanelController.swift`：`placementAvailability` 判据 + 引擎接线 +
  调试页用的查询/清理入口。
- `Sources/NotchCenter/NotchPanelContent.swift`：抽屉与紧凑带渲染占位。
- `Sources/NotchCenter/SettingsPages.swift`：调试页新增「无效组件」一节。
- `Sources/NotchCenter/Resources/{en,zh-Hans}.lproj/Localizable.strings`：新增占位与调试页文案
  （两语种键集合必须一致，`LocalizationTests` 校验）。
- 回归：`LayoutEngineTests` 覆盖"停用保留 / 失效删除 / 计数与删除同源 / 快捷动作槽保留"。

## Changelog

- v1.0.0:初稿（三态判据；占位显示停用与失效；调试页一键删失效；停用一律保留）。
