# HANDOFF — 组件尺寸三档模型改造(物理像素版)

> 交接时间:2026-09-07 22:20 (GMT+8)
> 交接人:上一会话(agent)。本文件是**唯一续接入口**——新会话先读本文件,再决定下一步。
> 工作区:`/Users/zhouzihang/Projects/Ai/NotchNotes`(macOS NotchCenter 插件宿主)。

---

## 1. 一页摘要(新会话先看这里)

任务:修改宿主对**组件(drawer 抽屉块)尺寸的限制方式**,取消旧的"标定离散档位"模型。

**用户最终拍板的模型(重要,别再做回格跨模型):**

- 每个抽屉块声明**三档物理像素尺寸**:`minSize / maxSize / recommendedSize`(单位 pt,`BlockPixelSize`)。
- `minSize` 的**全局下限是 75×60 pt**(`NotchBlock.globalMinimumPixel`)。
- 宿主按**当前用户格子尺寸(每格宽/高,不含 spacing)**把三档换算成"允许的格跨盒",再用于:新块落位用推荐档、拖拽缩放钳制在 `[minSpan…maxSpan]`。
- **组件像素不含格间间距 spacing**:换算公式 = 物理 ÷ 单格尺寸(不是 `n×cell + (n−1)×spacing`)。用户确认过这一点。
- 换算规则(用户已确认):min → **向上取整**使物理≥min;max → **向下取整**使物理≤max(至少 1 格);recommended → **就近取整**并夹进 `[min…max]` 换算盒。
- 用户调大格子导致 1×1 都超 max(量化不可表示):**1×1 兜底显示**;已摆放的块照常显示,不打断布局,再次拖拽时按新边界钳制。
- 存量官方插件迁移:旧跨度 × 默认格 150/120 → 像素(如旧 2×2 → 300×240)。

**当前状态:** Kit API 硬切完成、12 个官方插件已迁移、引擎/UI/测试全部适配,**557 个测试全绿(546 基线 + 本会话新增 10 例校验判定单测 + 1 例遮挡校验门禁;实测 `./scripts/build.sh test`)**。测试命令 `./scripts/build.sh test`。

**本会话已完成(2026-09-07 续接):**

- **Task A(打包期遮挡校验)已实现**:Kit 新增 `BlockProbe` / `NotchBlock.probes`(可选)/
  `BlockSizeVerifier`(纯几何);11 个官方插件 15 个 drawer 块全员声明探针;门禁
  `BlockSizeVerifierTests`(10 例)+ `BlockMinSizeVerificationTests`;`build.sh verify-sizes`
  子命令;`package` 默认预检(`--skip-size-check` 逃生)。详见 Agent Note
  `docs/agent-notes/implemented/2026-09-07-block-min-size-occlusion-verification.md`。
- **Task B(文档同步)已完成**:架构设计文档 §4.2/§5.3/文件树/属性表、插件开发指南 §3 尺寸
  (+探针写作规范)、宿主开发约定代码地图、布局引擎与网格首节,全部改为像素三档模型;
  两篇历史 implemented note 追加"修订"注记(史实保留);新增 implemented note
  `2026-09-07-block-size-pixel-three-tier`(像素三档决策)与
  `2026-09-07-block-min-size-occlusion-verification`;api-changelog 登记 `NotchBlock.md`。
- **Task C 待收尾**:见 §6。

**还没做:** 见 §6 Task C(git commit 收尾)。

---

## 2. 为什么有这次改造(背景)

原需求(2026-09-07 会话):

> 修改本软件对组件尺寸的限制方式,取消原来标定的方式。每个组件提供最小尺寸、最大尺寸、推荐尺寸。最小尺寸的最小尺寸是 75×60。本软件会优先按推荐尺寸显示,用户不得将组件尺寸拖拽缩小到小于最小尺寸,或大于最大尺寸。另外,在插件打包时,需要校验插件组件在最小尺寸下是不是会发生遮挡。

**关键纠偏**(中途用户指出,导致推翻"格跨三档"初版):

> 似乎有误区,我所说的最小尺寸、最大尺寸是以像素为单位。这样子,不管用户如何修改布局中的单元大小都能够适应。

即:组件声明的是**物理像素区间**,宿主实时换算格跨——用户把格子从 75×60 调到 280×240,组件物理尺寸仍落在声明区间内。

---

## 3. 新旧模型对照

| 维度 | 旧模型(已废弃) | 新模型(当前实现) |
|---|---|---|
| 声明单位 | 离散档位(BlockSize 枚举 / supportedSizes) | 物理像素 `BlockPixelSize(width:height:)` |
| 三档 | 枚举预设 | `minSize/maxSize/recommendedSize` 三档 pt |
| 组件允许的"尺寸集合" | 离散格跨目录 | 像素矩形盒 → 按当前格子换算成连续格跨盒 `[min…max]` |
| 全局下限 | (无物理概念) | 75×60 pt = `NotchBlock.globalMinimumPixel` |
| 拖拽钳制 | 只允许目录中的格跨 | 盒内任意整数跨,盒外拒绝/钳回(手势层钳制 + 引擎提交闸门) |
| 遮挡校验(打包期) | 未实现 | **未实现**,待做(Task 5) |

---

## 4. 已完成的代码改动(全部未提交,工作区 36 个文件)

核心改动都在工作区。**尚未 git commit**。上一基线 commit:`fa08d98`(块尺寸对照实验室)。

### 4.1 Kit(`Sources/NotchCenterKit/NotchBlock.swift`)— 尺寸 API 唯一真源

- 删:`BlockSize` 枚举、`supportedSizes/supportedGridSpans/defaultSize`、按格跨的 `allows/clamping`。
- 增:`BlockPixelSize`(Hashable/Codable/Sendable,含 `size: CGSize` 便捷)、`NotchBlock.globalMinimumPixel = 75×60`。
- `NotchBlock` 三档字段:`public let minSize/maxSize/recommendedSize: BlockPixelSize?`(compact 恒 nil)。
- 校验 `validationError`:drawer 必须三档齐全、逐轴 `min ≤ recommended ≤ max`、min ≥ 75×60;compact 不得声明三档。
- **换算核心(新会话重点,勿改语义,除非用户再拍板):**
  - `sizeBox(cellWidth:cellHeight:) -> (min: GridSpan, max: GridSpan, recommended: GridSpan)?`(compact 返回 nil);
  - `axisSpan(minPixel:maxPixel:recommendedPixel:cell:)`:min=ceil(px/cell) 至少1;max=floor(px/cell) 至少1;max 不足 min 时以 min 兜底;recommended=round 夹进 [min…max]。
  - `allows(_:cellWidth:cellHeight:)` / `clamping(_:cellWidth:cellHeight:)`:按**当前格子**换算后判断/钳制。
- `GridSpan` 保留(布局/引擎层仍用格跨),`GridSpan.globalMinimum = 1×1` 保留作无声明兜底。
- 注意:换算**不含 spacing**(组件像素=格子之和,用户确认)。`GridMetrics.width(columns:)` 仍含间距,那是宿主渲染几何,与组件声明语义分离。

### 4.2 宿主(NotchCenter)

- `LayoutEngineMutation.swift`:`autoPlaceDrawerBlock / placeDrawerBlock` 落位跨度改为 `block.sizeBox(...)?.recommended`,新增默认参数 `cellWidth/cellHeight = NotchGridMetrics.cellWidth/.cellHeight`(引擎不依赖 UI,直接读 store 转发);`resizeDrawerBlock` 守卫改 `definition.allows(span, cellWidth:cellHeight:)`。
- `LayoutEngineArrangement.swift`:`previewArrangement(resizing:)` 守卫同样改 allows(带 cell)。
- `LayoutEngine.swift / LayoutEngineValidation.swift`:移除 `sizeNotSupported` 相关 issue/校验(存量盒外跨度照显,不视为损坏——首次拖拽即被钳回)。
- `DrawerGestureMath.swift` / `DrawerInteractionState.swift` / `DrawerPanelView.swift`:`DrawerElement` 的 `minSize/maxSize` 字段**语义变为"当前格子换算出的允许格跨盒"**(类型仍是 GridSpan);`ResizeSpanResolver.resolve` 现在钳进 `[min…max]` 盒,不再有 legacy 上界。手势层不做像素换算——换算在元素构建处一次完成。
- `NotchPanelContent.swift`:构建 `DrawerElement` 时用 `GridMetrics.current` 调 `block.sizeBox(cellWidth:cellHeight:)` 得到盒的 min/max 传入。
- `SettingsPages.swift`:`preferredSpan(for:)` 改为像素 → 当前格子换算推荐档;目录卡尺寸同前。
- `AppDelegate.swift`:探针处同样换算。
- `BlockContext.swift`:`BlockLayoutInfo.size` 保持 `GridSpan?`(运行时真实跨度,不改语义)。

### 4.3 12 个官方插件(Plugins/*)

所有 drawer 块声明从 `GridSpan` 三档迁移为 `BlockPixelSize` 三档 = 旧跨度 × 150/120:
- 例:MediaControls `2×2/4×2/2×2` → `300×240 / 600×240 / 300×240`;NotesPlugin `2×2/4×4/4×2` → `300×240/600×480/600×240`;Scratchpad `1×1/4×4/2×2` → `150×120/600×480/300×240`。
- 插件内部消费 `BlockLayoutInfo.widthColumns/heightRows/frame.size` 做版式适配——**这些运行时字段没变**,所以插件 UI 逻辑零改动;只改了声明与个别 `size:` 参数调用(见 git diff)。

### 4.4 测试(全部已适配,546 绿)

- 测试夹具新增默认格常量 `fixtureCellWidth=150/fixtureCellHeight=120`,`fixtureBox` 返回 **BlockPixelSize 三档**(=旧档跨度 × 150/120),便于引擎在默认格下换算回相同格跨、旧断言不破。
- `LayoutEngineTests`:验证规则/钳制重写为像素断言;新增 3 个换算单测:
  - `testPixelBoxConversionAtVariousCellSizes`(默认/最小/最大格三档换算);
  - `testPixelBoxCollapsesToGlobalMinimumWhenCellExceedsMax`(1×1 兜底);
  - `testPixelBoxRecommendedAlwaysInsideDeclaredBox`(推荐夹紧不变式,多组格子遍历)。
- `SystemMonitorTests`/`DisplayPluginTests` 等改像素断言。

---

## 5. 如何验证(新会话照做)

```bash
cd /Users/zhouzihang/Projects/Ai/NotchNotes
./scripts/build.sh dev debug     # 宿主+插件编译
./scripts/build.sh test          # 全量测试(当前 546 tests, 0 failures)
```

注意一个**既有脆性测试**(与本次改动无关):`DisplayPluginTests.testConsecutiveWriteFailuresHideRow` 全量并行负载下偶发超时,单独跑必过;若全量偶挂,单独复验该用例区分"并行抖动 vs 真回归"。

---

## 6. 未完成事项(新会话的 TODO)

### Task A — 打包期遮挡校验 ✅ 已完成(2026-09-07 本会话)

原始需求第 5 句已落地,设计决策与最终机制见 implemented note
`docs/agent-notes/implemented/2026-09-07-block-min-size-occlusion-verification.md`。
**机制与初版草稿的差异(重要)**:最终采用**声明式几何探针 + 纯几何校验**,未做渲染实测——
探针由插件用与视图同一套布局常量推导"关键区必须完整可见"矩形,校验器按 minSize 内容盒做
越界/自叠纯几何判定(tolerance 0.5)。渲染读回(打 a11y 标 + 读真实 frame)留作后续增强,
理由见 note 的 Alternatives 表(B/C/D 方案)。

落地物:Kit(`BlockProbe`/`NotchBlock.probes`/`BlockSizeVerifier`)→ 11 个官方插件 15 个
drawer 块全员探针 → `BlockSizeVerifierTests`(10 例)+ `BlockMinSizeVerificationTests` →
`build.sh verify-sizes` + `package` 预检(`--skip-size-check`)。

### Task B — 文档同步 ✅ 已完成(2026-09-07 本会话)

- 架构设计文档 §4.2/§5.3/文件树/§5.5 缩放句/属性表行 8、26 → 像素三档 + probes;紧凑尺寸改中性表述。
- 插件开发指南 §3「尺寸」→ 像素三档 +「打包期最小尺寸遮挡校验(probes)」写作规范。
- 宿主开发约定代码地图 Kit 条目;布局引擎与网格首节 + 迟滞措辞(档位→格)。
- 历史 note 两篇追加「修订(2026-09-07,像素三档模型)」,史实保留。
- 新增 implemented:`2026-09-07-block-size-pixel-three-tier`(像素三档决策);
  occlusion note 自 proposed 迁入 implemented。
- api-changelog 新增 `docs/api-changelog/NotchBlock.md`(v2.0.0 破坏 + added 两条)。
- 门禁:`./scripts/run-doc-checks.sh` 6 PASS / 1 FAIL(仅 AGENTS.md 预算,已知既有,勿擅动)。
- 注意换行纪律:markdown 段落/列表项须单行(verify-md-wrap 强制),新增/修改 md 后先跑门禁。

### Task C — 收尾(本会话进行中)

- 全量测试复验通过(557 绿,`./scripts/build.sh test` exit 0);文档门禁 6 PASS/1 FAIL
  (仅 AGENTS 预算,已知既有)。按逻辑拆 commit:
  1. Kit + 宿主(引擎/UI/手势):像素三档 + 遮挡校验 API(含 `scripts/build.sh` 的
     verify-sizes/package 预检接线);
  2. 官方插件:像素三档迁移 + 探针声明(Plugins/**);
  3. 测试适配与新增(Tests/**);
  4. 文档同步 + agent notes + api-changelog + HANDOFF.md(docs/** 等)。
- 已知既有门禁失败(与本任务无关,HEAD 即如此):`AGENTS.md` 1904 字符 > 上限 1900。不在本次
  任务范围内,勿擅动;若要恢复全绿需压缩 ≥4 字符并经 PR 说明。

---

## 7. 仓库纪律速查(动代码前必读)

- `AGENTS.md` 是常驻指令(项目根),上限 1900 字符,改前看 `docs/agents/` 分域子文档:
  - 引擎/布局:先读 `docs/agents/布局引擎与网格.md` 与 `docs/agents/宿主开发约定.md`;
  - 涉及抽屉手势:`docs/agents/抽屉分页与滑动切页.md`、`docs/agents/面板与抽屉.md`;
  - 测试纪律:`docs/agents/测试指南.md`。
- UI 遵循 `docs/DESIGN.md`;术语纪律 `docs/TERMINOLOGY.md`(目前无禁用词)。
- 构建真源 `Project.swift` + `scripts/build.sh`;插件登记处 `Plugins/<Name>/Plugin.plist`(改插件依赖白名单在 Project.swift `knownExtraDependencies`)。
- Swift 6 严格并发 / macOS 15+ / Tuist;宿主 `@MainActor`;纯算法剥出来单测(见 `DrawerGestureMath` 的注释风格)。
- 改动引擎推挤逻辑前必读 `DragReorderReproTests`(有 AGENTS.md 级保护注释)。

---

## 8. 关键决策记录(如需回看)

| 决策点 | 结论 |
|---|---|
| 三档单位 | 物理像素 pt(用户纠偏,推翻格跨) |
| 换算公式 | min ceil / max floor(≥1) / recommended round 夹紧;每轴独立;px ÷ 单格尺寸 |
| spacing 归属 | 不含,组件像素 = 格子之和(用户确认) |
| 用户调大格子致 1×1 超 max | 1×1 兜底显示;存量块不动;再拖按新边界钳制(用户确认) |
| 官方插件迁移 | 旧跨度 × 默认格 150/120 → 像素(用户确认) |
| 引擎拿格子尺寸 | 读 `NotchGridMetrics.cellWidth/.cellHeight`(store 转发,非隔离单例) |
| 换算发生时机 | 元素构建/落位/守卫处实时换算,不缓存进 PlacedBlock(存布局仍是格跨) |
| 全局像素下限 | 75×60 = `NotchBlock.globalMinimumPixel`(= 最小格 75×60,自洽) |
