# API 变更日志:NotchBlock(块声明与尺寸)

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。

## 2026-09-07 · v2.0.0 · added(打包期遮挡校验)
- 新增 `BlockProbe { id, rect }`(块本地坐标的关键 UI 区矩形)与 `NotchBlock.probes:
  (@MainActor (BlockLayoutInfo) -> [BlockProbe])?`(可选;compact 块与未声明的第三方块跳过)。
- 新增 `BlockSizeVerifier`(Kit 纯几何判定器):`violations(probes:contentSize:)` 返回
  越界(`probeOutsideContent`)/ 自叠(`probesOverlap`)违规列表。
- 语义:打包校验时宿主以 `minSize` 作内容盒调用 probes,探针只准依赖 `frame.size`(像素),
  不得依赖网格跨度上下文;官方 drawer 块必须声明(门禁),见 `verify-sizes`。
- 兼容性:非破坏(纯新增,默认 nil)。
- 迁移:<无>
- 关联 Agent Note:[2026-09-07-block-min-size-occlusion-verification](../agent-notes/implemented/2026-09-07-block-min-size-occlusion-verification.md)

## 2026-09-07 · v2.0.0 · breaking(像素三档模型,迁移自离散档位)
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
- v2.0.0:像素三档 + 打包期遮挡校验(2026-09-07)。
