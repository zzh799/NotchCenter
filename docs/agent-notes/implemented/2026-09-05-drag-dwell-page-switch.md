# Agent Note:拖拽驻留分页胶囊自动切页（设置目录 + 抽屉内重排两条路径）

status: implemented
date: 2026-09-05
deciders: zeaven

## Context(背景与约束)

两条拖拽路径都无法把组件/块送到非激活页：设置面板「组件」页拖块进抽屉时落位固定写 `uiState.drawerActivePage`（[BlockDropTargeting.swift](../../../Sources/NotchCenter/BlockDropTargeting.swift) `performBlockDrop`）；抽屉内重排（编辑模式，`DrawerInteractionState` → `applyDrawerDrag`）只在块所在页内移动。需求（真机验收后扩为两条）：拖动中把指针压在顶栏分页胶囊上驻留片刻即切到该页；目录路径松手落在该页网格，抽屉路径被拖块**搬移**到该页（iOS 桌面拖图标到屏幕边缘翻页的同款交互）。

约束：`canSwitchDrawerPage` 明确禁止拖拽进行中切页——落点预览、落位飞行、跨窗口拖拽都按**当前激活页**计算，中途换页会把结果写到错的页上（见 [NotchPanelContent.swift](../../../Sources/NotchCenter/NotchPanelContent.swift) 与 [抽屉分页与滑动切页](../../agents/抽屉分页与滑动切页.md)）。例外必须不破坏这条红线。抽屉路径还有第二道坎：被拖块的手势挂在块容器视图上，切页重建会整屏换掉元素树，手势随视图生死。

Out of scope：快速区路径（紧凑块不进网格，胶囊切页对它无意义，压上胶囊不起计时）。

## Decision(决策)

共用一枚 `CapsuleDwellTimer`（[BlockDragCoordinator.swift](../../../Sources/NotchCenter/BlockDragCoordinator.swift)）：压上非激活页胶囊起 0.5s `Task` 计时，移开/换目标/会话结束即取消；到点用最近指针位置复核仍在同一颗胶囊上才回调。为什么用 Task 计时而不是逐事件判 deadline——驻留=指针**静止**，此时没有任何鼠标事件流入，纯事件驱动永远到不了点。

**目录路径**（自建拖拽会话）：`updatePointer` 每次落点刷新后喂驻留判定；到点回调 `switchDrawerPageForDrag(_:)`——绕过 `canSwitchDrawerPage` 的"拖拽进行中"禁令，但保留展开/编辑入场/菜单追踪/滑动会话守卫，**并保留 `dropPreview == nil` 守卫**：指针压在胶囊行上时 `dropZone` 判 `topBar` 恒无落点、`dropPreview` 已同帧清空，落位仍按切换后的激活页算，不存在错页写入。

**抽屉内重排路径**：`DrawerPanelView.onDragChanged` 末尾喂 `NSEvent.mouseLocation`（手势 translation 只对块局部有意义）；驻留到点回调控制器 `moveDraggedBlockCrossPage`——清落点占位（切页守卫要求 `dropPreview` 为空）→ 引擎 `moveDrawerBlockCrossPage`（**保留 placementID**，插件实例状态键不换；原页摘除并压实，目标页按 `nearestFreeOrigin` 最近可用落位）→ `switchDrawerPageForDrag` 切页。被拖块的 `ForEach` 身份随 placementID 跨页保留，拖拽手势随之续走，松手在目标页内精确落位；若框架重建了视图身份（未观测到），块也已落在目标页、拖拽静默结束——两种结局都符合"移到该页"，不做浮窗交接。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 悬停即切（无驻留时长） | 实现最省 | 快扫过顶栏去网格首行就误翻页，不可控 | 否 |
| B. 系统拖放（NSItemProvider + onDrop）替代自建会话 | 命中测试免费 | 抽屉是无边框穿透 Panel，透明区 drop 无法稳定命中，自建会话正是为此 | 否 |
| C. 胶囊行挂 SwiftUI 手势接收拖拽 | 几何免算 | 跟手浮窗 `ignoresMouseEvents` 不派发事件；事件路由在源窗口，跨窗口手势不通 | 否 |
| D. 探针实测胶囊行真实 frame 替代常量数学 | 布局改动免疫 | 跨 SwiftUI 向控制器回传 frame 的生命周期管理复杂；行几何全由 `DrawerPagePillLayout` 常量派生且已单测钉住 | 否 |
| E. 抽屉路径驻留到点即自动落位、拖拽结束 | 最简单 | 无法在目标页精确选格，需重新抓取 | 否（降级结局保留为框架重建身份时的兜底） |
| F. 抽屉路径驻留到点交接给浮窗（目录式）续拖 | 与目录路径体验完全一致 | 需 isPreview 浮层避免同 placement 双实例绑定（同族事故见领域文档），交接时序复杂 | 否，收益不抵复杂度 |

## Consequences(影响)

- 新增守卫例外是第三条切页通路，领域文档 [抽屉分页与滑动切页](../../agents/抽屉分页与滑动切页.md) 的守卫条目已同步；`canSwitchDrawerPage` 注释补例外指向。
- 引擎新增 `moveDrawerBlockCrossPage`（回归见 `LayoutEngineTests` 跨页搬移三例：身份保留+原页压实、精确落格、同页/未知 ID/不存在页拒绝）；驻留时序回归见 `DrawerInteractionStateTests`（到点回调携带最近拖动目标、无会话/命中激活页不起计时、松手与复位摘除计时）。
- 已知观感：目录路径指针压在胶囊行上时跟手浮窗仍显示"无效"角标（该处确实不收落点），切页本身以高光层 spring 移动为反馈；驻留期间无额外进度指示，如需 iOS 式进度环另立决策。
- 抽屉路径的跨页续走依赖 `ForEach` 身份保留这一框架行为，未观测到破坏；若未来 SwiftUI 版本行为变化，交互退化为"块落到目标页、拖拽结束"，不产生错页或丢块。

## Changelog

- v1:2026-09-05 初稿（仅目录路径，抽屉路径 out of scope）。
- v2:2026-09-05 真机验收后扩范围：补抽屉内重排路径（引擎跨页搬移 + 手势跨页续走），备选方案补 E/F。
- 2026-09-09: 实现已落地 main；治理加固存量清理（D7）git mv 至 implemented。
