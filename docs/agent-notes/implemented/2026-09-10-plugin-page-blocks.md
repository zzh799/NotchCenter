# Agent Note:整页块（BlockKind.page）与番茄钟页面化

status: implemented
date: 2026-09-10
deciders: 用户（逐题拍板）+ 实现代理
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 需求：插件页面——插件提供一个页面，添加到面板后**完全使用当前抽屉页**，同页不得再有其它组件；但页面主体仍保留与普通组件相同的左上角设置与右下角拖拉。
- 现状约束（读码结论）：`BlockKind` 只有 `.compact` / `.drawer`；抽屉"页"抽象（`LayoutModel.drawerPages` + `PlacedBlock.page`）已存在；左上齿轮 / 右上 ✕ / 右下握把**全部由宿主的 `DrawerBlockContainer` 叠上去**，且只在"编辑模式 + 悬停"出现；`LayoutEngine` 的自动投放 / 移动 / 缩放一律假设同页可多块。
- 不做（out of scope）：
  - **不做可交互活动摘要通道**。`ActivitySummary` 是纯只读数据、`HostController` 无"请用户回答"入口，"收起态直接评分"是另一个大特性。
  - 不做"整页独占整个抽屉"或"连顶栏一起独占"。顶栏（紧凑带 + 分页胶囊）仍归宿主。
  - 不做整页块的跨窗口拖入落位（拖拽语义是"落到网格某格"，整页没有位置）。

## Decision(决策)

### 1 表示法与语义

- `BlockKind` 新增 `.page`（枚举而非布尔标志：`compact / drawer 网格 / 独占整页`是三选一，编译器强制处理新分支）。
- **页边界 = 一个抽屉页的内容区**；页面 = "只允许放一个、且禁止再加别的块的抽屉页"。顶栏与分页胶囊照旧。
- 不变量：**同页不得出现"整页块 + 其它块"**。整页块恒为 `originColumn = 0 / originRow = 0`，其列跨度夹在 `[minimumColumnCount(), effectiveMaxColumns()]`，因此它正好铺满该页内容区（面板宽 = `occupiedColumns` 由它单独决定）。

### 2 添加规则（当前页空则就地占用，否则新开一页）

- 空页就地占用；当前页非空或已是整页页 → 新开一页（`addDrawerPage(.right)`）；页数已达 `maxDrawerPageCount`（9）且无空页 → **失败并提示，不自动清理**。
- 页面**不参与首启自动投放**（`seedDefaultLayout` 只认 `.drawer`，天然排除）。
- 目录：混入插件现有 `drawerItems`（不新增分区，不支持拖入落位）。
- 允许同一整页块多实例（各自独立 `placementID` / 设置 / 持久化）。

### 3 尺寸与表面

- 复用网格格跨：尺寸走 `sizeBox` 三档 + 现成的握把 resize 路径（`DrawerBlockContainer → DrawerInteractionState → resizeDrawerBlock`），零新几何代码；**不突破 `effectiveMaxColumns()`**（不给整页开后门）。
- `minSize` 是"拖拽下限"，**不是运行时保证**：屏幕高度封顶时面板会被压到 `minSize` 以下。
- 表面满血：不套 `BlockCard`、**排除出抽屉自身的 `ScrollView`**、背景与内部滚动由插件自管；编辑模式的压暗层与描边仍由宿主叠（与"编辑角标任何落位不得各自重画"一致）。
- 编辑 chrome 规则（本次一并推广到**所有抽屉块**）：**设置齿轮只要块有设置视图，悬停即出现，不再要求编辑模式**；✕ 与握把仍归"编辑模式 + 悬停"。
- 整页块 ✕ 的语义 = **把组件从这页移除、页面留空**（与普通块 ✕ 严格一致）；删页仍走分页胶囊的页面设置。

### 4 拖拽与重排封禁

- 整页块不可拖动、不参与一键重排、不可跨页搬移。
- 任何块拖不进"整页页"：落点判定层由引擎守卫拒收（`placeDrawerBlock` / `autoPlaceDrawerBlock` / `moveDrawerBlockCrossPage` 三处），不依赖视图层。
- 整页块换页顺序仍走分页胶囊的拖排。

### 5 异常态

- 插件不可用（停用 / 卸载）时，整页块渲染**宿主占位视图**（"该插件已停用"）；普通块维持现状的静默跳过。
- 为在插件不可解析时仍能识别整页页，`PlacedBlock` 增加持久化标记 `isPage`；插件可解析时**以插件声明为真源**并在加载 / 启用集变化时回写该标记（防漂移）。
- 非法共存（插件把某块 `kind` 从 `.drawer` 改成 `.page`、或手改 `layout.json`）→ **整页块自己搬到新页，普通块原地不动**（无损；无新页则丢整页块）。

### 6 对外 API

- `BlockKind` 新增 case 对"穷举 `switch` 的第三方插件"是源码级破坏，对"只用 `== .drawer` 比较"的插件零影响。
- `NotchCenterKitAPI.currentVersion` bump 到 **1.2.0**；`docs/api-changelog/NotchBlock.md` 记 `added` 并附一行迁移提示。
- **`currentVersion` 自此为版本唯一真源**：changelog 条目改标对应 `currentVersion` 值，回改 2026-09-07 两条口号式的 `v2.0.0`。
- 整页块的 `probes` **豁免**（遮挡校验的前提是"同页还有别的块"，整页独占没有这个前提）；`interaction` 对 `.page` 无意义，声明 `.custom` 即校验报错。`layoutInfo.region` 沿用 `.drawer`，`frame` = 内容可视区，`isPreview` 沿用现有契约。

### 7 番茄钟整页形态（首个使用者，也是唯一活样例）

- 新增 `pomodoro.page`（整页），min 300×240 / recommended 600×360 / max 900×600；`pomodoro.timer` 抽屉块**保留**（小控制卡与整页是两种形态）。
- 内容 = 大计时器 + 今日节奏 + 历史复盘（含微休息效果对照）。页面承载"计时 + 今日记录 + 最高频时长调整"；`PomodoroSettingsView` 保留全部配置，页面不新增第二份设置 UI。

### 8 番茄钟数据层重做

- 旧 `PomodoroStats`（单条 `{day, completed}`）被**明细**取代：每段专注一条 `PomodoroFocusSession`（起止 / 计划时长 / 结果 / 1–5 情绪评分 / 微休息 id 列表），每条微休息一条 `PomodoroMicroBreak`（起止 / 计划时长 / 结束方式）。
- 旧键迁移：落成"那一天的一条日汇总兜底"（`dailyFallbacks`），**不伪造** N 条无评分明细，不丢弃。
- 保留全量（不按天裁剪），硬上限 **20000 条**（约两年半），超出丢最旧并在页面底部标注。
- 微休息复盘口径：**事实 + 关联对照**（"有微休息的专注 vs 无微休息的专注"平均情绪分 / 完成率），页面明确标注为相关性而非因果。

### 9 评分交互

- 评分入口：**整页顶部评分条 + 抽屉块整块替换**（`pomodoro.timer` 在待评分态整块变成评分版式，复用空闲态同款骨架，**不新增第五行 → 不动 `minSize`**，存量 300×120 放置不非法）。评分期间抽屉块**不给**任何计时控制。
- **不可跳过、不可补评**：评分条只有"打分"与"删除本次记录"两个出口。
- **阻塞式闸门**：有待评分时禁止开始下一个专注（`start()` 被挡并把注意力引到评分条，不弹窗）。为此引擎新增阶段 `.awaitingRating`：`rest` 结束仍未评 → 进入该阶段（冻结、不计时、进度条恒满）；该阶段 `skip()` 禁止、`stop()` 允许。
- 评分提示在 `focusCompleted` 那一刻就创建，用户在整个休息期间都能评。
- 只有"自然完成"的专注触发评分；手动跳过的专注不评分，只落一条 `outcome: skipped` 记录入库。
- 删除待评分记录 = 删除该会话 + 它的全部微休息记录，"今日完成数"随之减少（完成数从此由明细推导，不再有独立计数器）。
- **可达性兜底 = 被动自愈（Q16-B）**：待评分记录超过 **60 分钟**未处理即自动作废（记录丢弃）并恢复计时。已知代价：用户完全没放任何载体（无 `pomodoro.timer`、无整页）时，评分无处可达，番茄钟最坏被冻结 60 分钟后自愈。审阅者注意：这是明知的取舍，不是遗漏。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 页边界 = 整个抽屉（所有页） | 语义更霸道 | 需发明状态机处理"已有页怎么收敛 / 胶囊藏不藏 / 删页后旧页是否回来" | 否 |
| 页边界 = 整个 notch 面板（含顶栏） | 插件自由画一切 | 与"页面主体仍有左上设置"冲突，最易退化成从 0 重写 | 否 |
| 整页拖拽只改高度、宽度恒满列 | 最省 | 砍掉需求明写的"右下拖拉" | 否 |
| 真像素宽度（面板宽不再由列数推导） | 页面能真"宽" | `DrawerGridGeometry` / 渲染左列 / 滑动切页 / 胶囊定位全建立"宽 = 列数 × step"上，动一批已验证路径 | 否 |
| 右上 ✕ = 删整页 | 少一次点击 | 与普通块 ✕ 长一样但后果不同，且与胶囊的页面设置语义重叠 | 否（✕ = 移除块、页面留空） |
| 设置齿轮也只在编辑模式出现 | 文档零特例 | 整页应用的设置要走两步，反直觉 | 否（推广为"有设置即悬停显示"） |
| 页面套 `BlockCard` | 视觉统一零新增 | 把整页应用锁死在"卡片 + 宿主滚动"里 | 否 |
| 整页块 = 插件声明的普通块（不新增 kind） | 零 API 变更 | 无法表达"禁止同页共存"这个**不变量**，只能靠约定 | 否 |
| 待评分队列（从旧到新依次评） | 不丢样本 | 离开几小时回来连点 N 次；事后回忆打分数据质量极差 | 否 |
| 待评分单挂 + 自动关闭为"未评分" | 保住完成数 | 与"不可跳过"的精神冲突 | 否（改为超时作废） |
| 活动摘要 / 设置窗口承载评分条 | 可达性最好 | 摘要只读、设置窗口方案被用户否掉（Q16 选 B） | 否 |

## Consequences(影响)

- **存量行为变更**：`DrawerBlockContainer` 的齿轮显隐条件放宽为"有设置 + 悬停"（不再要求编辑模式），所有抽屉块的非编辑态悬停都会浮出齿轮。牵连 chrome 相关回归测试（`BlockCardTriggerTests` 等）。
- **持久化模型**：`PlacedBlock` 增 `isPage`（`decodeIfPresent ?? false`，旧 `layout.json` 向后兼容）。
- **API**：`NotchCenterKitAPI.currentVersion` 1.1.0 → 1.2.0；穷举 `BlockKind` 的插件须补 `.page` 分支。
- **插件侧**：`PomodoroStats` 键被 `history` 键取代，旧 `stats` 只读迁移一次；`Plugins/PomodoroPlugin/README.md` 需更新数据说明。
- **新门禁分支**：`verify-sizes` 对 `.page` 豁免 `probes`；`probes` 的"越界 = 溢出邻居"论证对整页不成立。
- 落地后本 note 移入 `docs/agent-notes/implemented/`。

## Changelog

- v1.0.0:初稿（整页块能力 + 番茄钟页面化 + 数据层重做；Q1–Q16 逐题拍板结论汇总）。
- v1.0.0 落地：宿主侧 `BlockKind.page` + `LayoutEnginePages` 独占守卫 + `PlacedBlock.isPage` 回落标记 + 满血渲染变体 + chrome 齿轮放宽 + `LayoutIssue.pageBlockSharing`；插件侧 `pomodoro.page` 整页视图、评分条（`.awaitingRating` 闸门 + 60 分钟自愈）、`PomodoroHistory` 明细档（全量 + 20000 上限 + 旧 `stats` 迁移）。全量测试 622 例通过；`verify-sizes` 新增 `.page` 分支。本 note 移入 `implemented/`。
