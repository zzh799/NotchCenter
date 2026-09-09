# Agent Note: 总览块混合式密度：方向看格数、图表看像素

status: implemented
date: 2026-09-10
deciders: 用户(确认路线 A 混合式，MiniBar 保留)

## Context(背景与约束)

系统总览块按跨度切形态（`OverviewArrangement.forSpan`），只看格数不看像素。格子尺寸用户可调（设置 → 布局，宽 75...280、高 60...240），同一跨度在小格下物理像素减半，sparkline（高 26）与标题加数值挤在一起；大格下小跨度又有富余像素却强制只显示数字。用户还反馈总览缩不到 1x1，根因同源：最小跨度由 `ceil(最小像素 / 当前格子)` 换算，小格下最小值自然涨到 2x2，不是 bug。本次只解决“小尺寸下图表太挤”：像素不够时 sparkline 自动降级为 MiniBar（用户明确 MiniBar 保留），布局方向（网格 / 横排 / 竖排）不动。

out of scope:宿主与 Kit 零改动（`BlockViewCacheKey` 已含 frame，像素变化 naturally 重走 makeView）；`minSize` 像素声明不动（1x1 可达性随格子变化是既有语义）；单指标块仅加同款宽幅降级，不动阈值与单位逻辑；目录预览与防御路径回退推荐形态。

## Decision(决策)

- 方向继续用格数（`forSpan` 不动，用户意图：2x2 方格 vs 4x2 宽条在默认格下都是宽大于高，纯像素分不清），密度（sparkline vs MiniBar）新增纯函数看 `layoutInfo.frame.size`：`OverviewArrangement.showsSparkline(arrangement:contentSize:enabledCount:)`，落点 `Plugins/SystemMonitorPlugin/Sources/BlockLayoutArrangement.swift`。
- sparkline 网格按每 cell 分到的内容高度判定：行数按 `ceil(enabledCount / 2)` 算（开关关掉部分指标后 cell 变大应自动恢复图表），阈值 `minSparklineCellHeight = 90`（标头约 16 + 数值 22...32 + 两处间距 12 + 曲线 26 + 呼吸，推导见代码注释）；横排取整块内容高度同样阈值；`compactStrips / stackedMiniCells / miniCellRow` 本来就是 MiniBar 或纯数字，不参与判定恒走老路。
- 非正尺寸（目录预览等 frame 为零的路径）回退 true，保持推荐形态的 sparkline 外观不变。
- 单指标块同款：`MetricCellForm.showsWideSparkline(contentSize:)`，宽幅曲线高 52，内容高度阈值 60（52 + 呼吸），不够时 2x1 自动用 mini 形态（MiniBar 保留）。
- `OverviewBlockView / MetricBlockView` 新增 `contentSize` 入参（调用方传 `layoutInfo.frame.size`），创建期一次算好并透传给 `MetricCell(showsSparkline:)`；缩放拖拽预览期宿主只拉伸外框不重走 makeView，松手提交后才切换形态（既有行为，不变）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| B 纯像素（forSpan 换 forSize） | 格数依赖清零 | 分不清 2x2 与 4x2 意图，零 frame 回退分支多，测试重写面大 | 否决 |
| C 缩放时 GeometryReader 实时切换 | 拖拽中即时切换 | 视图内运行时状态与 BlockViewCacheKey 创建期语义冲突，有布局反馈环风险 | 否决，本轮只做提交后切换 |
| D 直接降总览 minSize 保 1x1 可达 | 小格也能 1x1 | 1x1 纯数字在小格下更挤，治标不治本 | 否决，留待后续按需再议 |

## Consequences(影响)

- 仅插件内改动：`BlockLayoutArrangement.swift`（新纯函数）+ `BlockViews.swift`（两个视图入参）+ `SystemMonitorPlugin.swift`（makeView 传 size）；默认格（150x120）下所有跨度判定结果与老行为一致，老截图不变。
- 测试：沿用 `SystemMonitorTests` 的跨度映射用例（不动），新增像素降级用例（默认尺寸保持图表、最小格降级 MiniBar、零尺寸回退、关指标后恢复）。
- commit 走 `fix:`（小尺寸图表挤压修复）或 `chore:`（以最终提交类型为准）；落地后本文件 `git mv` 至 `implemented/`。

## Changelog

- v1:proposed(2026-09-10，用户确认混合式路线后建)。
- v2:implemented(2026-09-10，实现落地，全量 580 单测与 9 项文档门禁全过)。
