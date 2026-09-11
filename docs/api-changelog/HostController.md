# API 变更日志:HostController

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。

## 2026-09-11 · v1.4.0 · added
- 新增 `permissionStatus(of permission: SystemPermission) -> PermissionStatus` 与 `presentPermissions(_ focus: [SystemPermission])` 系统权限通道（`SystemPermission` / `PermissionStatus` / `SystemSettingsURL` 与 `PermissionStatusProviding` / `PermissionRequesting` / `PermissionGuidePresenting` 三个协议同批加入 Kit）。
- 语义:`permissionStatus` 同步、无副作用、**不弹任何窗**,插件据此渲染权限降级态(页面本身仍须可用);`presentPermissions` 请求宿主弹出「权限管理」弹窗逐条显示权限与系统设置跳转按钮,由插件在**运行时真的发现权限缺失**时调用,设置页入口走同一终点。
- 兼容性:非破坏(纯新增;两成员均为**协议要求** + extension 默认实现——**不得**退化为 extension-only,宿主经存在类型 `any HostController` 分发时纯 extension 成员会被静态遮蔽,同 `showActivitySummary` / `pluginWasDisabled` 的历史坑)。
- 迁移:<无>;插件侧用法见 `docs/agents/系统集成与多语言.md`「系统权限要诚实」。
- 关联 Agent Note:[2026-09-11-permission-management-panel](../agent-notes/implemented/2026-09-11-permission-management-panel.md)

## 2026-09-05 · v1.1.0 · added
- 新增 `quickActions() -> [QuickAction]` / `quickAction(id: String) -> QuickAction?` 快捷动作注册表读取通道（`QuickAction` 类型见 Kit，语义见架构文档 §4.11）。插件侧对应新增 `NotchCenterPlugin.quickActions`（登记）与可选 `NotchCenterQuickActionSink.acceptQuickAction(_:placementID:span:)`（容器块落位接收）。
- 语义:宿主在插件启用/attach 后自动收集动作、禁用/卸载前注销;返回的 `QuickAction` 是活体可观察实例(identity 稳定),点击方执行 `execute`、观察 `isActive` 拿开关态。
- 兼容性:非破坏(纯新增;三者均为**协议要求** + extension 默认实现)。
- 迁移:<无>;已有插件若想被「快捷按钮盒」收纳,见插件开发指南 §3「注册快捷动作」。
- 关联 Agent Note:[2026-09-05-quick-button-box](../agent-notes/implemented/2026-09-05-quick-button-box.md)

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
- v1.1.0:快捷动作注册表通道新增(2026-09-05)。
- v1.1.0:活动岛移除 + 活动摘要通道新增(2026-09-03)。
