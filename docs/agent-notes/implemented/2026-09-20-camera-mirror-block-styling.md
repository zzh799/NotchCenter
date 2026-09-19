# Agent Note: 镜子块样式对齐规范：补卡片壳、启停钮收进块内悬浮角标

status: implemented
date: 2026-09-20
deciders: zhouzihang

## Context(背景与约束)

`camera.mirror`（[CameraMirrorBlockView](../../../Plugins/CameraPlugin/Sources/CameraBlockViews.swift)）是 11 个官方抽屉块里**唯一不自绘 `BlockCard`** 的块：宿主 [`DrawerBlockContainer`](../../../Sources/NotchCenter/DrawerBlockContainer.swift) 只负责 `clipShape` 与编辑态压暗，卡片表面（填充 / 发丝描边 / 悬停微亮）是插件的义务。其余块（Notes / Scratchpad / ClipboardHistory / Pomodoro / QuickButtonBox / Display / CommandScheduler，DSH·Calibre 经 `ServiceBlockView`）都已自绘。结果：镜子在抽屉里常态无填充、无描边、无悬停反馈，是样式异类。

另一个关键前提：`stopSession()` 在抽屉收起时执行（[决策](2026-09-11-drawer-content-warmth.md) 配套的 `\.isDrawerPresented` 契约），**每次展开后都是未启动态**。因此未启动态才是这个块的默认长相，而它当前的画面区底衬取 `Surface.fill`(0.025)，与卡片常态同值——等于一块和背景同色的空矩形。样式整改的重心必须落在未启动态。

`DESIGN.md` 相关约束：§9「所有抽屉块一致…统一套 `BlockCard`」与「统一按钮样式（`RoundedHoverButtonBody`）/ 圆形按钮基元（`IconCircleButton`·`IconCircleBadge`）」；§7「悬停背景/前景变化走 easeOut 0.10–0.13」；§11「每个可交互控件都提供 `.help()` 与 `.accessibilityLabel()`」。

不在范围：几何契约的 min / recommended / max 尺寸不动；摄像头会话生命周期与懒授权路径（[2026-09-11-permission-lazy-trigger](2026-09-11-permission-lazy-trigger.md)）不动；不新增 token、不改 `DesignTokens.swift`。

## Decision(决策)

1. **块壳归位**：整块套 `BlockCard(hoverEffect: true)`——整块主要命中区就是画面区，悬停微亮与「整块可交互」语义相符（同 QuickButtonBox）。
2. **撤掉标题行**：块内不再有「镜子」标题（`mirror.title` 键随之删除），画面区独占整块内容区。块的识别靠宿主的块显示名与图标，块内不再重复一遍。
3. **控件收进块内右上角悬浮角标**：块内无常驻控件。启停钮 = 组件默认圆形按钮（Kit `IconCircleButton`，直径用默认 22pt，自带悬停增亮 / 手型光标 / help / a11y），由块级 `.overlay(alignment: .topTrailing)` 承载，`.padding(6)` 与宿主编辑角标同一环；`if isHovering` + `.transition(.opacity)` + `Motion.hover` 控制显隐——**整套照 ClipboardHistory 块内角标**（搜索 / 清空角标）抄，不自造外观。
   - 早期一版曾把控件做成"自绘压暗衬底的浮动面板"，v1.2.0 撤掉：块内圆形动作钮的既有标准就是 `IconCircleButton` 裸钮（自带半透明底衬 + 发丝描边 + 阴影），再套一层自绘面板属于"任何落位不得各自重画"的违例。
   - 落位右上角与宿主编辑角标（齿轮 / ✕ / 缩放握把）同环，编辑模式下会被压暗层与 ✕ 盖住——这是既有块（ClipboardHistory）同样如此的行为，且编辑模式本身屏蔽块内容手势，可接受。
4. **整区点击保留**：画面区仍是 `Button`，点画面任意处即启停（README 已记载的行为不变）。它同时是无指针场景的兜底入口——角标只随悬浮出现（`if isHovering` 条件下它不在视图树里，VoiceOver 也拿不到），键盘 / VoiceOver 用户靠整区按钮与 `.help()` / `.accessibilityLabel()` 触达；角标的动作与它同源（`toggleSession`），因此两者谁接到点击结果一致。
5. **状态语义去重**：顶栏不再有第二个入口，`toggleSession()` 由画面区与右上角角标驱动；`isPaused` 不再产生独立可见文案，只用于 help / a11y 文案的「停止 / 继续 / 开始」三态区分。
6. **画面区层级**：底衬改 `Surface.track`(0.08) + `Hairline.thumbnail`(0.12) 描边（`lineWidth: 0.5`），圆角 `Radius.chip`。未启动态因此是一块可见的「取景器」而不是同色空洞；运行中画面覆盖底衬，描边作为取景框留在外圈。未启动态中央常驻「相机图标（22pt light）+ 点击打开镜子（12pt medium）」的引导（`Foreground.muted`）——角标只在悬浮时出现，这条提示是静止态唯一的指路牌。
   卡片壳取 `hoverEffect: false`（同 ClipboardHistory）：悬浮反馈由角标自己给（`IconCircleButton` 的悬停增亮），卡片不必跟着亮。
7. **权限引导态**：标题 11→12 semibold（`secondary`）、说明 9→11（`muted`）、按钮由自绘 `RoundedRectangle(cornerRadius: Radius.thumbnail)` 换成 Kit `RoundedHoverButtonBody` 基体（圆角随之从 4 修正到 `Radius.button` 7，三态 0.07/0.11/0.15、描边 0.10）。内边距统一引 `Space.cardPadding`。
8. **探针收敛为一条**：标题行撤掉后 `camera.header` 不再存在，`mirrorLayoutProbes` 只声明「内容区完整可见」（`camera.preview` = inset 内缩的整个内容区）。`BlockSizeVerifier` 对探针做互不重叠判定，因此不能再为控制面板单列一条探针（面板必然落在画面区内）。
9. **a11y 与本地化**：块级 `.accessibilityElement(children: .contain)` + `.accessibilityLabel(a11y.mirror)`（没有可见标题后这条更要紧）；画面区 `Button` 带 `.help()` 与状态化 `.accessibilityLabel()`；引导按钮带 `.help()`。新增 `mirror.help.start` / `mirror.help.resume` / `mirror.help.stop` / `a11y.mirror` / `gate.openSettings.help`；移除失去引用的 `mirror.title` / `mirror.pause` / `mirror.resume`（en 与 zh-Hans 同步，`LocalizationTests` 校验键集奇偶）。
10. **过渡副本护栏**：画面区 `Button` 加 `.disabled(context.layoutInfo.isPreview)`，滑动切页过渡副本不再能真的启停摄像头会话（配套义务见 [插件开发约定](../../agents/插件开发约定.md)，先例 [`PomodoroBlockViews`](../../../Plugins/PomodoroPlugin/Sources/PomodoroBlockViews.swift)）。权限引导按钮不设护栏：它只弹宿主的权限弹窗，不是单例副作用。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 顶栏保留圆形按钮（`IconCircleButton`）+ 画面区独立入口 | 改动小，保持「顶栏有动作」的既有块惯例 | 未启动态两个反义入口叠加（继续 / 点击预览），状态表达自相矛盾；顶栏挤占本就不多的头部高度 | 否 |
| 控件常驻浮在画面右上角（不随悬浮隐去） | 随时可见、无需寻址 | 运行中常驻遮住一块画面；静止态多一个常驻控件，与「块内只留画面」的定稿相反 | 否 |
| 控件走 Kit `BlockPopover` 长按弹宿主浮窗 | 复用宿主浮窗定位与外观 | 启停是高频动作，长按 0.2s + 浮窗是给设置 / 确认用的重交互，代价与收益倒挂 | 否 |
| 启停钮落在画面区**底边居中**（播放器惯例） | 不与宿主编辑角标争角 | 与「按其他组件标准」相悖：块内圆形动作钮的既有落位就是右上角，自成一套反而更像异类 | 否（曾定为该方案，随后改为右上角角标） |
| 启停钮**自绘压暗衬底的浮动面板** | 面板压得住任意亮度的画面 | 块内圆形钮的标准外观就是 `IconCircleButton` 裸钮（自带底衬 / 描边 / 阴影），自绘面板属"各自重画"违例 | 否（曾被选，v1.2.0 撤销） |
| 画面区只显示、启停仅由角标驱动 | 命中面唯一，杜绝误触 | 角标只在悬浮时存在，键盘 / VoiceOver 与「直接拍一下画面」的直觉路径都没了；且要改 README 与 a11y 文案 | 否 |
| 画面区去掉底衬与描边（只在有画面时存在） | 未启动态最「干净」 | 块退化成「一片同色 + 一块悬停才出现的面板」，看不出画面会出现的位置 | 否 |
| 为控制面板单列一条探针 | 把面板与宿主角标的错位写成可校验约束 | `BlockSizeVerifier` 对探针做**互不重叠**判定，面板必落在画面区内，会直接判错 | 否 |

## Consequences(影响)

- 用户可见：镜子块与其他抽屉块同族；块内不再有标题与常驻控件，静止时只有一面带取景框的画面（未启动态中央是相机图标 +「点击打开镜子」）；悬浮时右上角浮出标准圆形启停钮（与设置齿轮、✕ 移除同一环）；权限引导态字号与按钮观感升级。
- 布局：块内只剩一层，撤掉的标题行 18pt + 间距 6pt 全部还给画面区，`180×140` 下引导态与画面区都更宽松。探针从两条收敛为一条，尺寸等级未动。角标 `padding(6)` 与宿主编辑角标同环，编辑模式下二者重叠（既有块同样如此）。
- 文档：`Plugins/CameraPlugin/README.md` 补充了「块内无标题行、悬浮浮出右上角启停钮」的描述，原「点击块内画面区域开始/停止预览」仍然成立。`DESIGN.md` 与 `DesignTokens.swift` 无新增 / 修改。
- 无迁移成本：不涉及持久化数据与设置项。

## Changelog

- v1.2.0: 启停钮改回**块内右上角悬浮角标**（`IconCircleButton`，照 ClipboardHistory 标准），撤销自绘压暗面板；未启动态中央补相机图标并把文案改为「点击打开镜子」（2026-09-20）。
- v1.1.0: 定稿改为「撤掉标题行 + 控件收进悬停浮出面板（底边居中）」，探针由两条收敛为一条（2026-09-20）。
- v1.0.0: 初版（2026-09-20）。
