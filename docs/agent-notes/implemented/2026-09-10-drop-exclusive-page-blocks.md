# Agent Note:撤销整页块独占语义，落点偏好改为插件声明

status: implemented
date: 2026-09-10
deciders: 用户（逐题拍板）+ 实现代理
replaces: [2026-09-10-plugin-page-blocks](../implemented/2026-09-10-plugin-page-blocks.md)
superseded-by: <无>

## Context(背景与约束)

- 背景：`2026-09-10-plugin-page-blocks` 引入了 `BlockKind.page`——独占一整个抽屉页、同页禁止共存、恒铺满内容区、不可拖动 / 缩放 / 重排。落地后复盘认为**它违背了"块是灵活组件"的设计原则**：一个插件形态换来了一整套跨引擎的特例。
- 具体代价（读码结论）：独占不变量横切了落点判定、5 处 mutation 守卫、几何归一（`LayoutEnginePages` 212 行）、渲染变体（`DrawerPanelView` 出 `ScrollView`）、宿主占位视图、chrome 规则、以及持久化模型（`PlacedBlock.isPage`）。这些代码
  **全部只服务于"同页不得共存"这一条不变量**。
- 需求重新收敛为：**去掉"整页独占"这层限定，回归统一的网格组件设计**。唯一值得保留的是落点便利——添加时如果当前页已被占用，就为它新开一页，而不是在页里找缝。
- 不做（out of scope）：
  - 不做"整页独占整个抽屉"或"连顶栏一起独占"。
  - 不做存量布局的一次性迁移代码（见 Consequences 的降级口径）。
  - 不改番茄钟页面**内容**（大计时器 / 今日节奏 / 历史复盘）与评分闸门。

## Decision(决策)

### 1 移除 `BlockKind.page`，回归两态

- `BlockKind` 回到 `compact / drawer`；`isExclusivePage` 删除。
- `occupiesDrawerGrid`（`self != .compact`）保留——它本就是"吃不吃格跨换算"的判据，与独占无关，是这次改动后唯一该留下的读取语义。
- `.page` 专属校验（必须声明 `interaction: .expandDrawer`）与 `probes` 豁免一并删除：所有抽屉块回到同一套声明规则，`probes` 恢复**门禁强制**。

### 2 独占机制整体删除

- 删除 `LayoutEnginePages.swift`：`addPageBlock` / `normalizeExclusivePageState` /`normalizeExclusivePageGeometry` / `separateExclusivePageConflicts` /`exclusivePageConflictPages` / `vacantOrNewPage` / `pageBlock` / `isExclusivePage` /`isExclusivePageBlock` / `normalizedExclusivePageSpan`。
- 拆掉 `LayoutEngineMutation` 的 6 处独占守卫（autoPlace / place / moveCrossPage /move / reorder / resize）与 `resizeDrawerBlock` 的整页独立分支。
- 删 `LayoutIssue.pageBlockSharing`。
- 删 `PlacedBlock.isPage` 字段与编解码。
- **净效果**：大组件重新可拖动、可缩放、可跨页搬移、可参与一键重排、可与任意块同页共存。

### 3 落点偏好改为插件声明（非宿主白名单）

新增 `NotchBlock.placement: BlockPlacement = .autoGrid`：

| 档位 | 语义 |
|------|------|
| `.autoGrid`（默认） | 自动寻空位（现行为，`autoPlaceDrawerBlock`） |
| `.newPageWhenOccupied` | 当前页为空则就地占用；否则新开一页；页数达上限且无空页 → 失败并提示「抽屉页已满」，不自动清理任何页 |

- **为什么不写宿主白名单**：宿主目前**没有任何**插件 ID 硬编码，为单一插件开这个口子与本决策"去特例"的目标直接冲突。落点偏好是插件对自己组件的意图，理应由插件声明、宿主执行——与 `QuickAction.defaultInStrip`、`NotchBlock.symbolName` 同构。
- 声明**只影响"添加那一刻"的落点**。落位之后该块无任何限制。
- 新增落点函数极薄：按 `placement` 分派，不做几何归一、不写标记、不参与加载归一。

### 4 渲染回归统一路径

- `DrawerPanelView`：删除整页分支，`pageSlide` **无条件**进宿主 `ScrollView`；所有抽屉块统一走 `BlockCard` + 宿主滚动。
- 删除 `ExclusivePagePlaceholderView` 与 `NotchPanelContent.pagePlaceholderElement`；插件不可用时所有块统一静默跳过（回到 `.drawer` 既有行为）。
- 删除 `DrawerElement.isPage` / `DrawerBlockContainer.isPage` 及其拖动守卫。
- `pomodoro.page` **不再自管滚动**：删根 `ScrollView`，删 `PomodoroPageMetrics.top`这个"给宿主齿轮让位"的特例（普通块的让位由 `BlockCard` 统一处理）。

### 5 版本与兼容口径

- `NotchCenterKitAPI.currentVersion` 1.2.0 → **1.3.0**（保守，不跳 2.0.0）。移除枚举case 对"只用 `== .drawer` 比较"的插件零影响，只影响穷举 `switch` 的插件；与09-07 那次破坏性重做记 minor 的策略一致。
- 存量 `layout.json` 的 `isPage` 键被解码器**忽略**：块就地留在原页原位置，不搬页、不丢块。与原整页块同页的其它块可能短暂重叠，交给既有压实 / 钳制路径在下一次编辑时收敛——不写一次性迁移代码。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 保留 `.page` 但放宽共存 | 改动小 | 独占机制的代码全留着却不再有用途，是更坏的中间态 | 否 |
| 宿主白名单 `pomodoro.page` 走新开页 | 零 API 变更、行为可预期 | 宿主首次硬编码插件 ID，与"去特例"目标冲突 | 否（用户否决） |
| 按 `recommendedSize` 阈值隐式判断大组件 | 零 API 变更 | 规则隐式，插件作者无法预期，等于猜 | 否 |
| 新增落点策略协议 / 闭包 | 表达力最强 | 为单一场景引入协议，过重 | 否 |
| `wantsOwnPage: Bool` | 更短 | 名字描述"意图"而非"动作"，实际语义只是落点 | 否 |
| 插件声明 `BlockPlacement`（采纳） | 声明式、零破坏（有默认值）、与既有先例同构 | 目前只有 `pomodoro.page` 一个使用者 | 是 |
| 存量布局一次性迁移（搬页 / 建新页） | 不出现短暂重叠 | 迁移代码只跑一次却要永久维护；重叠可由既有路径自愈 | 否 |

## Consequences(影响)

- **删除面**：`LayoutEnginePages.swift` 整文件、`ExclusivePagePlaceholderView.swift`整文件、`ExclusivePageBlockTests.swift` 整文件；`LayoutEngineMutation` /`LayoutEngineValidation` / `LayoutModel` / `DrawerPanelView` / `NotchPanelContent` /`DrawerBlockContainer` / `BlockDropTargeting` / `SettingsPages` 各删一处特例。
- **新增面**：`BlockPlacement` 枚举 + `NotchBlock.placement`（带默认值，两个构造器都要加）+ 一个落点函数 + 落点行为测试。
- **行为变更（存量）**：原本是整页块的大组件重新可拖动 / 缩放 / 重排 / 跨页搬移；`drawerElements` 不再有整页特例；插件停用时整页块从"宿主占位视图"退回"静默跳过"。
- **API**：`currentVersion` 1.2.0 → 1.3.0；穷举 `BlockKind` 的插件须删 `case .page`；新增 `placement` 有默认值，不声明即零影响。
- **门禁**：`verify-sizes` 删除 `.page` 分支，恢复"所有 drawer 块强制 probes"；`pomodoro.page` 因此必须补探针声明。
- **保留意见（记录在案）**：`BlockPlacement.newPageWhenOccupied` 目前只有`pomodoro.page` 一个使用者，且有默认值兜底，本质上仍是为单一场景新增的枚举档位。收益/成本比偏薄；若日后仍无第二个使用者，应考虑收紧回 `Bool` 或直接移除。
- 落地后本 note 移入 `docs/agent-notes/implemented/`；被替代的`2026-09-10-plugin-page-blocks.md` 原地标注 `superseded-by`。

## Changelog

- v1.0.0:初稿（撤销 `.page` 独占语义 + 落点偏好改插件声明；Q1–Q6 逐题拍板结论汇总）。
- v1.0.0 落地：宿主侧删除 `LayoutEnginePages` 整文件、`BlockKind.page`、`PlacedBlock.isPage`、`LayoutIssue.pageBlockSharing` 与整页渲染变体；新增 `BlockPlacement` + `NotchBlock.placement`（默认 `.autoGrid`，零破坏）与 `addDrawerBlockOnNewPageIfOccupied` 落点函数。插件侧 `pomodoro.page` 转 `.drawer` + `.newPageWhenOccupied`，不再自管滚动，补声明探针。`verify-sizes` 恢复对全部官方抽屉块强制探针。全量测试通过，文档门禁全绿；本 note 移入 `implemented/`，并在 `2026-09-10-plugin-page-blocks` 标注 `superseded-by`。
