# Agent Note: 服务卡启停期的 UI 反馈（紧凑旋转指示 + 整卡按压加强）

status: implemented
date: 2026-09-18
deciders: 用户

## Context(背景与约束)

Dsh / Calibre 两张服务控制卡（Kit `ServiceBlockView` + 各插件监视器）在「用户按下启停」到「状态真正翻转」之间有 2 个反馈空洞：

1. **紧凑排布（宽度 < 110pt，也是默认 75×60 的推荐尺寸）在启停期间毫无变化**：紧凑排布按 2026-09-08 决策只留「图标 + 名称」，状态行被隐藏；而这排布下整卡点击是唯一启停入口（无开关子控件）。用户点下去后直到 launchctl 落定（含 600ms 延迟刷新）才有变化，中间像没反应。
2. **整卡按压反馈在浅底上不可见**：`blockPopoverTrigger` 的按压叠加是白色（填充 +0.03 / 描边 +0.12），而紧凑开启态整块铺了 `white.opacity(0.6)` 的浅底——白叠白零对比。「按下把服务关掉」恰是开启态（浅底）下的按压，也就是最需要反馈的那一次。
3. 顺带发现的状态谎言：块与浮窗在 busy 期间显示的是 `isBusy ? (isServiceOn ? stopping : starting)`，即**重启**与**开/关自启动**期间会顶着「正在停止…」，与用户实际点的动作不符。

out of scope：开关控件的乐观切换（按下即翻态、不等回读）、浮窗按钮的按下态、`*ServiceMonitor` 的轮询节奏。

## Decision(决策)

- **紧凑排布的启停指示**（Kit `ServiceBlockView`）：`isBusy` 时图标位换成循环旋转弧（`ServiceBusyRing`，直径 15 = `iconSize`、线宽 2），名称保留；图标与旋转弧共用 `iconSlotHeight` 18pt 槽高，切换不跳行。`accessibilityReduceMotion` 为真时静止。旋转曲线新增 `NotchTokens.Motion.spin`（linear 0.9s repeatForever）。
- **按压反馈分档**（Kit `BlockCard.swift`）：新增 `BlockPressFeedback{ standard, emphasized, dimmed }`，`blockPopoverTrigger` 增加 `pressFeedback:` 参数（默认 `standard`，既有调用方观感不变）。`emphasized` = 填充 +0.06 / 描边 +0.20（合成 0.085 / 0.29，明确高于强调态 0.055 / 0.20，确立「按下 > 强调 > 悬停 > 常态」阶梯）；`dimmed` = 黑叠加 0.14、不叠描边。判定落在纯函数 `ServiceBlockView.pressFeedback(isCompact:isOn:)`：紧凑 && 开启 → `dimmed`，其余 → `emphasized`（完整排布卡片永远是深底）。
- **busy 文案贯通**：两个 `*ServiceMonitor` 新增 `busyLabel`（在飞动作文案，busy 期间非 nil），块状态位与浮窗状态行统一读它，替代原来按 `isServiceOn` 反推的 `busyText`。顺带修掉重启/自启期间「正在停止…」的错报。
- 回归：`Tests/NotchCenterTests/ServiceBlockFeedbackTests.swift`（档位判定矩阵、白 alpha 阶梯、旋转指示与图标位槽高关系）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 紧凑 busy 时把名称换成「正在启动…」文案 | 方向明确（起 / 停可区分） | 名称消失、10pt 槽里塞状态字必然缩字；信息量还不如保留名称 + 旋转 | 否（用户未选） |
| 紧凑 busy 时整卡描边脉冲 | 不动图标位 | 开启态白底上白描边同样不可见；脉冲与抽屉动效抢注意力 | 否 |
| 旋转弧替换图标（本方案） | 零行数变化、浅底深底都可见、方向由开关底色承担 | 不区分启动 / 停止（紧凑态本就没有文字位） | 选此 |
| 全局加强按压（把 `standard` 直接调高） | 改一处、全应用一致 | 剪贴板行、暂存区、QuickButton 等块的按压观感一起变，超出本次诉求 | 否 |
| 按底色自动选档（覆盖层自己感知底色） | 调用方零参数 | 覆盖层拿不到下层绘制内容，SwiftUI 无此能力 | 否 |
| `pressFeedback` 参数 + 纯函数判定（本方案） | 影响面锁在服务卡；判定可单测；既有档位不动 | Kit 多一个公开枚举与参数 | 选此 |
| 紧凑启用态按压改为「按下即变关闭态」（乐观切换） | 反馈就是结果本身 | 服务启停可能失败（自启动失败 / bootstrap 报错），乐观态要处理回滚，与「开关诚实地反映 launchd 状态」的既有原则冲突 | 否（用户未选） |

## Consequences(影响)

- Kit 公开 API 增量：`BlockPressFeedback`、`blockPopoverTrigger(pressFeedback:)`、`ServiceBlockView.pressFeedback(isCompact:isOn:)`，与 `ServiceBlockCompactMetrics` 的三个新常量（`iconSlotHeight` / `busyRingDiameter` / `busyRingLineWidth`）。默认参数保证其他调用方（剪贴板、暂存区等）行为不变。
- `ServiceBlockView.body` 的 GeometryReader 上移到最外层（原在 `BlockCard` 内容内），宽度同时驱动排布与按压档位；`BlockProbe` 几何为声明式，不受渲染结构调整影响。
- `busyLabel` 是插件层新增的 `@Published`，两个插件各一份（沿用「两个实例尚可接受复制」的既有约定）。
- 文档同步：`DESIGN.md §7 / §9`、`服务控制类插件开发指南.md §3`、`宿主开发约定.md` 代码地图。
- 服务启停的实际耗时不变；变的是这期间的可见反馈。

## Changelog

- v1.0.0: 初始提案，同日实现并落地（2026-09-18）。
