# API 变更日志:NotchBlock(块声明与尺寸)

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。
>
> 版本号以 `NotchCenterKitAPI.currentVersion` 为唯一真源;本文件只标注变更对外的兼容性口径。

## 2026-09-10 · v1.2.0 · added(BlockKind.page 独占整页)
- **新增** `BlockKind.page`(枚举第三态):整页块独占**一整个抽屉页**,该页不得再有任何其它抽屉块。
  配套 `BlockKind.occupiesDrawerGrid`(compact false,drawer/page true)与 `isExclusivePage`(仅 page true)。
- **新增** `PlacedBlock.isPage: Bool`(持久化标记,默认 false):插件声明是"是否整页"的唯一真源,解析不到时回落。
- **尺寸**:整页块复用像素三档,规则与 drawer 完全一致(逐轴 `min ≤ recommended ≤ max`、min ≥ 75×60);
  列跨度恒夹进 `[minimumColumnCount(), effectiveMaxColumns()]`,原点恒 `(0,0)`。
- **约束**:`interaction` 必须为 `.expandDrawer`(声明 `.custom` 即校验失败);同页混排由 `LayoutIssue.pageBlockSharing` 报错。
- **`probes` 豁免**:整页内容盒 = 整页,不存在邻居遮挡;`verify-sizes` 对 `page` 只校验声明合法性。
- **兼容性**:纯新增(`BlockKind` 增 case、`PlacedBlock` 增可选字段)。枚举新增 case 对"穷举 `switch BlockKind`"的插件是源码级破坏;
  只做 `== .drawer` 比较的插件零影响。
- **迁移**:穷举 `switch BlockKind` 的插件补 `case .page`;不做整页的插件无需任何改动。
- 关联 Agent Note:[2026-09-10-plugin-page-blocks](../agent-notes/implemented/2026-09-10-plugin-page-blocks.md)

## 2026-09-07 · v1.1.0 · added(打包期遮挡校验)
- 新增 `BlockProbe { id, rect }`(块本地坐标的关键 UI 区矩形)与 `NotchBlock.probes:
  (@MainActor (BlockLayoutInfo) -> [BlockProbe])?`(可选;compact 块与未声明的第三方块跳过)。
- 新增 `BlockSizeVerifier`(Kit 纯几何判定器):`violations(probes:contentSize:)` 返回
  越界(`probeOutsideContent`)/ 自叠(`probesOverlap`)违规列表。
- 语义:打包校验时宿主以 `minSize` 作内容盒调用 probes,探针只准依赖 `frame.size`(像素),
  不得依赖网格跨度上下文;官方 drawer 块必须声明(门禁),见 `verify-sizes`。
- 兼容性:非破坏(纯新增,默认 nil)。
- 迁移:<无>
- 关联 Agent Note:[2026-09-07-block-min-size-occlusion-verification](../agent-notes/implemented/2026-09-07-block-min-size-occlusion-verification.md)

## 2026-09-07 · v1.1.0 · breaking(像素三档模型,迁移自离散档位)
- **移除**:`BlockSize` 枚举(small/medium/wide/large/extraLarge)、`NotchBlock.supportedSizes`
  / `supportedGridSpans` / `defaultSize`,以及按档位的 allows/clamping 变体。
- **新增**:`BlockPixelSize { width, height }`(pt);`NotchBlock.minSize / maxSize /  recommendedSize: BlockPixelSize?`(compact 恒 nil)与 `NotchBlock.globalMinimumPixel`  (75×60);`sizeBox(cellWidth:cellHeight:)` / `allows(_:cellWidth:cellHeight:)` /  `clamping(_:cellWidth:cellHeight:)`(按当前格子换算,不含格间间距);`GridSpan` 保留
  (布局/引擎内部语义,`GridSpan.globalMinimum` 1×1 兜底)。
- 语义:组件声明物理像素区间,宿主按当前用户格子换算允许格跨盒;min 向上取整(≥1)、
  max 向下取整(≥1,格子过大时 1×1 兜底)、recommended 就近取整夹进盒内。
- 兼容性:破坏(依赖旧离散档位的第三方抽屉块须迁移)。
- 迁移:旧跨度 × 默认格 150/120 → 像素(旧 2×2 → `300×240`);三档须满足逐轴
  `min ≤ recommended ≤ max` 且 min ≥ 75×60;运行时 `BlockLayoutInfo` 字段不变。
- 关联 Agent Note:[2026-09-07-block-size-pixel-three-tier](../agent-notes/implemented/2026-09-07-block-size-pixel-three-tier.md)

## Changelog
- v1.2.0:`BlockKind.page` 独占整页 + `PlacedBlock.isPage` 回落标记(2026-09-10)。
- v1.1.0:像素三档 + 打包期遮挡校验(2026-09-07)。
- v1.1.0:活动岛移除 + 活动摘要通道(2026-09-03)。
- v1.0.0:NotchCenter 插件宿主架构(2026-08-21)。
