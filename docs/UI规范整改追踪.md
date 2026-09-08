# UI 规范整改追踪

> 代码事实源 [`DesignTokens.swift`](../Sources/NotchCenterKit/DesignTokens.swift)（`NotchTokens`），spec 数值出自 [`DESIGN.md`](DESIGN.md) §2/§3/§4/§5/§7/§14；任一侧改动必须同步另一侧。本文件只追踪存量与进度。

## 扫描与规则

> `scripts/scan-ui-tokens.sh` 扫描三类内联样式字面量：`color-rgb`（硬编码 RGB 构造）/ `font-raw`（裸 `.font(.system(size:))`）/ `spring-raw`（裸 spring 参数）。警告级、不挂构建门禁；基线根目录 `ui-token-baseline.json` 只降不升（`--strict` 超基线 exit 1，`--update-baseline` 重写快照）。豁免注释行与 `NotchCenterKit/`、`Tests/`、`Vendor/`。迁移与豁免约定见 [`插件开发约定.md`](agents/插件开发约定.md)「UI 推荐走 NotchTokens」节。

## 存量与进度

首扫 270 处（插件 184 + 宿主 86），历轮累计 96 处（插件 10 + 宿主 86）。

- [x] OpenCodeUsagePlugin 38 → 2：峰谷色收敛 `PeakClockPalette`，字体走 token；残留 2 为 `PeakClockColor` 逻辑层唯一色源（豁免）。
- [x] SystemMonitorPlugin 28 → 3：字体/量表轨道走 token；方向/等级色留 `MetricPresentation`（数据可视化豁免），内存 normal 绿归 `Semantic.accentGreen`。
- [x] ScratchpadPlugin 20 → 0：spring 收敛 `Motion`（`shelfAppear`/`removal`/`hover`）；chip 圆角/尺寸/描边 token 化，文件名常态 alpha 归 `muted`。
- [x] ClipboardHistoryPlugin 16 → 0：硬编码绿改 `accentGreen`，组界线改 `Hairline.divider`，0.15/0.12 统一 `hover`，行圆角归 `Radius.button`。
- [x] CalibrePlugin / DshPlugin 各 11 → 0：ServiceBlockView 上提 Kit（含 `ServiceBlockCompactMetrics`），Popover 字体 token 化。
- [x] PomodoroPlugin 16 → 3：字体走 `Text.system(...)` 工厂；阶段强调色留 `PomodoroTheme`（状态语义色豁免）。
- [x] MediaControlsPlugin 11 → 1：字体走工厂；播放强调蓝收敛 `MediaControlsTheme.accent`（语义色豁免）。
- [x] NotesPlugin 12 → 0：TextKit 字色经 `NSColor(NotchTokens.Foreground.*)` 桥接白 alpha 阶梯（0.62 就近 muted）；`RoundedHoverButtonBody` 上提 Kit。
- [x] QuickButtonBoxPlugin 10 → 0 / DisplayPlugin 6 → 0：字体走工厂；确认浮层动效归 `Motion.stateChange`。
- [x] CaffeinatePlugin 5 → 1：字体走工厂；激活底衬收敛 `CaffeinatePalette.activeFill`（状态色豁免）。
- [ ] 宿主 Sources/NotchCenter 86（暂缓，抽屉/编辑器/设置窗口内联字面量）。

## 后续收紧

扫描挂入门禁聚合并切 `--strict`；`Radius`/`Space` 纳入扫描规则；宿主批次迁移。
