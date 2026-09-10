# Agent Note: 抽屉内拖动 —— 被拖块脱离容器渲染

status: implemented
date: 2026-09-10
deciders: 用户（提出"让拖动组件脱离容器"并选定方案 4 / 新实例渲染）+ 实现代理
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

**症状**（用户报告）：抽屉编辑模式下拖动番茄钟页面块（`pomodoro.page`）时，① 不跟手（位移滞后于光标）；② 其它组件会**移位**；③ 拖动中有**闪烁**。空闲态同样发生。

**根因（用户定位，读码确认）**：抽屉的可见面板宽度 = `ui.drawerWindowSize.width`，它在**固定满高满宽的窗口内水平居中**（`DrawerPanelView` 的`.frame(maxWidth: .infinity, alignment: .top)`）。拖动时 `applyPreviewWindowSize`用 `withAnimation(DrawerAnimation.spring)` 改这个宽度，于是：

1. 面板宽度变化 → **绕屏幕中线重新居中** → 面板**左缘**左右移动；
2. 块坐标以**面板左缘**为基准（`DrawerGridGeometry.x(column:)` =
   `(column − leftColumn) × step`）→ 左缘一动，整页块在屏幕上的绝对位置全部平移；
3. 被拖块一边被 `dragOffset` 拉向光标、一边被左缘平移推走，两者方向相反 →
   **反复跳动 + 不跟手**；其它块在这一过程中被反复插值 → **闪烁**。

用户明确要求**保留窗口尺寸动画**（"我希望有动画"），因此"去掉 spring"这条路被排除；也没有窗口锚点机制可用（全项目 `grep anchorPoint` 零命中）。

**已被实测证伪的三个候选根因**（探针读数见 `NOTCHCENTER_DRAG_PERF_LOG`）：
- `GlobalFrameReader` 几何自反馈回路：极限对照（永久停写）下 `bodyPerEvent`
  仍为 3.08，与修复前后完全一致。
- 左扩窗口尺寸动画：`leftExpand=36` 时 `gapMax=45.8ms`，反而比 `leftExpand=0`
  时的 105.0ms 更快；且两次 `widthWrites=0`。
- 推挤 spring 逐帧重启：加动画守卫后 `bodyPerEvent` 仍为 3.04。

**关键实测特征**：`bodyPerEvent` 恒定 3.00–3.13（七次会话方差极小）=**与负载无关的结构性开销**，不是缺陷信号；真正的症状是 `gapAvg` 达标（14–30ms）而 `gapMax` 达 145–488ms 的**偶发长帧**。

**out of scope**：本次只改**抽屉内块重排**这一条拖动路径。紧凑图标重排、分页胶囊拖动排序、设置面板→抽屉的跨窗口拖拽均不动。

## Decision(决策)

**让被拖块在拖动期间脱离容器**：渲染到一个独立无边框 `NSPanel`（`DrawerDragPanel`），原位置的块渲染为 `opacity(0)`；松手后浮窗关闭、块在原位显形。

**为什么这样根治**：浮窗不在抽屉那棵视图树里，因此**不受**面板宽度 spring、面板居中、面板裁切、`ScrollView` 的任何影响。被拖块的屏幕位置 = 按下时的屏幕基准 + 手势 `translation`（纯平移），与面板几何完全解耦 —— 这是唯一从架构上消除"跟随窗口动画"的做法，同时**保留**窗口尺寸动画与推挤动画。

**实现落点**：

- 新增 `Sources/NotchCenter/DrawerDragPanel.swift`：独立无边框 `NSPanel` +
  `NSHostingView`，窗口特征对齐既有 `DragPreviewPanel`（透明、无窗口阴影、`ignoresMouseEvents`、层级 = `popUpMenuWindow + 2`、`animationBehavior = .none`）。阴影画在 SwiftUI 内容上（窗口级阴影会在收场时留下大黑影——既有教训）。
- `DrawerPanelView`：
  - 新增 `@State detachedDrag: (placementID, panel)?` 与 `detachedDragOrigin`；
  - `onDragChanged` 首帧建立浮窗（`beginDetachedDragIfNeeded`），后续帧只
    移动窗口（`moveDetachedDrag`）；
  - `onDragEnded` / 抽屉收起 / 退出编辑 / 切页 四条路径都调 `endDetachedDrag()`
    ——浮窗是独立窗口，**不会**随面板收起自动消失，漏一条就会残留；
  - 块容器 `.opacity` 增加 `detachedDrag?.placementID == element.id` 条件，
    避免"容器内一份 + 浮窗一份"的重影。
- `DrawerActions` 新增 `blockScreenRect: (String) -> CGRect?`：浮窗基准矩形
  由**控制器**经 `DrawerScreenMapper` 提供。视图层不重复实现「格 → 屏幕」换算（那是 `DrawerScreenMapper` 的唯一职责，`DrawerGridGeometryTests`用往返测试钉住其互逆性）。

**内容用新实例渲染**（用户拍板）：浮窗内容取自 `DrawerElement.view`（同一插件视图值），**数据同源**（番茄钟读 `PomodoroStore.shared`、亮度读同一store），故显示与状态一致。已知代价：持有**跨实例私有状态**的插件（如 Notes 的 `NSTextView` 绑定）在浮窗上是"另一份"，拖动中看到的可能不是正在编辑的那个选区。这是明知的取舍，不是遗漏。

**坐标纪律**（本项目最容易写错处，已单测钉住）：基准矩形来自`DrawerScreenMapper.screenRect`（Cocoa，**左下**原点），而 SwiftUI 手势`translation` 是**左上**原点、y 向下。换算规则：
```text
窗口原点.x = 基准.minX + translation.width
窗口原点.y = 基准.maxY − translation.height
```

**明确不做**：不引入窗口 `anchorPoint` 机制（macOS `NSWindow` 无原生支持，自造需接管布局，收益不抵复杂度）；不冻结 `drawerWindowSize`（会让超出部分被裁、失去空间预览）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 被拖块脱离容器（本决策） | 架构上根治；保留全部动画；基建已有（`DragPreviewPanel`/`DragPreviewLanding`） | 浮窗用新实例 → 跨实例状态插件有落差；跨窗口渲染一次性成本 | **采纳** |
| 拖动中左缘锚定 | 一处改动，块基准不动 | 面板偏离中线，松手回正时横移 —— **把抖动从拖动中挪到松手时** | 否 |
| 拖动中补偿偏移 | 被拖块绝对稳定 | 新增渲染偏移量，与 `dragOffset` 叠加、互相掩盖；其它块仍动 | 否 |
| 拖动中冻结面板宽度 | 最简单、面板绝对静止 | 超出部分被裁，失去"将要扩到哪"的预览 | 否 |
| 拖动中禁用左扩 | 掐掉主要触发源 | 治不了右扩（占用列数增加同样触发居中平移） | 否 |
| 只把被拖块移出居中影响（同树内） | 比跨窗口轻 | 被 `pageSlide` 的 `.clipped()` 裁切，拖出边界即消失 | 否 |
| 去掉窗口尺寸 spring | 直击左缘移动 | 用户明确要求保留动画 | 否 |
| 冻结网格基准原点（曾实施） | — | 只管网格列坐标，管不了面板左缘的屏幕平移；**实测无效** | 已回退 |

## Consequences(影响)

- **行为变化**：抽屉内拖动块期间，被拖块由独立浮窗渲染；网格内原位不可见
  （`opacity(0)`，**保留布局占位**，故推挤与落点判定完全不变）。
- **观感**：被拖块不再受面板居中/尺寸 spring 影响，预期消除跳动与不跟手。
  这是本轮**最需要真机确认**的一点。
- **已知代价**：浮窗内容是插件视图的新实例。数据同源的插件（番茄钟、亮度、
  剪贴板、监控）视觉一致；持跨实例私有状态的插件（Notes 编辑器选区/滚动位）可能显示"另一份"。若日后需要严格一致，可在 `BlockLayoutInfo.isPreview`契约上扩展，或改为拖动中隐藏+浮窗只显示静态快照。
- **无 API 变更**：改动均在宿主内部（`Sources/NotchCenter/`），
  `NotchCenterKit` 公开 API 与 `currentVersion` 不动。
- **新增测试**：`DetachedDragGeometryTests`（4 例）钉住坐标系换算与
  `DrawerScreenMapper` 的行号方向 —— y 轴写反会上下镜像且编译器不报错，是本次最关键的单测。另有 `DragPerfCollectorTests`（6 例）保留探针语义。
- **保留的探针**：`NOTCHCENTER_DRAG_PERF_LOG=1`（`DragPerfCollector`）。
  它证伪了三个错误假设，是唯一产出确定结论的工具，故保留（默认关闭、零开销、不改行为）。
- **已回退的改动**：`GlobalFrameReader.isSuspended`（含 3 处调用点）、
  `DrawerPanelView` 推挤 spring 守卫、`DrawerBlockContainer` 动画归属与时序、`PomodoroPageViews` 字号缓存、`NotchPanelController` 左扩计数、`AppDelegate` 合成拖拽探针（从未生效）、`resolveOrigin` 基准冻结。净删除约 280 行无证据改动。
- **测试环境异常（非本次引入）**：`./scripts/build.sh test` 全量只发现并执行
  12 个用例（4 个 suite），而 `Tests/NotchCenterTests/` 下有 60 个测试文件。定向 `-only-testing` 正常。建议单独立项排查，以免门禁长期给假绿灯。
- **方法论留痕**：本问题经历三次**被实测证伪**的错误假设。教训：探针必须
  能证伪 —— 只测"改完是否好一点"无法排除巧合，必须做极限对照与对照实验。

## Changelog

- v1.0.0: 初稿。诊断结论为 `GlobalFrameReader` 几何自反馈回路。
- v1.1.0: 实施记录；用户真实拖拽数据证伪回路假设。
- v2.0.0: 根因更正为推挤 spring 每帧重启（后被证伪）。
- v3.0.0: **根因更正 + 架构改造**。用户定位真因 = 面板宽度 spring 导致面板
  居中、左缘移动、块基准平移；选定"被拖块脱离容器（新实例渲染）"方案。净删除约 280 行无证据改动，新增 `DrawerDragPanel` 与坐标系单测。
