# Agent Note:行列数可选范围改为按屏幕与格尺寸动态推导

status: implemented
date: 2026-09-10
deciders: 项目维护者

## Context(背景与约束)

- **问题**:行列数的三个「可选项范围」此前是写死常量——`LayoutModel.maxColumnsRange = 2...8`、`minRowsRange = 1...9`、`minColumnsRange = 3...8`;而**只有列容量**是动态的(`LayoutEngine.screenColumnCapacity()`,由屏幕宽度 + 格宽 + 间距 + 内边距推导)。后果如下。
- 宽屏(容量 > 8)用户调不到第 9 列;窄屏(容量 4)滑条上 5–8 段是死区,可选而不可达。
- **行侧根本没有容量概念**:最小行数下拉恒为 1–9,小屏选 9 行会让网格内容高于视口,底部空行只能靠 ScrollView 滚动看到。
- 格尺寸(单元宽/高、间距)本身是用户可调项(设置 → 布局),行列可选范围却与之脱钩:把单元格调大后,原档位立刻变成放不下的档位。
- **明确不做(out of scope)**:不引入「自动行列数」、不移除用户配置项——用户配置仍是真源;不改 `updateScreenConstraint` 的既定契约(**换屏导致的容量变化是临时状态,不永久改写 layout.json**,见 [布局引擎与网格](../../agents/布局引擎与网格.md)),存量 `maxColumns/minRows/minColumns` 一律原样保留、不做回改;不动块的落点/推挤/压实/校验语义——容量只夹「尺寸」与「可选档位」。

## Decision(决策)

- **容量计算抽成纯函数**(`Sources/NotchCenter/GridCapacity.swift`):输入「屏幕可用宽/高 + `GridMetrics` 快照」,输出列/行容量。列容量沿用现公式的等价形式;行容量为对称新增——1 行 = `cellHeight`,之后每行 +`stepHeight`,并扣除顶栏(`topBarHeight`)与底部内容内边距(`contentPadding`)。
- **屏幕可用高度进引擎**:`LayoutEngine.availableScreenHeight: CGFloat?`,由 `updateScreenConstraint(width:height:)` 写入;**nil 语义 = 未约束**(与 `DrawerLayoutMetricsResolver` 的 `maxHeight: CGFloat?` 同款约定),使既有只传宽度的测试保持原行为。控制器传入 `maxDrawerHeight(for:)`(= 屏高 − 顶部留白 − 紧凑带高),**不传**含设置面板让位的 `drawerMaxVisibleHeight`——后者随设置面板开合瞬变,会让档位跳。
- **动态可选范围**(引擎暴露、设置页消费):`selectableMaxColumnsRange` = `min(2, 列容量)...列容量`;`selectableMinColumnsRange(maxColumns:)` = `min(3, maxColumns)...maxColumns`(保住「抽屉不塌成一列窄条」的原设计意图,但绝不越过当前最大列数与容量);`selectableMinRowsRange` = `1...(行容量 ?? 静态兜底)`。全部保证 `lowerBound <= upperBound`,绝不构造空 `ClosedRange`。
- **生效值口径不变、下限补一次行容量夹紧**:`effectiveMaxColumns() = min(配置, 列容量)` 与 `minimumColumnCount() = min(配置, effectiveMaxColumns())` 保持原样;新增 `minimumRowCount() = min(配置, 行容量)`(屏高未知时退化为配置值)——与列侧对称,避免小屏上出现「视口外的空白行下限」。
- **多屏必须按「最憋屈」的那块屏算**(同日补丁):先前控制器同步容量时取的是**单块屏**——初始化取 `pairs.first`,展开/跨屏搬移时取鼠标所在屏。这与架构文档 §7.1 / §7.2 早已写明的「按**所有已启用显示器中最小可用宽度**」「最小分辨率屏幕」不符,后果是抽屉搬到小屏就放不下、行列档位随活动屏跳变。改为 `LayoutEngine.updateScreenConstraint(availableScreenSizes:)`:控制器把**全部** `pair` 的「屏宽 × `maxDrawerHeight(for:)`」喂进来,由 `GridCapacity.minimumAvailability` 取**分量最小值**(宽、高各自最小)。取分量最小而不是「先按某块屏算容量再比大小」:容量对可用尺寸单调不减,两者等价,而分量最小是那个「在每块屏上都放得下」的矩形下界,语义更直白。该路径因此**不接收 pair**——没有「当前屏」这回事,`expand()` 里换屏时调它只是保新鲜、结果不变(原两处按目标屏的调用已删除)。空序列不写任何值(无参考屏,`1440` / 未约束高的兜底留在控制器);值未变也不写(两个量是 `@Published`,而该方法在每次展开时都会跑,免得设置页无谓重算档位)。
- `LayoutModel` 的三个静态范围常量**保留**,语义降级为「持久化解码/绝对兜底边界」(上界统一为 `absoluteGridLimit = 64`),不再是档位真源。**上界必须放宽**:架构文档 §7.2 早已写明「全局上限 = 屏幕可用宽能容纳的列数」,留 8 会把动态档位重新卡死(宽屏 12 列的档位配上 8 的存储夹紧 = 又是一段死区);64 只用于兜住手改 JSON 的荒谬值——最小格 75×60 配零间距时 6K 级屏幕的容量也只在 40 上下。setter 的**存储**夹紧仍走静态范围(而非容量),保证换屏不丢用户配置。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| **A 范围动态化**(本决策) | 可选档位恒可达;行侧获得与列侧对称的容量约束;配置真源与「临时状态不回写」契约都不动 | 需把屏幕高度与紧凑带高度接进引擎;滑条轨道端点随屏幕/格尺寸变化 | **采用** |
| B 完全自动、移除配置 | 设置页更简单 | 用户失去手动控制;存量配置失效;与「用户配置是真源」的既有设计冲突 | 否决 |
| C 只补行容量封顶 | 改动最小 | 列侧「可选而不可达」的死区仍在;格尺寸与档位依旧脱钩 | 否决 |
| D 滑条端点跟随容量但存储也按容量夹紧 | 表面更「动态」 | 换屏把存量配置夹小 = 永久改写临时状态,与既有契约冲突 | 否决 |

## Consequences(影响)

- **代码**:新增 `GridCapacity.swift`(含多屏合并 `minimumAvailability`);`LayoutEngine.swift`(`availableScreenHeight`)、`LayoutEngineMutation.swift`(`updateScreenConstraint(width:height:)` 与多屏重载、容量与档位访问器、行下限夹紧)、`LayoutModel.swift`(设计意图常量 + `absoluteGridLimit`)、`NotchPanelController.swift`(从**全部** pair 聚合喂屏高,三处调用点统一为全局口径)、`SettingsPages.swift` + `ColumnRangeSlider.swift`(消费动态档位,`valueRange` 在视图与 `ColumnRangeSliderMath` 上都**必传**);本地化新增 `settings.layout.rowCapacity`(en / zh-Hans 成对)。
- **测试**:新增 `GridCapacityTests`(纯容量,含退化步长与多屏合并 4 例)与 `LayoutEngineTests` 的「行列容量与动态档位」9 例;既有 `LayoutEngineTests` / `SettingsLayoutTests` / `DrawerLayoutMetricsTests` 因 `availableScreenHeight` 默认 nil 保持原行为。两处断言写死了旧静态范围(`LayoutEngineTests` 的 setter 夹紧、`ColumnRangeSliderTests` 的默认轨道)已改为引用常量/显式传 2...8。全量 640 XCTest + 12 Swift Testing 通过。
- **文档**:更新 [布局引擎与网格](../../agents/布局引擎与网格.md) 的「最小行数 / 最小列数只夹尺寸」一节并新增「行列容量是「屏幕 ÷ 格」的纯推导」一节(含多屏取最小一段);[架构设计文档](../../NotchCenter 架构设计文档.md) §5.3 / §5.4 / §7.2 同步口径。

## Changelog

- 2026-09-10:初稿(proposed)。
- 2026-09-10:补充「静态兜底上界必须放宽到 `absoluteGridLimit`」的取舍(否则动态档位被重新卡死);实现落地,全量 634 XCTest + 12 Swift Testing 与 9 项文档门禁通过,转入 implemented。
- 2026-09-10:修正多屏口径——容量按**所有屏的最小可用尺寸**(分量最小)算,不再取 `pairs.first` / 鼠标所在屏;全量 640 XCTest + 12 Swift Testing 通过。
