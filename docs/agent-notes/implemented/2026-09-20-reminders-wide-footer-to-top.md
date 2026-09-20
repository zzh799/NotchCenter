# Agent Note:提醒事项块宽态页脚上移至顶部区带

status: implemented
date: 2026-09-20
deciders: zhouzihang

## Context(背景与约束)

需求（用户 2026-09-20 提出）：待办事项块在 **wide 与 large** 下，把 footer 改到 top Zone。

术语钉死：这里的 footer 指宽态底部的「大计数（22pt）+ 清单名（12pt）」条（`RemindersBlockView.footerZone` / `RemindersLayout.footerBand`），**不是**底部的撤销条/错误提示浮层（`bottomLayer`，保持不动）。

现状盘点：

- **窄态**：名称左 + 计数右，本就在 top zone，不在需求范围。
- **宽态**：top zone 只有圆形徽章，计数与名称沉在 footerBand（复刻参考中卡 368×290 的「计数沉底」版式）——**本次唯一要动的一态**。
- **大态**：计数（31pt）在上、名称（16pt）在下，今天刚按参考图落地（[`2026-09-20-reminders-large-header`](../implemented/2026-09-20-reminders-large-header.md) D2），**已经在 top zone，本方案不动**；若预期是大态也改成单行头部，属于推翻当日决策，需另行确认（见 D4）。

约束沿用：三态几何与探针同源推导（[`2026-09-20-reminders-block`](../implemented/2026-09-20-reminders-block.md) D3）；块内动作角标默认隐藏、悬停浮出（DESIGN.md §9）；不新增 `NotchTokens`。与参考中卡「计数沉底」的保真偏离是用户主动要求，记录在案。

明确不做：撤销条位置不动、窄态不动、大态不动（待确认）、不动宿主/Kit/`Plugin.plist`/本地化、不新增 token、不给宽态加头部线（参考中卡本就没有）。

## Decision(决策)

### D1 宽态 top zone：徽章 + 计数 + 名称 同行左对齐

`HStack { badge(⌀28); [计数 22pt + 名称 12pt]; Spacer }`：计数与名称保持 `firstTextBaseline`（沿用原 `footerZone` 的组合），徽章与文本行垂直居中。内容盒高 28 同时容纳徽章（28）与计数行盒（`footerContentHeight` = 28 已验证装得下 22pt 计数），**topBand 高度 48 不变**。内部顺序保持「计数在前」，与原 footer 组合及大态头部「计数优先」一致。

footerBand 整体删除，listBand 底边直达块底：宽态列表净增一个 footer 区带高（48pt）——336×162 可见行约 2.6 → 4.6 行，300×240 约 5.7 → 7.7 行。

### D2 宽态尾侧预留 10 → 36

计数/名称移入顶行后，`topTrailingReserve` 注释里「宽态的角标右侧本就是空白」不再成立。`topTrailingReserve(.wide)` 从 `padding`(10) 改为 `cornerControlInset + cornerControlDiameter + rowSpacing`（6+22+8 = 36，同窄态），保证悬停浮出角标时不压住计数/清单名。

### D3 几何与探针收缩

- 删除 `RemindersLayout.footerBand` / `footerContentRect` 字段及 `layout(for:)` 宽态分支的 footer 推导；`footerContentHeight` 更名 `wideHeaderContentHeight`（值 28 不变，语义从「底部内容高」改为「顶行内容高」）。
- `probes(for:)` 删除 footer 分支：宽态只剩 `top` + `list` 两个探针，三态统一。

### D4 大态不动（已确认）

大态的计数/名称已在 top zone，本方案零改动。用户于 2026-09-20 确认按默认执行（大态保持 `2026-09-20-reminders-large-header` D2 的两行堆叠 + 头部线，不改单行）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| D1 同行：badge + 计数 + 名称（计数在前） | 列表净增 48pt；与大态「计数优先」呼应；改动面最小 | 与参考中卡「计数沉底」偏离（用户主动要求） | **是** |
| badge + 名称左、计数右（对齐窄态头部） | 三态头部句式更统一 | 大计数跑到尾侧角标下方，悬停时该区域有视觉跳变；与原 footer 组合差异更大 | 否 |
| badge 一行 + 计数/名称第二行 | 头部最舒展 | 宽态高 162–249 本就稀缺，再吃 28pt 让列表反而变矮，与上移初衷相反 | 否 |
| 只删 footer 不上移 | 改动最小 | 计数/名称无处显示，信息丢失 | 否 |
| 大态也改单行/加徽章 | 三态头部完全同构 | 推翻当日参考图逐像素决策（两行堆叠 + 头部线） | 否（用户已确认不动大态） |
| 保留 footerBand 字段置 nil | 测试改动少 | 死几何留着必与实际布局漂移 | 否 |

## Consequences(影响)

- `Plugins/RemindersPlugin/Sources/RemindersMetrics.swift`：D2/D3 落点；文件头三态注释与 `topBand` / `footerBand` 字段注释同步改写。
- `Plugins/RemindersPlugin/Sources/RemindersBlockView.swift`：`content` 删 footer 条件块；`topZone` 的 `.wide` 分支重写为徽章 + 计数 + 名称；删除 `footerZone`；`topTrailingReserve` 相关注释更新。
- `Tests/NotchCenterTests/RemindersMetricsTests.swift`：`expectedProbeIDs` 宽态改两项；`probesMirrorLayoutBands` / `bandsTileTheWholeBlock` 去 footer 引用；`topContentAvoidsCornerControl` 删除 `state != .wide` 豁免并把宽态尺寸（300×240、336×162、336×249）纳入参数；`wideBadgeSitsAtLeadingEdge` 保留（徽章仍在内容盒左缘）。
- `Plugins/RemindersPlugin/README.md`：形态描述句改为「宽态是『徽章 + 计数 + 名称』头部 + 行列表」；顺带修正同句过期的「高 360」阈值描述（现为 300）。
- 无 Kit/宿主/`Plugin.plist`/本地化改动；撤销条（`bottomLayer`）与窄态零改动。
- 已知取舍：宽态头部从此偏离参考中卡；`footerContentHeight` 更名后，代码/文档里残留的「footer」字样按零容忍清理。
- 实现落地后本 note `git mv` 至 `implemented/`；commit 消息用 `fix:` 并引用 `(note: 2026-09-20-reminders-wide-footer-to-top)`。

## Changelog

- v1: 初版（proposed）。钉死术语（footer = 计数/名称条，非撤销条）；宽态上移方案 + 尾侧预留 36 + 探针收缩；大态不动列为待确认项。
- v1.1（实现落地）：`RemindersMetrics.swift` 删 `footerBand` / `footerContentRect`，`footerContentHeight` → `wideHeaderContentHeight`，`countFontSizeFooter` → `countFontSizeWideHeader`，`nameFontSizeWideFooter` → `nameFontSizeWideHeader`，宽态尾侧预留 36，`probes(for:)` 收缩为 top + list；`RemindersBlockView.swift` 宽态 `topZone` 改「徽章 + 计数 + 名称」同行（外层 center、内层 firstTextBaseline），删 `footerZone`；测试按本 note 更新并新增 `wideHeaderBandHoldsBadgeAndCount`；README 形态句同步（顺带修正过期阈值「高 360」）。D4 经用户确认按默认执行。全量 124 项测试通过。整库 RemindersPlugin 当时仍未入库，按仓库多 note 引用先例，本次与前序 reminders-block / large-header 实现合并为一个 commit、消息引用三份 note。
