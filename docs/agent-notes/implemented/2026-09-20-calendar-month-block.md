# Agent Note: 日历块 `calendar.month`：150×150 当月速览 + 点击打开日历.app

status: implemented
date: 2026-09-20
deciders: zhouzihang

## Context(背景与约束)

需求：抽屉里放一个日历组件，点击打开日历.app，视觉对标 macOS 通知中心日历（公历月 + 今日农历 + 今日白圆高亮），交互形态对标竞品的「日历速览」小组件。仓库当前无任何农历 / 日历代码（全库 grep `农历|Lunar|Calendar(identifier: .chinese` 零命中），本 note 是首个日历类块。

硬约束来自既有门禁与契约：

- 官方抽屉块必须声明 min/max/recommendedSize 三档与 `probes`（[插件开发指南](../../插件开发指南.md) §3），`BlockMinSizeVerificationTests` 按 `Plugins/` 清单逐一校验，新插件不登记等于探针无人校验。
- 抽屉强制深色、UI 走 `NotchTokens`（[插件开发约定](../../agents/插件开发约定.md)），禁止内联字面量散写。
- `blockPopoverTrigger(onTap:onLongPress:)` 的 `onLongPress` 是**必填**参数，且点击必须走该管线的 `DragGesture`（裸 `TapGesture` 真机不回调，见插件开发约定的红线条款）——所以「长按」这个交互位必须承载语义，不能留空。
- 窗口温存契约：收起态视图不卸载，跨天刷新不能只靠 `.onAppear`/`.onDisappear`。

不在范围：翻月 / 周视图 / 日程事件（EventKit）、格子内农历与节日标红、多实例独立设置（本块无实例状态）、紧凑块形态与快捷按钮。

## Decision(决策)

1. **块身份**：`Plugins/CalendarPlugin`，块 id `calendar.month`，`kind: .drawer`，三档固定 `150×150`（min = max = recommended），`symbolName: "calendar"`。固定尺寸的代价是用户无法把它拉成宽块，收益是版式与探针可穷举、字号不随尺寸漂移。
2. **版式常量**（`CalendarMonthMetrics`，探针同源推导）：内边距 10（`Space.cardPadding`）→ 头部 15 + 间隙 2 + 星期行 13 + 网格 100，合计 150。网格纵向均分剩余高度：5 行月份行高 20pt，6 行月份行高 16.67pt，**上下边距恒为 10pt**（首版曾按固定行高留白，六行月份会顶到内边距上，改为此算法）。今日圆直径 = `min(19, 行高 − 2)`，六行月份自动收到 14.7pt。
3. **日历数据全走系统**：周首日取 `Calendar.firstWeekday`、星期头取 `veryShortStandaloneWeekdaySymbols`、月份名走 `setLocalizedDateFormatFromTemplate("MMM")`（zh-Hans 出「9月」，`MMMM` 会出「九月」）。zh-CN 的 firstWeekday 恰为周日，与截图一致，因此不写死周首日（写死只会让 en 环境错位）。
4. **农历**：`Calendar(identifier: .chinese)` 取月 / 日 / 周期年，自建 `正月…腊月` 与 `初一…三十` 映射（`ChineseLunarFormatter`），头部渲染为「9月｜八月初十」。干支年由周期年推（`(cycleYear − 1) % 10 / % 12`，Foundation 的 `.chinese` 年组件即 60 周期序号），只在长按浮窗显示，不占块内空间。
5. **点击 = 打开日历.app**：块视图叠 `blockPopoverTrigger`，`onTap` 内按 bundle id `com.apple.iCal` 经 `NSWorkspace.openApplication` 打开；长按（0.2s）弹宿主浮窗，内容为「月日 / 星期 / 干支+农历 / 点击打开日历」，`cardSize` 夹在块尺寸 − `BlockPopover.cardInset` 之内（150 块 → 102×102 卡片）。
6. **跨天刷新**：块视图 `@State today` + `.task` 循环睡到次日零点后重算；并在 `\.isDrawerPresented` 变为真时**幂等**重新校准（覆盖睡眠唤醒 / 定时器失准），不吃 `.onAppear` 语义。
7. **无状态**：不写 `stateStore`、无 `settingsView`、无快捷按钮、无活动摘要。纯函数式渲染，多实例天然一致。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 尺寸声明成区间（如 150–300）自适应 | 用户可按需放大 | 每个尺寸段都要版式与字号分支，探针推导复杂度翻倍；150 宽下 7 列已是舒适下限，放大只增加空白 | 否 |
| 头部加 ‹ › 翻月 | 不打开 app 也能看别的月份 | 需要实例状态、跨天回弹逻辑，还要吃掉 15pt 头部高度；想仔细看月份的人本就要开日历 | 否 |
| 每格挂农历小字 / 节日标红 | 信息密度高，中文日历惯例 | 150 宽下每格仅 18.57pt，挂两行必然压到 7pt 以下；节日表要自维护且跨年跨地区有争议 | 否 |
| 周首日写死周日 | 与参考截图逐像素一致 | zh-CN 的 `firstWeekday` 本就是周日，写死只会在 en 环境错位 | 否（跟随 locale） |
| 长按空实现（`onLongPress: { _ in }`） | 零代码 | `onLongPress` 必填；长按必然先出现按压增亮，然后什么都不发生，等于给用户一个坏掉的交互位 | 否 |
| 走 EventKit 读今日日程 | 块内有真实内容 | 需要日历访问权限、权限拒绝态与隐私面设计，属于独立特性 | 否（留后续 note） |
| 用 `NSDateFormatter` 现成农历（如 `chinese` 日历的格式化模板） | 少写映射表 | Foundation 无中文月日名模板，取到的仍是「8/10」数字形式，出不来「八月初十」 | 否 |

## Consequences(影响)

- 新增 `Plugins/CalendarPlugin/`（Plugin.plist / README / Sources / Resources），Project.swift 与 build.sh 自动发现，无需改清单；`Tests/NotchCenterTests/BlockMinSizeVerificationTests.swift` 的 `officialBlocks` 与 `LocalizationTests.modules` 必须同步登记。
- 无 Kit / 宿主 API 改动，无新 token（复用 `Space.cardPadding`、`Foreground.*`、`Radius.button`、`Text.system` 与 `Text.caption`）。
- 本地化新增键集，en 与 zh-Hans 必须键位一致（`LocalizationTests` 校验）。
- 纯逻辑（月网格布局、农历格式化、版式计算）落成可测函数，`CalendarMonthGridTests` 覆盖：2026-09-20 → 八月初十（与参考截图同日）、二月闰月边界、六行月份行高与上下边距等值、跨 locale 的周首日。
- 已知取舍：块在 6 行月份（如 2026-08、2026-11）行高比 5 行月份紧 3.3pt，字号不变——这是 150×150 正方形下的必然。

## Changelog

- v1: 初版；块尺寸、农历范围、长按语义与跨天刷新在实现前经可视化确认（150×150 固定、仅头部农历、行高自适应撑满）。
- v1.1: 实现落地（`Plugins/CalendarPlugin`，`CalendarMonthGridTests` 覆盖月网格 / 农历 / 版式三类纯逻辑，`BlockMinSizeVerificationTests` 登记后探针门禁通过）。头部月份模板由 `MMMM` 改为 `MMM`——zh-Hans 的 `MMMM` 会渲染成「九月」，与参考截图的「9月」不符。
