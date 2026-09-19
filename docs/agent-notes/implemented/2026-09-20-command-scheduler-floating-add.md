# Agent Note: 定时命令块撤顶栏、新建钮收进右上角悬浮角标，最小尺寸放低到 300×300

status: implemented
date: 2026-09-20
deciders: 用户

## Context(背景与约束)

用户提出三项改动：撤掉块内顶部栏、新建按钮改到组件右上角悬浮显示、块支持最小 300×300。三点各自都有既有约束顶着：

- **工具行是块内唯一的控件带**：标题「定时命令」+ 任务计数 + 新建「+」+ 插件设置齿轮，占 24pt 高 + 6pt 间距（[TaskListView](../../../Plugins/CommandSchedulerPlugin/Sources/TaskListView.swift)）。撤掉它意味着块内不再有标题（块的识别由宿主的块显示名与图标承担，与 [镜子块整改](2026-09-20-camera-mirror-block-styling.md) 同一结论），也意味着**新建入口得换个落位**——行的长按触发器挂在行上（`blockPopoverTrigger` 只加在 `taskRow`），空态与卡片空白区没有任何触发器，没有「+」就无从创建第一条任务。
- **块内齿轮是重复入口**：宿主 [DrawerBlockContainer](../../../Sources/NotchCenter/DrawerBlockContainer.swift) 的左上角齿轮在**悬停**时即出现（`showsSettingsControl = hasSettings && isHovering`，2026-09-10 起已不要求编辑模式），与块内齿轮指向同一份 `SchedulerSettingsView`（插件的 `settingsView`）。同一入口写两遍，块内那份是净负担。
- **放低 minSize 会直接撞上决策 9 的硬约束**：卡片尺寸 = 块渲染尺寸 − `BlockPopover.cardInset`（48），因为宿主的鼠标「停留区」只看抽屉可见矩形（`NotchPanelInteraction.isPointInExpandedStayRegion`），浮窗窗口不参与判定——卡片伸出块的那部分鼠标永远够不到，光标一离开停留区抽屉就收起、浮窗跟着 dismiss。当时的兜底下限是 **320×200**：300×300 的块只给卡片 252×252，下限会**反向生效**把卡片撑出块 48pt（恰好等于留白），随后必然出现"浮窗一开就自己去关"的现象。所以本次不是改一个数字，而是要让卡片尺寸数学与两张卡的版式在 252×252 下都成立。
- **历史卡的版式假设**：左栏宽度有 148pt 下限（`listWidth`），252pt 宽的卡片留给输出的只有约 103pt——等宽日志在这种宽度下等于不可读。

out of scope（明确不动的部分）：调度/执行/存储语义（决策 1–5 与执行器）、活动摘要、块的 rec/max 两档、`BlockPopover` / `SettingPopover` 的 Kit 代码、`NotificationCenter` 与 `UserNotifications` 相关的一切。

## Decision(决策)

1. **撤掉工具行**：块内只剩任务列表一层（`BlockCard` 内直接是列表/空态）。`scheduler.block.title` 保留给宿主的块显示名，块内不再重复渲染。
2. **新建钮 = 右上角悬浮角标**：块级 `.overlay(alignment: .topTrailing)` + Kit `IconCircleButton(systemImage: "plus")`，`if isHovering` + `.transition(.opacity)` + `NotchTokens.Motion.hover`，`padding(SchedulerMetrics.controlInset = 6)` 与宿主编辑角标同一环。整套照 ClipboardHistory 的搜索/清空角标与 CameraPlugin 的启停钮抄：`DESIGN.md` §9「圆形角标式按钮的唯一外观基元…任何落位不得各自重画」。护栏：`.disabled(context.layoutInfo.isPreview)`（滑动切页的预览副本不得真的弹浮窗，同 Pomodoro / CameraMirror）。
3. **齿轮撤掉，只留悬浮「+」**：插件设置收敛为宿主左上角齿轮单入口（`settingsView` 未动，视图未动）。随之删除块内的 `presentGlobalSettings()`、本地化键 `scheduler.action.settings` 与 `scheduler.settings.title`（en / zh-Hans 同步，两表键集仍奇偶）。保留新建入口的理由见决策 2 的第二条约束——空态没有触发器。
4. **卡片尺寸数学抽成纯函数**：[`SchedulerPopoverMetrics.cardSize(ideal:blockSize:)`](../../../Plugins/CommandSchedulerPlugin/Sources/SchedulerTheme.swift) 逐轴 `min(理想尺寸, 可用空间)`，兜底下限降到 **200×160**，且下限恒满足 `≤ minSize − cardInset`（300 − 48 = 252）。**卡片在声明尺寸区间内绝不越出块**，下限只兜"块被拖到比 minSize 还小的一帧"。旧断言「最小块必须撑得住下限 320×200」连同那条隐含推理一并作废——它是把"下限"当成了固定事实，而不是可以跟着块走的值。
   - 抽取动机是可测：不变量不再靠读代码确认，而是单测直接喂三档尺寸验（见 Consequences 的测试清单）。
   - `@MainActor` 标注是 `BlockPopover.cardInset` 的执行者要求；不为了让枚举"看起来纯"而把 48 抄成插件内字面量（同一事实两处写，必腐烂）。
5. **历史卡加单栏版式**：卡片宽 < `twoColumnMinWidth`（420，取左栏 148pt 下限的反解）时改「记录列表在上（卡片高的 34%）、选中记录的输出在下」，宽卡仍是左右两栏。
6. **表单卡参数行自适应**：`ViewThatFits(in: .horizontal)` 二选一——宽卡一行（时间步进器 + 星期/日），窄卡两行。「每周」一行的自然宽约 317pt（两套步进器 + 七个星期钮），252pt 卡恒走两行。表单本身不另加滚动：`SettingPopoverCard` 的内容区已经是 `ScrollView`（`padding(14)`），小卡靠它滚动，保存另有 `keyboardShortcut(.defaultAction)`（回车仍可用）。
7. **三档尺寸**：min `300×300`（用户要求）、rec `660×460`、max `960×760` 不动。rec/max 不动是有意的：卡片数学在 300×300 下只是"能用"，日志真正好看仍要块大。
8. **探针收敛为一条** `scheduler.list`：`scheduler.toolbar` 随工具行消失；右上角悬浮「+」**不单列探针**——它必然落在列表区内，而 `BlockSizeVerifier` 对探针做互不重叠判定，单列会直接判错（同 CameraMirror 的收敛结论，见其决策 8）。`visibleRowsAtMinimum` 3 → 4：300 − 20 = 280 的内容盒里 4 行 = 226 装得下，5 行 = 290 越界；竖轴总和 10 + 226 + 10 = 246 ≤ 300 过门禁。
9. **空态提示改写**：`scheduler.empty.hint` 由「点 + 新建一条」改为「悬浮本组件，点右上角 + 新建一条」——角标只在悬浮时进视图树，静止态得有人指路（同 CameraMirror 未启动态常驻引导的动机）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 工具行保留，只把「+」挪到右上角悬浮 | 改动最小，块内恒有标题与计数 | 24pt 工具行 + 6pt 间距仍被白占；标题与块显示名重复；用户明确要求撤顶栏 | 否 |
| 齿轮跟「+」一起做两个悬浮角标 | 保留块内直达插件设置的路径 | 宿主左上角齿轮悬停即出（不要求编辑模式），与它同视图同语义，属重复入口；块内多一个常驻控件 | 否（用户裁定：齿轮撤掉） |
| 兜底下限不动（320×200），只把 minSize 放到 300×300 | 只改一个数字 | 下限反向生效把卡片撑出块 48pt → 卡片伸出部分鼠标够不到，浮窗一开就被抽屉收起带走（决策 9 的原始失效模式） | 否 |
| 历史卡窄卡仍走两栏，把左栏下限从 148 挤到 100 | 结构不改 | 252pt 卡片下输出栏不足 130pt，等宽日志基本不可读，且记录行会截断到认不出任务 | 否 |
| 最小尺寸再往下（如 240×300） | 能塞进更小格子 | 卡片 192×252：两栏阈值、表单窄行、任务行文本位（约 100pt）都要再退化一轮，收益只是"更小" | 否（用户定 300×300） |
| 历史/表单浮窗改走独立 `NSPanel`（旧决策 9B 的退路） | 尺寸自由，不受块尺寸夹持 | 当初否决理由未变（自管窗口生命周期 / 层级 / 多屏 / `orderFrontRegardless` 纪律）；本次版式降级已足够满足 300×300 | 否 |

## Consequences(影响)

- **用户可见**：块内无标题、无工具行、非常驻控件；鼠标悬浮后在右上角浮出标准圆形「+」（与宿主齿轮、✕、缩放握把同一环）。空块靠空态文案 + 悬浮「+」，满块靠悬浮「+」。
- **布局**：工具行 24 + 间距 6 全部还给列表，`visibleRowsAtMinimum` 3 → 4；`minSize` 300×300 下探针通过（246 ≤ 300）。编辑模式下右上角会与宿主的 ✕ 重叠——既有块（ClipboardHistory）同样如此，且编辑模式本身屏蔽块内容手势，可接受。
- **浮窗**：三张卡尺寸恒 ≤ 块 − 48；历史卡窄卡单栏、表单卡参数行窄卡两行。300×300 下卡片 252×252：历史卡约"记录列表 85pt + 输出 120pt"，能用但不宽裕。
- **本地化**：删 `scheduler.action.settings`、`scheduler.settings.title`；改 `scheduler.empty.hint`（en / zh-Hans 同步）。`LocalizationTests` 的键集奇偶与"值非空"门禁不受影响。
- **测试**：`CommandSchedulerTests` 的「工具行 + 最少行数」断言改为「上内边距 + 列表区 + 下内边距」；「卡片 ⊆ 块」断言改为：下限 ≤ `minSize − cardInset`，且三张卡在 `minSize` 上逐一算出后 + `cardInset` 不越出块；新增「块足够大（`maxSize`）时卡片取理想尺寸，下限不抬高它」。
- **文档**：`Plugins/CommandSchedulerPlugin/README.md` 同步块描述、悬浮「+」、设置入口与三档尺寸。`DESIGN.md` / `DesignTokens.swift` 无新增，Kit 无 API 变更（`BlockPopover.cardInset` 复用既有公开值）。
- **无迁移成本**：不涉及持久化数据、设置项、任务表 schema 或 run 索引格式；插件版本与 `Plugin.plist` 不动。

## Changelog

- v1.0.0: 初版（2026-09-20）。撤工具行、新建钮收进右上角悬浮角标、齿轮收敛为宿主单入口、minSize 放低到 300×300 并配套卡片尺寸纯函数与两张卡的窄卡版式。
