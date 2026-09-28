# Agent Note: 剪贴板采集改常驻高速后台轮询

status: implemented
date: 2026-09-28
deciders: 用户
replaces: [2026-09-28-plugin-audit-p0-p1-fixes](2026-09-28-plugin-audit-p0-p1-fixes.md) 中 Clipboard 节拍部分

## Context(背景与约束)

用户报告：剪贴板历史仍然会丢失部分复制操作。定位出四个叠加成因：

1. **温存到期即停表（主因）**。2026-09-28 的审计修复把放置观察登记绑到块视图挂载生命周期，注释假设"抽屉温存使收起后视图仍挂载"；但 `DrawerContentWarmth` 只温存 300s。收起 300s 后视图卸载 → `viewDidDisappear` → `livePlacements` 空 → `stopTicking`，此后复制全部丢失，直到再次展开抽屉。
2. **冷启动从不开始**。从未展开过抽屉时块视图从未挂载，轮询表从不启动——这正是上一轮记为"已知边界"、且本轮确认用户会遇到的行为。
3. **间隔过长**。`activeInterval=1.0s` / `idleInterval=2.5s`。低于间隔的连续复制只剩最后一条（前一条已被覆盖，物理上不可恢复）；2.5s 极易被"复制→切 App→粘贴→切回→再复制"打穿。
4. **Timer 挂主 RunLoop**。`Timer` 加在 `RunLoop.main` 的 `.common`，主线程一卡（SwiftUI 渲染、抽屉动画）"发现变化"就被推迟/合并（timer coalescing）；`probe → MainActor → readPayload` 的多次跳转又拉长"发现→读取"窗口，窗口内再复制一次即丢。

约束：macOS 的 `pboard` 是 pull-only broker，Apple **不提供**剪贴板变更通知（已查证，无公开 API）。Polling 是唯一正解，问题在把它做稳。既有的隐私红线（transient 跳过、暂停不读载荷、暂停期不补记）与富媒体两段式读取（不为每次探测付载荷成本）必须保留。

Out of scope：私有 XPC 桥接 `com.apple.pasteboard.1`（第三方 Deck 的做法，未公开、随系统版本易碎，不引入）；间隔 < 0.5s 的连续复制（前一条已被覆盖，任何轮询都无法恢复）。

## Decision(决策)

- **D1 恒定 0.5s**：取消 active/idle 分档，固定 `0.5s`、`leeway 0.1s`。`changeCount` 单次约 10µs Mach IPC，CPU 可忽略；0.5s 是业界"甜点档"（0.3s 为实用下限）。
- **D2 插件启用即常驻**：轮询只随 `attach → suspend`（插件启用/禁用）起停，与放置实例、抽屉可见性彻底解耦。一并删除 occlusion 可见性探针（`ClipboardVisibilityProbe` 及 store 的 `probeAttached/Detached/VisibilityChanged`、`livePlacements`、`isObserved`、`currentInterval`）——分档取消后全是死代码。
- **D3 彻底解耦线程**：专用串行队列 + `DispatchSourceTimer`，在该队列上完成「探测 → 门控 → 读载荷」全程；仅把结论交回主线程落库。消除主线程卡顿拉长的"发现→读取"窗口，且探测严格有序（原先 `Task.detached` 探测存在乱序风险）。
- 判定顺序沿用既有 `ingest(_ probe:)`：自循环 → 计数未变 → 暂停 → transient → capture；纯函数化为 `ClipboardHistoryLogic.pollDecision`，可单测。
- 写回自循环用 `beginWrite/endWrite` 与轮询队列的"探测+计数前移"在同一把锁内互斥，杜绝把自写当外部复制；载荷读完**重探测**计数，变了就丢弃（下一拍收新的），保证不把新内容贴旧标签。

落点：新增 `Plugins/ClipboardHistoryPlugin/Sources/ClipboardPoller.swift`；改造 `ClipboardHistoryStore.swift`（内置引擎换成 poller、`attach(stateStore:startPolling:)`）、`ClipboardHistoryLogic.swift`（纯决策 + 迁移 `isTransient`、删 `DiagnosticMode.probeOff`）、`ClipboardHistoryViews.swift`/`ClipboardLibraryViews.swift`（删可见性探针）、`ClipboardHistoryPlugin.swift`（删 `placementRemoved` 调用）、剪贴板三套测试与插件 README。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 恒定 0.5s 后台常驻（本决策） | 彻底消除冷启动/温存到期/主线程卡顿三个丢记窗口；改动集中在剪贴板插件 | 每 0.5s 一次 Mach IPC 唤醒（可忽略）；删除分档省电逻辑 | 采用 |
| B 保留 active/idle 分档，仅提速（如 0.4s / 0.8s） | 收起档省些唤醒 | 收起时仍有 ~0.8s 丢失窗口；分档本身解决不了"温存到期停表"与冷启动 | 不采用 |
| C 只换后台表 + 提速，门控与读载荷仍跳主线程 | 改动小、测试契约不动 | 主线程繁忙时仍有"发现→读取"残留窗口 | 不采用 |
| D 事件驱动（CGEventTap 拦 Cmd+C / 私有 XPC 桥） | 无轮询 | 需辅助功能权限、只覆盖键盘复制、私有 API 随版本易碎 | 不采用 |
| E 维持放置门控，仅补"温存到期继续跑" | 语义最贴近上一轮 | 冷启动仍不记录；放置门控与可见性耦合仍在 | 不采用 |

## Consequences(影响)

- 剪贴板历史：App 启动（插件启用）后即常驻 0.5s 采集；冷启动、收起 >300s、未展开抽屉三种场景不再丢记。间隔 < 0.5s 的连续复制仍只保留最后一条（物理下限，README 声明）。
- 删除 `activeInterval`/`idleInterval`/`currentInterval`/`isObserved`/可见性探针等成员与 `DiagnosticMode.probeOff`；`ClipboardHistoryTests` 的节拍契约用例改写为"interval 常量 + start/suspend 起停"，新增 `pollDecision` 五态用例；`ClipboardAutoCleanupTests` 的 ingest 辅助改走 `pollNow()`。
- 上一轮 note `2026-09-28-plugin-audit-p0-p1-fixes` 的 Clipboard 节拍结论被本决策取代（该 note 已 implemented，仅在此标注取代，不移动文件）。
- 插件 README 与 store 头注释同步改写。
- 无持久化格式变化，旧历史与设置照常读取。

## Changelog

- v1.0.0: 常驻 0.5s 后台轮询定稿（2026-09-28）。
