# Agent Note:番茄钟空闲态瘦身与倒计时格式按载体分叉

status: implemented
date: 2026-09-20
deciders: zhouzihang
replaces: <无——本决策部分改写 2026-09-09-pomodoro-ui-redesign 的空闲态行数，不替代该 note>
superseded-by: <无>

## Context(背景与约束)

抽屉块空闲态原为三行对称栈（徽章 → 开始按钮 → 时长副文案）。问题：徽章与副文案重复表达同一件事——"即将开始的是多长时间的专注"，而真正的信息（时长）藏在 11pt 弱化文案里，视觉主体让给了一个没有任何状态语义的 `timer` 图标。

本次只动**抽屉块空闲态**与**倒计时文本格式**，不做的事（out of scope）：整页 hero 的布局与按钮文案（仍为 `drawer.startFocus`「开始专注」）；运行态四行结构与其布局探针（`pomodoroLayoutProbes` 镜像最满形态，是下限校验，空闲态减行不使其失效）；活动摘要芯片的文案长度（宽度封顶 180pt，见 [紧凑区与活动摘要](../../agents/紧凑区与活动摘要.md)）。

约束：倒计时文本的既有实现（`PomodoroEngine.swift` `pomodoroCountdownText`）按"不足 1 小时 `mm:ss`、超过则 `h:mm:ss`"分支，40 分钟输出 `40:00`，给不出需求要求的 `00:40:00`；且该函数被**三个载体共用**（抽屉块、整页 hero、摘要芯片）。

## Decision(决策)

### 1. 空闲态两行化

空闲态删去图标徽章与 `drawer.focusFor` 副文案，改为「倒计时 → 开始按钮」两行（落点 `PomodoroBlockViews.swift` `idleContent`）。删 `PomodoroBlockMetrics.idleBadgeDiameter`。

**硬约束**：空闲态倒计时必须与运行态倒计时同字号 / 字重 / 等宽（28pt semibold monospaced + `monospacedDigit`）——点「开始」时只应看到数字在走，不得出现任何位置、字号或宽度跳变。违背这条，本次改动即失去意义。

### 2. 倒计时格式按载体分叉，双方各自固定

| 载体 | 函数 | 格式 | 例 |
|------|------|------|-----|
| 抽屉块、整页 hero | `pomodoroCountdownText` | 固定 `HH:MM:SS` | `00:40:00` |
| 活动摘要芯片 | `pomodoroCountdownCompact`（新增） | 固定 `MM:SS` | `40:00` |

"固定"指去掉原先"跨 1 小时换格式"的自适应分支：主视图求**宽度稳定**（不随剩余时间在 5 / 7 字符间跳宽），芯片求**省宽度**（封顶 180pt 下容不下 8 字符）。两者语义不同，故不做成同一函数；边界写在两个函数的 doc comment 里。

### 3. 按钮文案 key 分叉

抽屉块新增 `drawer.start`（`开始` / `Start`）；`drawer.startFocus`（`开始专注` / `Start Focus`）保留给整页 hero。删除仅块视图引用的 `drawer.focusFor`。en 与 zh-Hans 两份表同步增删（`LocalizationTests` 校验键集合对称）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 单函数全局固定 `HH:MM:SS`（含芯片） | 三载体零分叉，改动最小 | 芯片副文案 5 → 8 字符，带宽估算膨胀；封顶 180pt 下换余量换不来收益 | 否 |
| B 主视图固定 `HH:MM:SS` + 芯片固定 `MM:SS`（本决策） | 各自取所需；主视图不跳宽、芯片不膨胀 | 存在两种格式，需靠注释与测试锁住用途边界 | **采纳** |
| C 仅空闲态用 `HH:MM:SS`，运行中保持自适应 | 改动面最小 | 点「开始」瞬间 `00:40:00` → `39:59` 宽度突变，正是本次要消灭的观感 | 否 |
| D 保留三行栈，只把副文案换成倒计时 | 最小改动 | 徽章图标仍占 40pt 纵向，与倒计时重复表达"时长" | 否 |

## Consequences(影响)

- **连带变化**：整页 hero 倒计时随 `pomodoroCountdownText` 一并变为 `00:40:00`（共用函数，全局固定格式的必然结果）。其按钮文案与布局不变。
- **不变**：摘要芯片显示（仍 `40:00`）、运行态布局、`pomodoroLayoutProbes` 与 `pomodoroPageLayoutProbes` 数值。
- **测试**：`PomodoroEngineTests.testCountdownTextFormatting` 七条断言全部重写（`0 → 00:00:00`、`3600 → 01:00:00` 等），并新增 `testCountdownCompactFormatting` 六条（含分钟超 60 的 `65:00`）。
- **文档**：`Plugins/PomodoroPlugin/README.md` 的空闲态描述已同步。
- 本决策不改写 2026-09-09 两份 note 的"跟随系统强调色"与"对称居中"结论，仅部分改写其空闲态行数。

## Changelog

- 2026-09-20:初版并落地（implemented）。
