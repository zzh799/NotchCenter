# Agent Note: 单屏亮度横向滑杆改 AppKit scrub 交互层

status: implemented
date: 2026-09-09
deciders: 用户(路线一确认:基于 AppKit 基础控件重做横向交互,横向 fill 与横向药丸一起换)

## Context(背景与约束)

单屏亮度横向自绘滑杆(小 fill 横条、大药丸横条)用 `DragGesture(minimumDistance: 0)` 挂在普通 `Color`/`Capsule` 上,视图树里没有 ScrollView。非编辑态页带整面是 `simultaneousGesture` 切页(设计如此,含块上方),控制器靠 `DrawerScrollProbe` 决定让路,而探针只认识 `NSScrollView`/`NSClipView` 的横向溢出,对自绘手势恒返回"放行"。结果双响应:亮度 scrub 的同时页面跟手走。竖条免疫纯属方向门槛(`DrawerPageSwipe.side` 横纵压比)过滤,与探针无关。触控板滚轮通路不受影响(药丸不消费滚动事件,横扫仍应切页),本次只修鼠标拖拽通路。

out of scope:宿主与 Kit 零改动(不加块级声明);竖向手势、1x1 启动器、浮窗行为不动;DDC 写入语义不动。

## Decision(决策)

- 新增 `HorizontalScrubStrip`(NSViewRepresentable,落点 `Plugins/DisplayPlugin/Sources/SingleBrightnessBlockView.swift`):内层 NSView 在 AppKit 层吃掉 `mouseDown`,经 `window.nextEvent` 跟踪循环消费整段拖拽(含拖出边界,钳制 0...100),`mouseUp` 收尾。事件到不了 SwiftUI 手势系统,祖先的 simultaneous 切页手势收不到位移,双响应消失;`scrollWheel` 不处理,触控板切页原样保留。
- 只在横向分支挂载:小 fill 横条整块 overlay,大药丸横条 overlay 后按 Capsule 裁形(裁形同时约束命中);竖向分支保留现有 `DragGesture` 不动。
- 位置换算抽成纯函数 `HorizontalScrubMath.percent(atX:width:)`(视图与测试共用);写入语义复用现有 `scrubSingleBrightness` + 松手终值补写,不变。
- 禁用态(`isPreview` 或未 ready)命中穿透(`hitTest` 返回 nil),行为与没挂 strip 时完全一致;`acceptsFirstMouse` 返回 true(面板是非激活 borderless,首击即调,与现有 SwiftUI 手势体感一致)。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 宿主按块声明让路(控制器 yield) | 语义正,同类块可复用 | Kit+宿主+插件三处改动,打破"宿主零改动"约束 | 否决(本轮用户明确要控件路线) |
| 透明原生 Slider 盖在自绘药丸上 | 零 AppKit 代码 | 点轨道步进语义与"点哪跳哪"不一致,thumb 边距导致映射错位 | 否决,还原度不够 |
| 子手势改 highPriority 抢占 | 改动最小 | 父级本就是 simultaneous(并发上报制),抢赢也拦不住控制器那份位移 | 否决,方向错误 |
| ScrollView 伪造溢出喂探针 | 复用探针 | 为机制扭曲 UI,且触控板横扫会被块吃掉、页面切不动,语义反了 | 否决 |

## Consequences(影响)

- 仅插件内改动,宿主/Kit 不动;commit 走 `fix:`。
- 按在滑杆上起拖即归滑杆(含中途转竖向也不切页),与原生 Slider/老 sliders 块一致,平台惯例;空隙起拖切页不受影响。
- 测试:新增 `HorizontalScrubMath` 纯函数单测;AppKit 事件吞没与命中穿透走真机验证(横拖页面不动、空隙/触控板切页正常、预览副本惰性、未 ready 占位可切页)。
- 落地后本文件 `git mv` 至 `implemented/`。

## Changelog

- v1:proposed(2026-09-09,用户确认路线一后建)。
