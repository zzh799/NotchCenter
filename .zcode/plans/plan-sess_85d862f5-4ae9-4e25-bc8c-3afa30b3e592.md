## Overview 块跨度扩展：2×2 → 1×1 / 1×2 / 2×1 / 2×2 / 4×2 / 4×3 / 4×4

盘问定稿（3 决策 + 落码确认）：1×1 = 横向小条竖排（名称+值）；1×2 = 四行、2×1 = 四列（名称+双值分色，复用现有 `MetricCell(showsSparkline: false)`）；单块 2×1 sparkline 死分支本次一并修。已确认宿主抽屉路径 `size` 恒 nil 但 `widthColumns/heightRows` 有值（`NotchPanelContent.swift:366-370`），所有尺寸判定改走 span。

### 1. 新增布局映射纯逻辑 — 新文件 `Plugins/SystemMonitorPlugin/Sources/BlockLayoutArrangement.swift`

```swift
enum OverviewArrangement: Equatable {
    case compactStrips    // 1×1：横向小条竖排
    case stackedMiniCells // 1×2：迷你 cell 竖排四行
    case miniCellRow      // 2×1：迷你 cell 横排四列
    case sparklineGrid    // 2×2 / 4×4：两列网格（现状）
    case sparklineRow     // 4×2 / 4×3：横向一排（现状）
}
static func overviewArrangement(widthColumns: Int?, heightRows: Int?) -> OverviewArrangement
// (1,1)→compactStrips；(1,2)→stackedMiniCells；(2,1)→miniCellRow；
// w==h→sparklineGrid；w>h→sparklineRow；nil（组件目录预览等无 span 上下文）→sparklineGrid

enum MetricCellForm { case mini, sparkline }
static func singleBlockForm(widthColumns: Int?, heightRows: Int?, size: BlockSize?) -> MetricCellForm
// span 已知 → w==2&&h==1 时 sparkline；span nil → size == .medium；再 nil → mini
```

### 2. 块声明 — `Plugins/SystemMonitorPlugin/Sources/SystemMonitorPlugin.swift`

- `overviewBlock`（59-78 行）：`supportedSizes: [.small, .medium, .large, .extraLarge]`、`supportedGridSpans: [GridSpan(1,2), GridSpan(4,3), GridSpan(4,4)]`、`defaultSize` 仍 `.large`（存量实例不变，只是可缩；1×1/2×1 走 BlockSize 预设、1×2 走 GridSpan，符合布局引擎红线"预设用 supportedSizes、自由档用 supportedGridSpans"）。
- `makeView` 把 `context.layoutInfo.widthColumns/heightRows` 传给 `OverviewBlockView`。
- `singleBlock`（53 行）：`showsSparkline` 改用 `singleBlockForm(...)`，修死分支；同步更新 7-10 行头注释的跨度描述。

### 3. 视图 — `Plugins/SystemMonitorPlugin/Sources/BlockViews.swift`

- `OverviewBlockView`：删掉 aspect>1.6 启发式与 GeometryReader（跨度变化本就重走 makeView，创建期即知布局），按 `overviewArrangement` 分支：
  - `compactStrips`：新视图 `CompactMetricStrip`——HStack 名称(9pt 灰)+值(12pt semibold 等级着色)，竖排 spacing≈4。**磁盘/网络为聚合单值**（读+写 / 下+上，`rateString(.auto)`；strip 单行放不下双值且 cellWidth 可缩到 90pt 会溢出），CPU/内存为百分比；等级着色复用 `MetricPresentation.level/levelColor`；`diskAvailable == false` 显示 `state.unavailable`。
  - `stackedMiniCells`（VStack）/ `miniCellRow`（HStack）：`ForEach(enabledKinds)` + `MetricCell(showsSparkline: false)` 直接复用（即"名称+双值分色+迷你条"）。
  - `sparklineGrid` / `sparklineRow`：维持现状（`MetricCell(showsSparkline: true)`、默认阈值/.auto 单位/默认排除表）。
  - 各形态都按 `instance.overview.enabled` 过滤，关几个排几个；history 空仍走 `waitingPlaceholder`。
- 同步更新文件头布局策略注释。

### 4. 测试 — `Tests/NotchCenterTests/SystemMonitorTests.swift`

- `testBlockDeclarationsValidateAndStayUnique`（356-361 行）：overview `supportedSpans` 扩为 7 个（1×1/1×2/2×1/2×2/4×2/4×3/4×4）；单块断言不变。
- 新增：`overviewArrangement` 七跨度+nil 映射回归；`singleBlockForm` 的 (2,1)/(1,1)/nil+size/nil+nil 四分支回归。

### 5. 明确不做 / 已知边界

- 本地化零新增键（名称复用现有 `displayNameKey`）；LocalizationTests 两个硬编码数组本就不含本插件，不扩scope。
- 实例设置不动（历史窗+四指标开关照旧；紧凑档无 sparkline 但设置无害）。
- 4×2/4×3/4×4 视觉零变化；存量用户已有实例不受影响。

### 6. 验证

`swift build && swift test` → `./scripts/build.sh dev` → 杀旧实例重启（防 stale-instance 坑）→ 编辑模式拖拽 overview 依次吸附 1×1/1×2/2×1 验证三形态 + 单指标块拉到 2×1 确认 sparkline 复活。截屏级视觉验收留给你真机确认。