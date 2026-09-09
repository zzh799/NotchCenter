# Agent Note: 番茄钟抽屉块 UI 按项目规范重做

status: implemented
date: 2026-09-09
deciders: 用户

## Context(背景与约束)

番茄钟抽屉块 UI 早于现行 UI 规范成形，逐条违反 `docs/DESIGN.md` 与 `docs/agents/插件开发约定.md`：抽屉视图自绘 VStack 而未走 Kit `BlockCard` 卡片壳；暂停/跳过/停止三个圆形按钮自绘（`Circle().fill(.white.opacity(0.09))`）而未用 `IconCircleButton` 统一基元；空闲态开始按钮是实色胶囊（阶段红 `opacity(0.85)`），违反「克制的白色层级」与 §9 统一按钮样式（`RoundedHoverButtonBody`）；全部前景/轨道色写内联 `.white.opacity(...)` 而未引用 `NotchTokens`；内边距 14 / 间距 9 未收敛到 `Space.cardPadding(10)` / `Space.blockGap(8)`；`PomodoroCompactView` 已死（入口早已改为快捷按钮 `pomodoro.toggle`，`blocks` 仅声明抽屉块，grep 证实无引用）却仍留存；设置界面同样散写内联透明度；README 仍记载已不存在的紧凑块。out of scope：引擎/统计/活动摘要通道/音效/计时参数与块像素三档均不动（`minSize 300×120` / `maxSize 300×240` 保持，只按新版式更新探针几何）。

## Decision(决策)

- 抽屉块包进 `BlockCard(hoverEffect: false)`：专注工具保持沉稳，悬停反馈由按钮各自承担（对标 `DisplaySlidersBlockView` 同为控件型卡片的做法）；无 `blockPopoverTrigger`（本块无浮窗内容，设置走插件级 `settingsView` 经 `SettingPopover`）。
- 版式常量收敛为 `PomodoroBlockMetrics` 命名枚举（内边距 10 = `Space.cardPadding`、纵向间距 8 = `Space.blockGap`、进度条高 4、控制钮直径 28）；空闲与运行中两态都 `maxWidth/Height.infinity` 居中，拉高到 240 时内容居中不拉伸（与 `OpenCodeUsageBlockView` 的 BlockCard 行为一致）。
- 控制钮换 `IconCircleButton`（直径 28，保证 120 高卡内的触击目标）；开始按钮换基于 `RoundedHoverButtonBody` 的 `PomodoroPrimaryButtonStyle`（白底层级 + 手型光标，复用 Kit 基体不自绘）；进度轨道换 `Surface.track`；全部文字换 `Foreground.body/secondary/muted`；倒计时保留等宽数字（`monospacedDigit` + rounded monospaced）。
- 阶段色（专注红/休息绿/微休息黄）只保留在圆点与进度条上，仍收敛于 `PomodoroTheme.swift` 单一调色板（`scan-ui-tokens` 基线 3 项豁免不变，不新增 `Color(red:)`）。
- 预览副本（`layoutInfo.isPreview`，滑动切页过渡）内控制钮禁用：只读展示，不认领共享单例的启停副作用。
- 删死代码 `PomodoroCompactView`；设置界面内联透明度换 token；README 块列表改记快捷按钮 + 抽屉块；探针几何按新版式更新（inset 10 / spacing 8，总需求 10+36+8+4+8+28+10=104 < 120，阈值与真实版式一致）。实现落点：`Plugins/PomodoroPlugin/Sources/PomodoroBlockViews.swift`、`PomodoroTheme.swift`（豁免注释）、`PomodoroSettingsView.swift`、`PomodoroPlugin.swift`（探针）、`README.md`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 保留实色胶囊开始按钮 | 专注态视觉强烈，一眼可点 | 违反白色层级与统一按钮样式，彩色块在深色抽屉里跳脱 | 否 |
| `BlockCard(hoverEffect: true)` 整卡悬停增亮 | 与服务卡一致 | 控件型卡片在按钮间移动鼠标时整卡闪烁，专注工具应沉稳 | 否，用 false（同亮度滑杆块） |
| 保留自绘圆形按钮，只换 token 颜色 | 改动最小 | 违反圆形按钮唯一基元，悬停/光标/无障碍三件套要手抄 | 否，换 `IconCircleButton` |
| 阶段色扩到按钮底/卡片底 | 阶段辨识度最高 | 引入彩色主题，违反克制白色层级 | 否，只留圆点 + 进度条 |
| 顺手放宽 maxSize 宽度到 3 列 | 大块更舒展 | 超出 UI 重做范围，牵动 sizeBox 与存量布局 | 否，尺寸不动 |

## Consequences(影响)

- 视觉：开始按钮由红胶囊变为白色层级圆角按钮；控制钮外观与编辑模式角标/用量卡刷新钮统一；卡片获得标准圆角 10 + 发丝描边（此前无）。
- 探针阈值从 112 降到 104，`verify-sizes` 重新校验；token 扫描基线不变（`PomodoroTheme` 仍 3 项，`BlockViews` 不新增命中）。
- 删除 `PomodoroCompactView`：无外部引用（单文件内定义，`blocks` 未注册），无迁移。
- README 与实现重新对齐（快捷按钮 `pomodoro.toggle/start/pause/reset` + 抽屉块）。

## Changelog

- v1.0.0:初版（proposed）。
