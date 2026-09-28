# Agent Note: 插件审计 backlog 第二批修复（功能坏账 + 主线程重活）

status: implemented
date: 2026-09-28
deciders: 用户

## Context(背景与约束)

[`插件优化审计`](../../插件优化审计.md) 首轮已修 5 条 P0/P1（[`2026-09-28-plugin-audit-p0-p1-fixes`](../implemented/2026-09-28-plugin-audit-p0-p1-fixes.md)）。本决策处理审计 backlog 里"现在就是坏的"7 条功能项与 3 条确定性主线程重活，共 10 条：

- Scratchpad 紧凑入口计数/清空失效（懒建 `storesByID` 覆盖不到未实例化 placement 的磁盘数据）；legacy 迁移在 store 非空时仍删旧记录（静默丢数据）。
- Pomodoro 无 `NSWorkspace` 睡眠观察，跨睡眠的历史时长被 wall clock 污染、跨多阶段靠 0.5s tick 逐拍补演并连播音效。
- Notes 未实现 `placementWasRemoved`，每实例内存与持久键 `activeTab.<placementID>` 成孤儿。
- CommandScheduler 设置页用静态常量初始化 `@State`，重开恒显示 30 分钟，动一下 Stepper 即覆盖持久值。
- Reminders `shutdown()` 不摘 `activationObserver`、不清 `hostController`，停用后 App 激活仍重建 `EKEventStore`。
- Camera `start/stopSession` 各派 detached 任务且立刻改 `isRunning`，快速切停可致会话在跑而 UI 认为停止（指示灯常亮、再也停不掉）。
- LidAngle 观察者 token 被丢弃致 `stop()` 摘不掉（停用后仍响应唤醒并重建定时器）；采样定时器跑主队列且同步 `IOHIDDeviceGetReport`；`start()` 不看 `preferences.isEnabled`。
- Caffeinate `isSleepDisabled()` 同步 spawn pmset，却在 `@MainActor` 的 init/停止/启动/恢复尾部调用。
- Clipboard 复制图片时的 SHA256 + 落盘 + 缩略图解码全在主线程；`ClipboardMediaStore.store` 未加锁。

明确 out of scope（留在审计文件）：第三梯队 3 条需真机验证的猜想项（CommandScheduler 唤醒补跑时序、SystemMonitor 32 位计数、LidAngle 休眠后句柄失效）；NotchTokens 收敛、本地化缺口、死代码清理、`PermissionGateView` 上收、CopyBack 主线程读盘（决策 D7 已声明先量测再定）。

## Decision(决策)

- **Scratchpad**：注册表在插件级 store 里持久化"已见 placementID 集合"，`attach` 时按集合预热各实例 store；`totalItemCount` / `removeAll` 因此覆盖未实例化 placement；`discard` 同时从集合移除。legacy 迁移只在 `seedIfEmpty` 真的接管后才删旧键。落点 `Plugins/ScratchpadPlugin/Sources/ScratchpadStore.swift`、`ScratchpadPlugin.swift`。
- **Pomodoro**：新增 `NSWorkspace.willSleep/didWake` 观察（幂等、随 store 单例常驻）。睡眠视作**暂停顺延**：`willSleep` 冻结引擎剩余时间，`didWake` 恢复并把进行中会话的 `startedAt` 顺延睡眠时长，历史时长与音效都不含睡眠。落点 `Plugins/PomodoroPlugin/Sources/PomodoroStore.swift`。
- **Notes**：补 `placementWasRemoved(blockID:placementID:)` → `NotesModel.forgetPlacement`，清 `editorStateByPlacement` / `activeTabByPlacement` / `placementGridRows` 与持久键 `activeTab.<placementID>`。落点 `Plugins/NotesPlugin/Sources/NotesPlugin.swift`。
- **CommandScheduler**：设置页 `timeoutMinutes` 改为从 `core.defaultTimeout` 派生（`@State` 仅存用户编辑中的值，随 `core` 变化同步），不再用静态默认覆盖持久值。落点 `Plugins/CommandSchedulerPlugin/Sources/SchedulerSettingsView.swift`。
- **Reminders**：`shutdown()` 摘 `activationObserver` 并清 `hostController`。落点 `Plugins/RemindersPlugin/Sources/RemindersCore.swift`。
- **Camera**：新增 `CameraSessionDriver`（非隔离、自带串行队列），把所有 `configure / startRunning / stopRunning` 收敛到同一条队列：最后一个意图必然最后执行。`isConfigured` 只在配置成功后置位（失败可重试）。块视图的收尾路径加 `isPreview` 护栏。落点 `Plugins/CameraPlugin/Sources/CameraBlockViews.swift`。
- **LidAngle**：观察者的 block token 入库、`stop()` 一并摘除；采样定时器迁到专用串行队列，`onReading` 回主线程再 `handle`；`preferences.isEnabled` 经 sink 驱动 `updatePollingState()`（禁用即停表，预览/生效中例外）。明确**不**按 `\.isDrawerPresented` 门控：本插件的效果本身就是"抽屉收起时盖子合上要生效"，按抽屉收起停表会破坏核心功能（与 Dsh/Calibre 的服务探测不同源）。落点 `Plugins/LidAngleDepthPlugin/Sources/LidDepthController.swift`。
- **Caffeinate**：`isSleepDisabled()` 改 async（内部 `Task.detached` 跑 pmset），`@MainActor` 调用点改 `await`。落点 `Plugins/CaffeinatePlugin/Sources/SystemSleepGuard.swift`、`CaffeinateStore.swift`。
- **Clipboard**：采集重活（SHA256 + 媒体落盘）移入轮询专用队列 —— `ClipboardPoller` 增 `prepareCapture` 闭包（在 `pollOnce()` 的采集分支、即调用线程上执行），`Outcome.captured` 携带 `PreparedCapture`（payload + imageHash + storedMediaName）；主线程只做记账。图片条目现在是**先落盘后判定**，去重/预算淘汰时沿用既有的"回收刚写的文件"路径。`ClipboardMediaStore.store` 补锁。落点 `Plugins/ClipboardHistoryPlugin/Sources/ClipboardPoller.swift`、`ClipboardHistoryStore.swift`、`ClipboardMediaStore.swift`。
- 落地即 `git mv` 本 note 至 `implemented/`，并同步审计文件。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| Scratchpad 新增 Kit 能力枚举 placement 目录 | 语义最直接 | 要给 `StateStore` 加目录枚举 API，扩公共面且与"键值模型"约定冲突 | 不采用，插件侧持久化已见 ID 集合 |
| Pomodoro 睡眠视作中断（丢弃进行中会话） | 实现最简 | 用户已专注的部分整段丢失 | 不采用，选暂停顺延 |
| Pomodoro 给引擎加 `shiftAnchors(by:)` 做时间平移 | 不需暂停语义 | 引擎要多一条只为系统睡眠存在的 API；与既有暂停机制重复 | 不采用，复用 `togglePause` + 顺延 `startedAt` |
| Camera 直接给两个 detached 任务加优先级/依赖 | 改动小 | 并发队列上的两个独立任务本就无顺序保证 | 不采用，改串行驱动器 |
| LidAngle 按 `\.isDrawerPresented` 门控采样 | 与 Dsh/Calibre 口径一致 | 抽屉收起时合盖效果会完全失效（本插件的核心场景） | 不采用，只按 `isEnabled` 门控 |
| Clipboard：把 `record` 整体改 async | 改动集中 | `pollNow()` 是测试的同步直注入口，会全面破坏既有用例 | 不采用，改在轮询队列预计算 |
| Clipboard：不再预写、仅把 hash 移后台 | 少一次写盘 | 缩略图解码（最大一笔开销）仍留主线程 | 不采用 |

## Consequences(影响)

- Scratchpad：紧凑角标在从未开过抽屉时也能显示正确计数；清空能删未实例化 placement 的磁盘数据。已见 ID 集合本身是新增持久键（`shelf.seenPlacements.v1`），首次启用时为空，需先打开过一次抽屉才登记（旧数据本来就要求打开过才有）。
- Pomodoro：锁盖再开时进行中专注从冻结处继续，历史时长不含睡眠；不再连播音效。用户手动暂停的会话不受影响。
- Notes：删实例即回收内存状态与 `activeTab` 持久键。
- CommandScheduler：设置页显示并保留用户实际配置的超时分钟数。
- Reminders：停用后不再订阅 App 激活、不再重建 `EKEventStore`；重新启用时 `attach` 会重新注入。
- Camera：快速启停不再留下"跑着但 UI 认为停了"的会话；`isConfigured` 语义变为"配置成功"（测试断言不变）。
- LidAngle：默认关总开关时不再常驻 8Hz 采样与主线程同步 HID 读取；启用后行为不变。传感器读数回调改经主线程 hop，`handle` 的时序仍由主队列串行保证。
- Caffeinate：刘海动画不再被 pmset 同步 spawn 阻塞；探针语义（读当前 SleepDisabled）不变，但调用点需 `await`。
- Clipboard：复制大图不再卡主线程；重复图片会先写后删一次（多一次写盘，换取不阻塞主线程）。
- 均不新增/删除公开 API；`LidAngleKit`、`NotchCenterKit` 不动。

## Changelog

- v1.0.0: 审计 backlog 第二批 10 条修复定稿（2026-09-28）。
