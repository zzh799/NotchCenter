# Agent Note: 抽屉展开耗时 —— 打点分解与实测结论

status: implemented date: 2026-09-11 deciders: 用户（提出"组件较多时展开要等很久"，选定先打点测量）+ 实现代理replaces: <无> superseded-by: <无>

## Context(背景与约束)

**症状**（用户报告）：抽屉里组件较多时，展开要等很久才出来。

**动手前的三个假设**（都可能错，必须先量）：

1. `rebuildContent` 的全量元素重建（引擎查询 + 每块 `makeView`）是主因；
2. 宿主侧每块 chrome（卡片壳、编辑角标、两个常驻 `GeometryReader`）随块数累加是主因；
3. 内容是"每次展开都重新首渲染一遍"（`DrawerPanelView` 的 `content` 由`if ui.isDrawerExpanded` 门控，收起即整树卸载），所以重复展开代价全额再付。

**不做**（out of scope）：本轮只落**探针 + 基线 + 结论排序**，不改任何展开行为（用户选定"先测量"）；具体优化另立 note。

## Decision(决策)

**落可常驻的性能探针，用它把单次展开拆成五段，再按实测排序优化路线。**

- `Sources/NotchCenter/DrawerOpenPerf.swift`：`DrawerOpenPerfCollector` （会话 = 一次冷展开；阶段 `enter → rebuilt → revealed → inserted → laidOut → visible`；看门狗 5s 兜底未完成样本，**不吞样本**——漏阶段本身就是要看的信号）。与 `DragPerfCollector` 同款约束：零 `@Published`，探针自己不得触发重绘。
- 埋点：`expand` 冷路径入口、`presentDrawer`（重建后 / 窗口上线后）、`rebuildContent`（内容规模 + `makeView` 命中/未命中计数）、`DrawerPanelView.onChange`（内容进树 / 淡入完成）、`DrawerHostingView.layout()`（首次布局）。
- 三个开关（与 `NOTCHCENTER_DRAG_PERF_LOG` 同族，默认关闭）：`NOTCHCENTER_DRAWER_PERF=1` 每次展开一行分解；`NOTCHCENTER_DRAWER_BENCH=1` 跑用户真实布局；`=synthetic`/`=uniform` 由 `DrawerBenchLayout` 自造布局（**N 曲线** / **同型块对照**），模板块型取自本机已加载可用的块，布局读写重定向到临时文件——不读也不写用户真实布局。轮数 `NOTCHCENTER_DRAWER_BENCH_ROUNDS`（默认 3），结束打印汇总表后退出。基准期间**必须钉住抽屉**（hover 模式下鼠标不在停留区会 0.25s 后自动收起，量到的是被打断的读数），并**事件驱动地等会话收尾**再走下一步（重页"挂载 + 淡入"可达 3s+，固定步间隔会让样本串到下一次会话——首版就踩了这个坑，样本页码滞后一步）。
- 单测：`DrawerOpenPerfCollectorTests`（9 例）钉住会话语义（重复埋点不覆盖首读、看门狗兜底、新展开顶掉旧会话不丢样本、未开启时零副作用）与报告格式；`DrawerBenchLayoutTests`（4 例）钉住合成布局口径（页数/块数、同型去重、货架排布不重叠）。

### 实测读数（Release、`cell 75×60`、逐页 ×3 轮；两条曲线均可一键复现）

A. **N 曲线** `NOTCHCENTER_DRAWER_BENCH=synthetic`（块型按面积降序循环铺页）：

| 块数 | `rebuilt` | `mount`(窗口上线→首次布局) | `visible`(入口→淡入完成) |
|---|---|---|---|
| 2 | 0.4ms | 313 / **316** / 339ms | 600 / **625** / 667ms |
| 4 | 1.0ms | 526 / **553** / 555ms | 842 / **865** / 867ms |
| 8 | 2.0ms | 568 / **601** / 603ms | 896 / **927** / 946ms |
| 12 | 1.7ms | 814 / **815** / 830ms | 1158 / **1195** / 1265ms |
| 16 | 0.5ms | 1055 / **1074** / 1090ms | 1487 / **1516** / 1543ms |
| 20 | 0.5ms | 1148 / **1153** / 1164ms | 1593 / **1659** / 1662ms |

B. **同型块对照** `NOTCHCENTER_DRAWER_BENCH=uniform`（每页 12 枚同一块型，量"哪个块贵"）：

| 块型 | `mount`(中位) | 每块 |
|---|---|---|
| `clipboard.library` 8×7 | 3003ms | **~250ms** |
| `clipboard.history` 4×4 | 2649ms | **~221ms** |
| `pomodoro.page` 4×5 | 444ms | ~37ms |
| `notes.notebook` 4×4 | 426ms | ~36ms |
| `camera.mirror` 3×3 | 160ms | ~13ms |
| `brightness.sliders` 4×2 | 153ms | ~13ms |
| `scratchpad.shelf` 4×2 | 126ms | ~11ms |
| `pomodoro.timer` 4×2 | 129ms | ~11ms |
| `brightness.single` 2×1 | 105ms | ~9ms |
| `calibre.service` / `dsh.service` 1×1 | 105 / 109ms | ~9ms |

**结论（三条，全部与动手前的假设 1 相反）**：

1. **`rebuildContent` 不是瓶颈**：0.3–7ms，与块数几乎无关。假设 1 被证伪。
2. **宿主侧每块 chrome 只有 ~9–13ms**（B 组末尾四行就是宿主 chrome 的下限），假设 2 至多解释个位数百分比。真正的成本是**块自己的首次渲染**：`clipboard.library` / `clipboard.history` **各 ~220–250ms/块**（`ClipboardHistoryBlockView` 用非惰性 `VStack` 物化全部条目行，其内注释说明了为何不能用 LazyVStack——该"不能用"的结论已于 2026-09-12 定位为结构误用并修正，见 [2026-09-12-clipboard-lazy-list](2026-09-12-clipboard-lazy-list.md)），是宿主下限的 20 倍；其余块型 9–37ms。用户布局里恰好有两块剪贴板（4×4 + 8×7），单这两块就贡献 ~470ms。
3. **每次展开都全额重付**：同一页连续 3–4 轮，`mount` 无衰减（1160ms 上下）；假设 3 成立。另有 **~300–340ms 固定尾巴**（`visible − layout` 恒为 290–350ms），来自 `onChange` 里 0.2s 延迟 + 0.18s 淡入，与内容无关。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 1. 直接削宿主侧循环（去掉每块 GeometryReader、body 内 O(N) 重算） | 无行为变化 | 实测上限 ~10ms/块，解释不了 1.6s | **推迟**：不是瓶颈，做了也量不出来 |
| 2. 展开时跳过无谓的 `rebuildContent`（脏位） | 简单 | 实测该段仅 0.3–7ms | **否决**：收益 ~2ms |
| 3. 内容常驻挂载（收起不卸载）+ 温存/悬停预热 | 直接消灭"每次重付"的 0.3–3s，顺带修插件状态重播 | 常驻内存与空闲 CPU，需插件审查 | **首选**（数据支持，效益最大） |
| 4. 两段式展开（先上壳/快照，内容分批挂载） | 感知延迟与 N 无关 | 竞态最多、实现最重 | **次选**：若第 3 条仍不够再用 |
| 5. 先改 340ms 固定淡入（首帧上屏即淡入） | 每页都省 ~0.3s，改动极小 | 观感取舍（内容与形变同时进行） | **建议与 3 同批做** |
| 6. 插件侧：剪贴板行改惰性/限量物化 | 单块 250ms → 数十 ms | 触及置顶/解顶跨分区状态迁移（旧注释称不能用 `LazyVStack`；该结论已于 2026-09-12 定位为结构误用并修正，见 [2026-09-12-clipboard-lazy-list](2026-09-12-clipboard-lazy-list.md)） | **已落地**：扁平单 `ForEach` + `LazyVStack`，见该记录 |

## Consequences(影响)

- 新增诊断代码（`DrawerOpenPerf.swift`、`AppDelegate.maybeRunDrawerOpenBench`、各埋点、单测 8 例），**默认关闭、生产路径只多一次布尔判断**。
- 领域文档新增「展开成本结构」一节（`docs/agents/面板与抽屉.md`），含实测表与诊断入口；后续优化必须以该表的哪一段为靶子，改完用同一基准复量。
- 已知口径边界：`laidOut` 是"宿主视图完成首次布局"的界标，非上屏帧；真正的"用户看到了"以 `visible` 为准（两者差 ~340ms 的淡入尾段）。基准必须在 Release 下跑（Debug 噪声大），且需独占机器—— 同一台机并发跑测试时 `mount` 抖动可达 2 倍。
- worktree 构建坑（`.git` 是文件 → Tuist 认不出根目录；无网需复用主仓 SPM 缓存）已记入领域文档，不在此重复。

## Changelog

- v1:2026-09-11 首版:探针 + 基线 + 三条实测结论与优化排序。
