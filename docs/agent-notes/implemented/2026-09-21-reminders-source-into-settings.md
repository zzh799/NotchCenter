# Agent Note:提醒事项数据源切换入口并入宿主设置浮窗

status: implemented
date: 2026-09-21
deciders: zhouzihang

## Context(背景与约束)

需求（用户 2026-09-21 提出）：待办事项块把左上角设置打开的内容，换成右上角清单按钮打开浮窗的内容，然后删除右上角清单按钮。

术语钉死：**左上角设置** = 宿主 `DrawerBlockContainer` 在悬停时浮出的齿轮按钮，走 `SettingPopover` 渲染 `NotchBlock.instanceSettingsView`（即 `RemindersInstanceSettingsView`）；**右上角清单按钮** = 块内 `RemindersBlockView.sourceSwitchControl`（`list.bullet.rectangle` 角标），走 `RemindersSourcePicker.present` 在 `BlockPopover` 里弹出 `RemindersSourcePickerCard`。

现状盘点：同一份"换数据源"能力有两个入口，且两处 UI 形态不同——设置浮窗里是 `Picker(.menu)` 表单（外加「未完成 N 项」与权限引导按钮），角标浮窗里是「智能 / 清单」分组列表（当前项打勾）。入口重复、形态不一致，是本需求要收掉的问题。

约束沿用：设置浮窗是插件设置的**唯一合法展示通道**（`SettingPopover` 文件头：任何插件设置都必须经它展示，不要在宿主或插件里自绘浮窗）；块的设置入口由宿主齿轮提供，插件只提供内容视图；`NotchTokens` 不新增（[DESIGN.md §9](../../DESIGN.md)）。

明确不做：不动三态版式骨架（区带划分与行列表几何）、不动块内行勾选、不动撤销条与错误提示（`bottomLayer`）、不动权限懒触发链路、不动宿主 / Kit / `Plugin.plist`、不新增探针。

## Decision(决策)

### D1 设置浮窗内容 = 数据源分组列表（与角标浮窗同一份渲染）

`RemindersInstanceSettingsView` 的 body 收缩为 `RemindersSourceList(instance:)`：`智能` / `清单` 两个分组 + 逐行选项（当前源打勾、具体清单显真实色点），即原 `RemindersSourcePickerCard` 的行渲染原样搬过来，**去掉它自带的 `ScrollView` 与外层 frame**（`SettingPopoverCard` 的内容区已经是滚动容器，再套一层会成嵌套滚动）。

随 `Picker` 一起退场的是设置里的「未完成 %ld 项」与权限引导按钮：前者不在角标浮窗的内容里，与"换成同一份内容"不符；后者与块内权限引导态重复（那块仍有按钮，且唯一入口是宿主权限管理面板）。

### D2 删除块内右上角清单角标

`RemindersBlockView` 删 `.overlay(alignment: .topTrailing) { sourceSwitchControl }`，连带删掉只为它存在的 `@State isHovering`（`.onHover` 与 `.animation(Motion.hover)` 同去；`BlockCard(hoverEffect: true)` 自带悬停反馈）与 `@State blockFrame`（角标浮窗的锚点追踪）。

### D3 角标的整条几何链路一并删除

删 `RemindersGlobalFrameReader`（`RemindersPalette.swift`，唯一消费者是块视图的锚点），删 `RemindersSourcePicker`（`present` / `cardSize`）并把文件更名为 `RemindersSourceList.swift`；`RemindersLayout` 删 `cornerControlDiameter` / `cornerControlInset` 字段，`RemindersMetrics` 删 `cornerControlInset` / `cornerControlDiameter` / `cornerControlInsetLarge` / `cornerControlDiameterLarge` / `topTrailingReserve(for:)` / `cornerControlRect(in:)`，`contentRect` 去掉 `trailingReserve` 参数改为左右对称内边距。

于是 `topContentRect` 尾侧不再让位：窄 / 宽态尾侧预留 36 → 0（`wide` 300 宽下头部内容盒由 254 放宽到 280），大态 58 → 0。**这是有意的**：预留存在的唯一理由是角标恒悬浮在右上角、不让位就会盖住计数或清单名（见 [`2026-09-20-reminders-wide-footer-to-top`](2026-09-20-reminders-wide-footer-to-top.md) D2），角标没了理由就没了；且兄弟插件一律不预留（`grep topTrailing` 只有本插件有 Reserve 概念），保留等于留一段永远无人占据的死留白 + 死几何（[插件开发约定](../../agents/插件开发约定.md)「撤销常驻控件后不要把它的探针留下」同旨）。

### D4 选择后关闭浮窗

列表行点击 = `instance.updateSource(_:)` + `SettingPopover.shared.dismiss()`，与角标浮窗原来的行为一致（原实现调 `BlockPopover.shared.dismiss()`，两条浮窗共用同一单例，语义等价）。

### D5 文案

删 `source.switch.help`（角标帮助文本）、`settings.section.source` / `settings.source.hint` / `settings.outstanding`（表单三件套随 `Picker` 退场）；`state.removed.hint` 里"用右上角按钮另选一个清单"改为指向左上角设置（en / zh-Hans 两份同步）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 内容换成列表 + 删角标（D1–D5） | 单入口、形态统一；删掉角标锚点与整条预留几何 | 设置浮窗失去"未完成 N 项"与权限按钮 | **是** |
| 只换内容、保留角标 | 改动最小 | 两个入口仍在，重复问题没解决，与需求后半句直接冲突 | 否 |
| 只删角标、设置保持 `Picker` 表单 | 少动渲染代码 | 用户明确要的是角标浮窗那套列表形态 | 否 |
| 齿轮点击改弹 `BlockPopover` 贴块小卡（复刻角标浮窗的定位） | 形态与角标浮窗逐像素一致 | 齿轮由宿主绘制、宿主决定经 `SettingPopover` 展示，插件要扩宿主钩子才能改；且违反"设置必须经 SettingPopover"的既有纪律 | 否 |
| 保留尾侧预留（角标删了但几何不动） | 无测试改动 | 死几何必与实际布局漂移，且留一段永久空白 | 否 |
| 设置里保留「未完成 N 项」 | 信息不丢 | 与"换成浮窗内容"不符；块头本身就有计数 | 否 |

## Consequences(影响)

- `Plugins/RemindersPlugin/Sources/RemindersBlockView.swift`：D2 落点（删 overlay / `isHovering` / `blockFrame` / 锚点 background / `sourceSwitchControl`）；行勾选与三态内容零改动。
- `Plugins/RemindersPlugin/Sources/RemindersSettingsView.swift`：整文件删除——它只剩一层"转发给列表视图"的空壳；`RemindersPlugin.listBlock.instanceSettingsView` 直接指向 `RemindersSourceList`。
- `Plugins/RemindersPlugin/Sources/RemindersSourcePicker.swift` → `RemindersSourceList.swift`：删 `RemindersSourcePicker` 枚举，`RemindersSourcePickerCard` → `RemindersSourceList`（名字不再带 Card：它不再是被弹出的卡片，而是设置浮窗的内嵌内容）；`RemindersSourceText` 不动。
- `Plugins/RemindersPlugin/Sources/RemindersMetrics.swift`：D3 几何删除；`RemindersLayoutState.large` 与 `topBand` 等注释里"右上角标"字样按零容忍清理。
- `Plugins/RemindersPlugin/Sources/RemindersPalette.swift`：删 `RemindersGlobalFrameReader`。
- `Plugins/RemindersPlugin/Resources/{en,zh-Hans}.lproj/Localizable.strings`：D5 键改动，两份键集必须一致。
- `Tests/NotchCenterTests/RemindersMetricsTests.swift`：删 `largeCornerControlFitsTopBand` / `cornerControlSitsInsideTopBand` / `topContentAvoidsCornerControl`（被删对象的专属断言），补 `topContentRectSitsInsideTopBand`（内容盒落在顶部区带内、左右内边距对称——保住内容盒的可见性覆盖，只是不再以角标为参照）；`wideBadgeSitsAtLeadingEdge` 去掉角标相交断言。
- `Plugins/RemindersPlugin/README.md`：「切换清单」一句改为唯一入口是块齿轮 / 设置面板。
- 无宿主 / Kit / `Plugin.plist` 改动；块尺寸三档与探针（top + list）不变。
- 已知取舍：块内不再能"悬停一下就换清单"，换源要走悬停浮出的齿轮（两步）；用户主动要求如此。
- 实现落地后本 note `git mv` 至 `implemented/`；commit 消息用 `fix:` 并引用 `(note: 2026-09-21-reminders-source-into-settings)`。

## Changelog

- v1: 初版（proposed）。钉死两处入口术语；D1–D5；尾侧预留归零与"未完成 N 项"退场列为已知取舍。
- v1.1（实现落地）：`RemindersSettingsView.swift` 整文件删除（纯转发空壳），`Plugin.swift` 的 `instanceSettingsView` 直接指向 `RemindersSourceList`；`RemindersMetricsTests` 三删一增（`topContentRectSitsInsideTopBand`），`wideBadgeSitsAtLeadingEdge` 去掉角标相交断言。全量 122 项测试通过（此前 124 = 122 + 被删 3 − 新增 1）。
