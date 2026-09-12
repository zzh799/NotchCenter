# Agent Note: 剪贴板列表惰性化（扁平单 ForEach + LazyVStack）

status: implemented
date: 2026-09-12
deciders: 用户（要求"把剪贴板插件改为使用惰性列表"）+ 实现代理
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

归因已于前序决策记录落定（[2026-09-11-drawer-content-warmth](../implemented/2026-09-11-drawer-content-warmth.md) 的"3. 剪贴板为什么这么贵"）：剪贴板块成本 ≈ **行数 × ~6ms/块/行**（单块 50 行 ≈ 317ms），与正文体积、可见性探针无关，消耗在**逐行视图物化**本身；当时把下一步的杠杆排序写成"惰性物化（`LazyVStack`，需先解决其跨分区复用不重刷的老问题）> 降默认 `displayCount` > 削单行装饰"。本决策只做第一项。

**老问题的真相要先纠正**：`ClipboardHistoryBlockView.historyList` 的原注释断言"`LazyVStack` 会让置顶/解顶跨分区移动时同 id 视图不重刷"，据此一直用非惰性 `VStack`。但原结构是「`LazyVStack` → `ForEach`(节) → 节容器 → `ForEach`(行)」，`LazyVStack` 的**直接子项只有两个"节"**——行藏在节容器内部，压根没进惰性作用范围；而"同 id 在两个 `ForEach` 容器之间搬家"这种身份变更，是这个嵌套结构自己造出来的。所以那条观察只说明"当时的写法既不惰性、身份又含混"，推不出"这个列表不能用 `LazyVStack`"。

**隔离验证**：`Experiments/ClipboardListProbe/`（独立可运行窗口，不参与 Tuist 构建）把两件事放进同一份数据源做 A/B——每行上报"自己实际渲染用的值"，台账与模型逐字段比对，任何不一致（含模型已删除仍在上报的幽灵行）即计冲突。结论：**扁平单 `ForEach` + `LazyVStack` 下跨分区移动零冲突，且已物化行数从"全部"降到"视口内十来行"**；而"节嵌套 + 惰性外容器"写法无论怎么切，物化行数都等于总行数。

**不做**（out of scope）：`displayCount` 档位调整（方案 C）、削逐行装饰（`contextMenu` / a11y，方案 B2）、逐行几何采集改造（方案 B1）、页级内容缓存（方案 E）。本决策只换列表结构；惰性化后逐行装饰只对视口内的十来行生效，那些方案的边际收益已被本决策吃掉大半。

## Decision(决策)

**两处列表都改成"行的扁平序列 + 惰性容器"，行本身保持原样（交互、装饰、锚点逻辑零改动）。**

- **扁平项模型收敛到纯逻辑层**（`ClipboardHistoryLogic.swift`）：新增 `ClipboardSectionKind`（自视图层内私有类型上移）与 `ClipboardListItem`（`.sectionBreak(kind)` / `.entry(entry, section:)`）+ 纯函数 `listItems(pinned:recent:)`。组界只在两节之间出现（首节上方仍无线）。**行身份 = `entry.<uuid>`，与分区无关**——这是"跨分区移动不重刷"的结构性修复：行始终落在同一个 `ForEach` 里，SwiftUI 按 id 复用同一视图并随值重刷内容。组界的 id 走独立前缀 `break.*`，两个 id 空间不混用。
- **抽屉块**（`ClipboardHistoryViews.swift`）：`historyList` 由「`VStack` → `ForEach`(节) → `ClipboardSectionView` → `ForEach`(行)」改为「`LazyVStack` → 单一 `ForEach(items)`」，删除内私有 `ClipboardSection` / `ClipboardSectionView`；组界作为一项渲染（发丝线，`.accessibilityHidden`，与旧的装饰性分隔线一致）。`displayedSections` 相应改为 `displayedItems`，分区、搜索、条数截断语义逐字不动。
- **分组无障碍语义随容器消失**：原先挂在节容器上的 `accessibilityLabel` 改挂到行上（新增键 `drawer.row.a11y`，`"%1$@，%2$@"`），VoiceOver 逐行报"组名 + 正文"——信息不丢，但由"进组容器"变成"逐行前缀"。
- **库页**（`ClipboardLibraryViews.swift`）：最近列表 `VStack` → `LazyVStack`、置顶看板 `HStack` → `LazyHStack`；`sections` 是计算属性而 `body` 原先访问 4 次（每次重跑类型筛选 + 大小写不敏感全库扫描），改为 `body` 内求值一次后作参数下传。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 节嵌套 + 内层 `LazyVStack`（保留节容器） | 无障碍与组界语义零改动，改动面最小 | 外层惰性容器必须知道每个节的高度才能排布后续节 → 强制内层全量测量，惰性拿不到；且"同 id 跨容器搬家"照旧 | **否决**：结构上不成立 |
| B. 扁平单 `ForEach` + `LazyVStack`（本决策） | 行真正惰性；身份稳定；两侧列表共用一套项模型 | 组界与 a11y 语义要重挂；触及列表结构，需回归置顶/解顶与滚动 | **采用** |
| C. 降默认 `displayCount`（50 → 20） | 一行改动、立竿见影 −60% | 用户可见的功能缩水；老实例配置里存着 50，要迁移才生效 | **否决**：用户明确选惰性化，且这是"少给内容"而非"少付成本" |
| D. 削逐行 `contextMenu`（与行尾图标按钮功能重复） | 成本极低、零功能损失 | 不解决物化量；且惰性化后逐行装饰只作用于视口内十来行 | **另立**：留作后续可选增量 |
| E. 逐行几何采集改造（去掉逐行常驻 `GeometryReader`） | 可能顺带修切页/滚动的逐帧重绘 | 长按锚点会错位，需真机核实；不解决物化量 | **另立**：同上 |

## Consequences(影响)

- **收益（静态可断言，运行时待复量）**：单块物化行数由"总行数"降到"视口内行数"（300×240 的块约 6–8 行）。按 ~6ms/行推算，50 行块 ≈ 317ms → **~40–50ms**；页级收益取决于页内有几个剪贴板块。真实降幅必须在 Release + 独占机器 + `NOTCHCENTER_DRAWER_BENCH=uniform|reopen` 下逐页 ×3 取中位复量（验收线沿用"单块 50 行 < 80ms、uniform 12 块页 < 1.2s"），**本轮未做真机复量**。
- **行为变化（唯一一处）**：抽屉列表的分组无障碍由"节容器标签"变为"行标签前缀"；视觉上组界发丝线的位置与间距与旧版逐字一致（`Group` 对栈布局透明，旧结构下分隔线本就在同一间距序列里）。
- **保守的地方**：行视图本体（`blockPopoverTrigger` 的逐行几何追踪、`contextMenu`、a11y 标签、圆角背景描边）一概不动——交互与长按锚点行为零风险变化。
- **回归面**：置顶/解顶跨分区（本决策的主场景）、搜索过滤切换、清空未置顶、`displayCount` 档位、库页类型筛选 + 搜索双条件。逻辑侧由 `ClipboardLibraryTests` 新增用例覆盖（保序、id 唯一、id 跨分区不变、组界只出现在两节之间）。
- **文档**：`docs/agents/面板与抽屉.md` 的「展开成本结构」一节需改写剪贴板段落（旧文写着"改惰性前先解决那个复用问题"，该问题已定位为结构误用并修复）。
- **构建注意**：改完插件必须确认 `.app` 里的插件 bundle 真的换了（详见 `docs/agents/面板与抽屉.md` 的 worktree/构建一节），否则复量会读到"宿主新、插件旧"的假象。

## Changelog

- v1:2026-09-12 首版：扁平项模型 + 两侧列表惰性化；备选 A 因结构上拿不到惰性否决，C 因用户选定而否决，D/E 另立。
