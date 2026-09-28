# Agent Note: 插件审计首批 5 条 P0/P1 修复

status: proposed
date: 2026-09-28
deciders: 用户

## Context(背景与约束)

7 个只读子智能体对 19 个插件做了一次深挖，结论落在 [`插件优化审计`](../../插件优化审计.md)。本决策只处理其中 5 条已核实的 P0/P1，其余留在审计文件作为 backlog，不在本轮范围（明确 out of scope：主线程重活、NotchTokens 收敛、本地化缺口、测试缺口补齐、需真机复现的猜想项）。

两条修复会改变既有行为，必须先留决策记录：其一，Clipboard 的轮询门控——2026-09-05 决策原定「常驻轮询 + 开 1.0s / 收起 2.5s 双档，无放置实例或禁用才停表」，实现却把放置登记绑在抽屉可见性上，收起即注销、`isObserved` 转假、`stopTicking`，等于关闭期间完全不记录；本轮按原决策语义改回。其二，Dsh/Calibre 的活跃档——`setActive` 从未被调用，文档要求的 2s 活跃档从未生效、恒 10s，且禁用后仍每 10s 起 shell 探测。

## Decision(决策)

- **Clipboard**：放置观察登记改随视图挂载生命周期（`onAppear`/`onDisappear`），不再随 `\.isDrawerPresented` 注销；抽屉可见性只经 occlusion 探针切换 `activeInterval`/`idleInterval`。收起后仍按 2.5s 记录。落点 `Plugins/ClipboardHistoryPlugin/Sources/ClipboardHistoryViews.swift`、`ClipboardLibraryViews.swift`，store 逻辑不动。
- **CommandScheduler**：`reschedule` 从「只 arm 最近的单个任务」改为 arm 全部启用任务（抽 `static func nextFires(tasks:now:)` 纯函数）；`tick` 本已遍历全部到点任务，保持不变。落点 `Plugins/CommandSchedulerPlugin/Sources/SchedulerCore.swift`。
- **Notes**：`scheduleSave()` 已有待执行保存时不再推迟（保证连续输入下至多 0.18s 落盘一次）；`NotesPlugin` 补 `pluginWasDisabled` 与 `NSApplication.willTerminateNotification` 两处 `flush()`。落点 `Plugins/NotesPlugin/Sources/NotesStore.swift`、`NotesPlugin.swift`。
- **Display**：补 `placementWasRemoved(blockID:placementID:)`，`SingleDisplayInstanceRegistry.discard` + 清 placementStore 的 `config.display`；插件级 DDC 区间不受影响。落点 `Plugins/DisplayPlugin/Sources/DisplayPlugin.swift`。
- **Dsh / Calibre**：块视图接入 `\.isDrawerPresented` 驱动 `setActive`；monitor 增 `suspend()`/`resume()`，`pluginWasDisabled` 停表、`attachServices` 恢复。落点两插件的 `Plugin.swift`、`*ServiceMonitor.swift`、`*ServiceBlockView.swift`。
- 落地即 `git mv` 本 note 至 `implemented/`，并把审计文件的链接同步过去。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| Clipboard：彻底改成插件级常驻观察（attach 即轮询，不看放置实例） | 冷启动、从未开过抽屉也能记录，最贴「常驻」字面 | 与 store 注释「无已放置实例 → 停表」冲突，且插件拿不到「放置被新增」的回调，只能反向放宽 | 不采用，本轮只解耦可见性 |
| Clipboard：保留现状，仅补「关闭期间补记最后一条」 | 改动最小 | 仍是关闭期间静默丢内容，与常驻语义相悖 | 不采用 |
| CommandScheduler：改成全局任务队列逐条 arm | 语义最直白 | 注释明确否决（一个卡死任务不该阻塞所有任务），改动面大 | 不采用，改为一次 arm 全部 + 单 Timer 等最近者 |
| Notes：另加一条独立的 max-wait 定时器 | 去抖窗口可精确配置 | 多一条状态与定时器，且无法用简单确定性测试锁住 | 不采用，改为「已有待执行不推迟」 |
| Dsh/Calibre：禁用时不销毁、只 `setActive(false)` | 改动更小 | 禁用后仍每 10s 探测，资源浪费未消除 | 不采用，加 suspend |

## Consequences(影响)

- Clipboard：收起抽屉后恢复 2.5s 记录；`ClipboardHistoryTests` 里「测试不登记 placement」的旧注释需同步更新，本轮补 `viewDidAppear → idleInterval` 断言。冷启动、从未打开过抽屉时仍不记录（放置观察随视图挂载才生效），属已知边界，不列入本轮。
- CommandScheduler：同刻多条任务现在都会触发；`nextFires` 为静态纯函数，可被单测穷举。
- Notes：连续输入最多每 0.18s 落盘一次（写放大略增，快照体积小）；强杀仍可能丢最近 0.18s 内的输入。
- Display：删单屏条实例即回收内存模型与 `config.display`；不改动块声明、探针与 DDC 区间存储。
- Dsh/Calibre：抽屉展开 2s、收起 10s、插件禁用停表、重新启用恢复；不新增单测（会触碰真实 launchctl，违反测试红线），靠构建与既有套件回归。
- 其余 backlog 项仍待排期，见审计文件第二、三、四节。

## Changelog

- v1.0.0: 审计首批 5 条 P0/P1 修复定稿（2026-09-28）。
