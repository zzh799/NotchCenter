# Agent Note: 服务卡 busy 窗口改为真实状态驱动（goal 轮询替代固定 600ms）

status: implemented
date: 2026-09-18
deciders: 用户

## Context(背景与约束)

两张服务卡（Dsh / Calibre）的 busy 窗口由 `*ServiceMonitor.runAction` 决定，结构是「跑 launchctl → `Task.sleep(600ms)` → 清 busy + 探测一次」。那 600ms 的原意是给 launchctl 留 settle 时间，不是表达进度，于是它同时错在两个方向：

- **太短**：`bootstrap` 返回只代表 launchd 受理，worker 可能还在等外置卷（`probe()` 此时判 `.starting`，Calibre 场景可达数十秒）。600ms 后旋转指示停转、状态行切到「启动中…」，观感是「转圈停了 = 完事了」。
- **太长**：停一个已退出的服务，`bootout` 与状态落定都在几十毫秒内，剩下的是白等。
- **重启错位**：`kickstart -k` 之后 600ms 可能探到重启前的旧 `.managed`，UI 先亮「运行中」再跳回启动中。
- **失败被吞**：`toggleRunning` 里 `_ = control.start()` 丢弃返回值，bootstrap 失败只能靠 600ms 后的探测间接体现。

out of scope：不动轮询节奏（2s 活跃 / 10s 空闲）、不做进度百分比（launchd 不提供，旋转仍是不确定型指示）、不做开关的乐观切换（开关继续诚实回读）。

## Decision(决策)

- **收敛判定抽成纯值**（`Sources/LaunchdControlKit/ServiceActionGoal.swift`）：`ServiceActionGoal{ running, stopped, restarted(previousLaunchdPID:), autostart(expected:) }`，每个 goal 自带 `isSatisfied(by:)` 与 `timeout`。
  - `running`：`state == .starting || .managed`——**只等 launchd 把进程拉起来**，等卷的几十秒交给既有的黄灯 `.starting` 状态行，不让旋转指示一直转。
  - `stopped`：`!status.isLoaded`——野进程是否仍占端口不改变「launchd 已释放任务」这个事实。
  - `restarted`：`launchdPID` 非 nil 且 ≠ 动作前的值（踢活了新进程即算收敛）。
  - `autostart`：读回的 `RunAtLoad` 等于目标值（与 launchd 进程状态无关）。
- **收敛循环**：`ServiceActionWatcher.wait(goal:interval:timeout:minimumDuration:sample:)` 按 300ms 采样直到命中或超时（running 15s / stopped 6s / restarted 20s / autostart 4s）。采样器由监视器注入（`refreshOnce()` 顺带把中间真实状态推给 UI）。`minimumDuration` 450ms 是**可见性下限**（避免旋转弧只闪一帧），不参与收敛判定。
- **两个 `*ServiceMonitor.runAction`**：动作返回错误 → 立即以该错误收尾，不空转；否则轮询到 goal；超时 → 报新增的 `<name>.error.actionTimeout`。`busyLabel` 与 UI 层不动。
- **顺带修**：`toggleRunning` 的启动分支在 `status.isLoaded`（即 `.loadedNotRunning`）时改走 `control.restart()`（kickstart）。bootstrap 对已加载的任务必然报 already loaded，旧代码吞掉这个失败；错误可见化之后若不改，会把「服务其实起来了但没在跑」误报成 bootstrap 失败。

## Alternatives considered(备选方案)

| 方案 | 优点 | 理由 |
|------|------|------|
| 保留固定 600ms，只把注释写诚实 | 零风险 | 用户诉求就是「按真实状态播」；反馈空洞仍在 |
| 把 600ms 调大（如 2s） | 一行改动 | 治不了本质：真实时长既可能 <100ms 也可能 >10s，常数必然错在一侧 |
| busy 一直转到 `.managed`（真就绪） | 「转完=可用」语义最直白 | wrapper 等卷可达数十秒，转圈会被读成卡死；且 `.starting` 黄灯本来就是这个信息的正确载体 |
| goal 驱动 + 采样器注入（本方案） | 收敛逻辑可单测（脚本化采样器喂状态序列）；纯值判定覆盖矩阵清晰 | 选此 |
| 用 `launchctl` 的退出码/`-w` 等待代替探测 | 少写逻辑 | `launchctl bootstrap` 无「等就绪」语义；状态真源始终是 `probe()` |

## Consequences(影响)

- LaunchdControlKit 公开 API 增量：`ServiceActionGoal` / `ServiceProbeSnapshot` / `ServiceActionWatcher`（含 `Outcome{ settled, timedOut }`），回归用例 `Tests/NotchCenterTests/ServiceActionGoalTests.swift`（判定矩阵 + 脚本化采样器驱动的收敛循环）。
- busy 时长不再是一个常数：停止通常是几百毫秒，启动通常到 `.starting` 出现为止，失败路径立即结束。采样频率在 busy 期间从「一次性探测」升到 300ms 一次（每次 `probe()` 含 launchctl/pgrep/lsof/ps 数次 fork），仅持续到达成 goal 为止。
- 用户可见行为变化：命令失败立即报错而非静默；超时新增「未在预期时间内完成」错误文案；`.loadedNotRunning` 卡上按开现在走 kickstart 而不是失败的 bootstrap。
- 文档同步：`服务控制类插件开发指南.md`（API 速查 + 五件套 + §3 busy 口径 + 决策表）、`宿主开发约定.md` 代码地图。

## Changelog

- v1.0.0: 初始提案（2026-09-18）。
