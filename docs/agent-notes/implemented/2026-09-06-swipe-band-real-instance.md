# Agent Note: 滑动切页改真实例页带,根治落位闪烁

status: implemented
date: 2026-09-06
deciders: 用户（调研后拍板实施；isPreview 契约暂留、清理另行 PR）

## Context(背景与约束)

滑页切页落位后暂存区与系统监控闪一下:滑动中的"预览"并非截图,而是 `buildDrawerElements(page:isPreview: true)` 重新 makeView 的独立实例;`landDrawerSwipe` 落位时整体重建 `drawerElements` 为缓存真实例——预览实例与真实例是两套视图身份,SwiftUI 结构位不同必整批重挂:暂存区缩略图 `@State` 归零回退文件图标再异步加载、监控重挂探针/视图。视图缓存命中救不了(同一 AnyView 值换个结构位照样重挂)。out of scope:胶囊点击切页路径(直接跳页,重挂是既有接受行为)、`isPreview` 契约与五个插件守卫分支的删除(暂留,真机确认后另行 PR)。

## Decision(决策)

两条腿:**① 滑动层用真实例**——`beginDrawerSwipe`/换绑改 `isPreview: false` 构建,走正常缓存键并回写 `drawerViewCache`,插件副作用(监控采样、缩略图加载、DDC 枚举、Notes 绑定编辑器)在滑动期间预热,落位即就绪;**② 单一常驻页带**——`DrawerPanelView.pageSlide` 弃"网格层 + 预览层"两层 ZStack,改单容器单 ForEach(`bandItems` = 稳态 `drawerElements` + 未落位时叠加 `swipe.elements`,按元素来源注入渲染几何与条带位移,目标页 `isInteractive: false`)。落位拍 `drawerElements := session.elements`(同 id 同值)+ 置位 `isLanded` 停会话贡献:目标页子视图在同一 ForEach 里身份保持、原点页在视口外卸载,落位零重挂载;回弹目标页滑出视口后随会话清除卸载,原点页全程未动。`landDrawerSwipe` 不再调 `buildDrawerElements`,随后的 `rebuildContentAfterPageChange` 按缓存键复用同一批视图值(会话构建时已回写,键逐项相等——`layoutEngine.frame(for:)` 是绝对列坐标与页无关,已核)。实现落点:`Sources/NotchCenter/NotchPanelContent.swift`、`DrawerPanelView.swift`(previewGrid/previewBlock/grid 三段删除,新增 DrawerBandItem/bandItems/bandBlockContainer,blockContainer 增 `in renderGeometry` 参数)、`PanelUIState.swift`/`DrawerPageSwipe.swift` 注释。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 落位后延迟几帧撤预览层垫底挡空帧 | 一天工期,宿主单点 | 挡不住"内容错误"型闪烁(缩略图回退图标是不透明错误内容);两套实例的时序债照旧 | 否决,止痛不治本 |
| 预览实例落位 promote 为真实例 | 不改滑动期 | `layoutInfo.isPreview` 是 makeView 时冻结的值,写通道守卫(媒体命令/DDC)运行时读旧值拦着;生命周期登记(onAppear 已带着 isPreview 跑过)无法补跑,等于要给 BlockContext 加激活机制 | 否决,比现状更伤 |
| 滑动中显示位图快照 | 滑动期最轻 | 落位照样重挂,闪烁原样;位图与实时内容有落差 | 否决 |

## Consequences(影响)

行为变化:目标页真实例副作用提前到滑动开始,若用户取消走 onDisappear 正常回滚(注册/注销、探针挂拆、定时器启停);Notes 编辑器绑定/恢复选区提前,滑动中可能抢第一响应者——真机验证项。防线保留:会话期页带两条 `.animation(value:)` 仍为 nil、条带宽冻结会话起点值、落位帧非动画、`isLanded`/兜底时钟幂等守卫不变;`rebind` 仍整层重建(视口外不可见)。`isPreview` 成为死契约暂留,文档(抽屉分页与滑动切页/面板与抽屉/插件开发约定)已标注状态;LocalizationTests 无涉,全量测试 524 用例通过。

## Changelog

- 2026-09-06: 创建,记录真实例页带改造共识与实施。
