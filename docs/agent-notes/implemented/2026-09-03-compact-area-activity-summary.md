# Agent Note:紧凑带活动摘要(活动信息收进紧凑带)

status: implemented
date: 2026-09-03
deciders: zhouzihang
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 现状:插件活动(如番茄钟计时)经 `HostController.showActivityIsland` 在刘海下方弹活动岛窗展示;内容偏大时覆盖屏幕内容区,与"不遮挡屏幕"的期望冲突。
- 需求(已与用户确认形态):活动进行时,信息收进刘海紧凑带内呈现"当前活动简介 + 进度"迷你形态;屏幕其余区域不弹覆盖内容;状态出现/更新/消失均有过渡动画。
- 配套:媒体播放插件经本通道提交"正在播放"摘要,见 [`2026-09-03-media-controls-plugin`](2026-09-03-media-controls-plugin.md)。
- out of scope:各插件活动内容的内部设计。

## Decision(决策)

- **删除活动岛机制,新增"紧凑带活动摘要"通道**:`HostController.showActivitySummary(_:)` / `removeActivitySummary(id:)` 提交/收回结构化 `ActivitySummary(id:title:subtitle:symbolName:progress:)`;宿主在刘海紧凑带内渲染一行「图标 + 文案 + 迷你进度」芯片,**不新建窗口、不遮挡屏幕内容区**。
- 旧实现整体移除:`ActivityIslandContent` / `showActivityIsland` / `removeActivityIsland` / `ActivityIslandPanel` / `IslandHostingView` / `IslandHitTestingTests` 全部删除;Kit API 版本升至 v1.1.0(破坏性变更,明细见 [`api-changelog`](../../api-changelog/HostController.md))。
- 展示语义(宿主):按提交顺序维护序列(`PanelUIState.activitySummaries`),同 id 原位覆盖、**最新在左、次新在右**、仅一条在左、抽屉展开期间整体让位、收回后回退次新——纯逻辑 `ActivitySummaryDisplay.visiblePair`,领域约定见 [`紧凑区与活动摘要`](../../agents/紧凑区与活动摘要.md)。
- 几何与刷新纪律:摘要带宽变化沿镜像同步链路(`syncSummaryWidths` → `syncSummaryGeometryMirrors` → `positionCompactPanel` 非动画重摆),不走 `refreshCompactGeometry()`/`rebuildContent()` 全量路径;芯片宽度由 `SummaryChipMetrics.estimatedWidth` 估算(与渲染同字体规格 + 余量,宁宽勿裁、封顶 180pt),避免「测量 → 重建」环路。
- 动画纪律:出现/更新/移除过渡一律发生在既有窗口**内容内**(`.transition` 进出场、进度原位刷新),窗口 frame 不参与动画(活动岛 frame 动画是历史事故教训)。
- 协议纪律:`showActivitySummary` / `removeActivitySummary(id:)` 保持为 HostController **协议要求**(extension 只给默认实现),避免存在类型分发静态遮蔽。
- 存量迁移:PomodoroPlugin(经 `pomodoro.summary` 提交「阶段 + 剩余 + 进度」,停止收回)与新增 MediaControlsPlugin(经 `media-controls.summary`)改走本通道;进度刷新节流(整秒)与禁用收回在插件侧完成。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 信息收进紧凑带(本提案) | 不新增覆盖层、不遮挡屏幕,形态轻 | 带宽内空间有限,文字需截断/滚动策略 | 采用(用户已确认形态) |
| 岛窗收窄为单行胶囊 | 保留岛窗机制、改动小 | 仍在刘海下方占用屏幕空间,与"不外显内容"诉求不符 | 否 |
| 维持现状(大内容岛窗) | 零改动 | 遮挡屏幕内容区,不符合产品期望 | 否 |

## Consequences(影响)

- 宿主侧:`PanelUIState` 增加 `activitySummaries` / `summaryLeftWidth` / `summaryRightWidth`(含 `visibleSummaryPair` / `effectiveSummary*Width` 只读派生);`CompactSummary.swift` 承载排布与宽度估算纯逻辑;`CompactPanelView` 增加摘要芯片层;`NotchGeometry` 增加摘要带宽(镜像 + 配平)。
- Kit 破坏性接口变更记入 [`api-changelog`](../../api-changelog/HostController.md)(ActivityIsland removed / ActivitySummary + 通道 added);`NotchCenterKitAPI.currentVersion` = v1.1.0。
- 新增回归:`ActivitySummaryTests`(可见对/让位/覆盖不换位/收回回退/宽度估算)、`NotchGeometryTests` 摘要带宽节、`MediaControlsTests`(媒体摘要状态机)。
- 文档同步:领域子文档更名并重写为 [`紧凑区与活动摘要`](../../agents/紧凑区与活动摘要.md);架构文档 §4.10 重写;PomodoroPlugin README 改述摘要通道。

## Changelog

- v2:implemented 收口(2026-09-03)——活动岛机制整体移除、以摘要通道替代;带宽内文案策略=估算 + 截断兜底;多活动展示取舍=每侧各一条(最新左/次新右);进度刷新节流在插件侧(整秒)。
- v1:proposed 草案(2026-09-03)。
