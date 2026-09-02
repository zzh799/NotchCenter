# API 变更日志:HostController

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。

## 2026-09-03 · v1.1.0 · added
- 新增 `showActivitySummary(_ summary: ActivitySummary)` / `removeActivitySummary(id: String)` 活动摘要通道成员(`ActivitySummary` 类型见 Kit,结构同见架构文档 §4.10);两者必须保持为**协议要求**(extension 仅默认空实现)。
- 语义:同 id 覆盖更新不改变新旧次序;id 不存在收回无副作用;宿主在刘海紧凑带内渲染芯片,不新建窗口。
- 兼容性:非破坏(纯新增)。
- 迁移:<无>
- 关联 Agent Note:[2026-09-03-compact-area-activity-summary](../agent-notes/implemented/2026-09-03-compact-area-activity-summary.md)

## 2026-09-03 · v1.1.0 · removed
- 移除活动岛通道:`showActivityIsland(_:)` / `removeActivityIsland(id:)` 与 `ActivityIslandContent` 类型(窗口机制随 `ActivityIslandPanel` / `IslandHostingView` 一并删除)。
- 兼容性:破坏(依赖旧通道的插件须迁移;`NotchCenterKitAPI.currentVersion` 升至 1.1.0)。
- 迁移:改用新增活动摘要通道 `showActivitySummary` / `removeActivitySummary(id:)`;官方插件已迁移(PomodoroPlugin / MediaControlsPlugin 参考实现)。
- 关联 Agent Note:[2026-09-03-compact-area-activity-summary](../agent-notes/implemented/2026-09-03-compact-area-activity-summary.md)

## Changelog
- v1.1.0:活动岛移除 + 活动摘要通道新增(2026-09-03)。
