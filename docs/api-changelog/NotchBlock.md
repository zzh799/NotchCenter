# API 变更日志:NotchBlock(块声明与尺寸)

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。
>
> 版本号以 `NotchCenterKitAPI.currentVersion` 为唯一真源;本文件只标注变更对外的兼容性口径。

## 2026-09-10 · v1.3.0 · breaking(移除 BlockKind.page,撤销整页独占语义)
- **移除** `BlockKind.page`(枚举回到 `compact` / `drawer` 两态)与 `BlockKind.isExclusivePage`。独占不变量(同页禁止共存、恒铺满内容区、不可拖动/缩放/重排)整体删除:`LayoutEnginePages` 整文件、`LayoutIssue.pageBlockSharing`、`PlacedBlock.isPage` 一并移除。
- **新增** `BlockPlacement { autoGrid(默认), newPageWhenOccupied }` 与 `NotchBlock.placement`(带默认值,纯新增零破坏)。**只影响"从目录添加那一刻"落在哪一页**:`newPageWhenOccupied` 在当前页被占用时另开一页(页满且无空页则失败提示);落位后该块与任何抽屉块完全同权(可拖动/缩放/跨页搬移/参与重排/同页共存)。落点偏好由**插件声明、宿主执行**,宿主不硬编码任何插件 ID。
- **`probes` 恢复门禁强制**:`.page` 的豁免分支删除,所有官方 `.drawer` 块都必须声明探针。
- **渲染**:删除整页渲染变体(出 `ScrollView`、宿主占位视图);所有抽屉块统一走 `BlockCard` + 宿主抽屉 `ScrollView`;插件不可用时统一静默跳过。
- **兼容性**:破坏。移除枚举 case 对"穷举 `switch BlockKind`"的插件是源码级破坏;只做 `== .drawer` 比较的插件零影响。`placement` 有默认值,不声明即零影响。
- **迁移**:穷举 `switch BlockKind` 的插件删掉 `case .page` 分支(并入 `case .drawer`);曾用 `.page` 的块改声明 `kind: .drawer`(尺寸三档原样保留),如需"添加时另开一页"再补 `placement: .newPageWhenOccupied` 与 `probes`。存量 `layout.json` 的 `isPage` 键被解码器忽略,块就地留在原页原位置(不搬页、不丢块)。
- 关联 Agent Note:[2026-09-10-drop-exclusive-page-blocks](../agent-notes/implemented/2026-09-10-drop-exclusive-page-blocks.md)

## 2026-09-10 · v1.2.0 · added(BlockKind.page 独占整页)——已被 v1.3.0 整体撤销
- ~~新增 `BlockKind.page`(枚举第三态):整页块独占**一整个抽屉页**,该页不得再有任何其它抽屉块。~~
- ~~新增 `PlacedBlock.isPage: Bool`(持久化标记,默认 false)。~~
- ~~`probes` 豁免;`verify-sizes` 对 `page` 只校验声明合法性。~~
- **本条目已作废**:整页独占语义与"块是灵活组件"的设计原则冲突,于 v1.3.0 整体撤销。保留此条仅为版本沿革可追溯(`occupiesDrawerGrid` 未撤销,它本就是"吃不吃格跨换算"的判据)。

## 2026-09-07 · v1.1.0 · added(打包期遮挡校验)
- 新增 `BlockProbe { id, rect }`(块本地坐标的关键 UI 区矩形)与 `NotchBlock.probes: (@MainActor (BlockLayoutInfo) -> [BlockProbe])?`(可选;compact 块与未声明的第三方块跳过)。
- 新增 `BlockSizeVerifier`(Kit 纯几何判定器):`violations(probes:contentSize:)` 返回越界(`probeOutsideContent`)/ 自叠(`probesOverlap`)违规列表。
- 语义:打包校验时宿主以 `minSize` 作内容盒调用 probes,探针只准依赖 `frame.size`(像素),不得依赖网格跨度上下文;官方 drawer 块必须声明(门禁),见 `verify-sizes`。
- 兼容性:非破坏(纯新增,默认 nil)。
- 迁移:<无>
- 关联 Agent Note:[2026-09-07-block-min-size-occlusion-verification](../agent-notes/implemented/2026-09-07-block-min-size-occlusion-verification.md)

## 2026-09-07 · v1.1.0 · breaking(像素三档模型,迁移自离散档位)
- **移除**:`BlockSize` 枚举(small/medium/wide/large/extraLarge)、`NotchBlock.supportedSizes`/ `supportedGridSpans` / `defaultSize`,以及按档位的 allows/clamping 变体。
- **新增**:`BlockPixelSize { width, height }`(pt);`NotchBlock.minSize / maxSize /  recommendedSize: BlockPixelSize?`(compact 恒 nil)与 `NotchBlock.globalMinimumPixel`  (75×60);`sizeBox(cellWidth:cellHeight:)` / `allows(_:cellWidth:cellHeight:)` /  `clamping(_:cellWidth:cellHeight:)`(按当前格子换算,不含格间间距);`GridSpan` 保留(布局/引擎内部语义,`GridSpan.globalMinimum` 1×1 兜底)。
- 语义:组件声明物理像素区间,宿主按当前用户格子换算允许格跨盒;min 向上取整(≥1)、max 向下取整(≥1,格子过大时 1×1 兜底)、recommended 就近取整夹进盒内。
- 兼容性:破坏(依赖旧离散档位的第三方抽屉块须迁移)。
- 迁移:旧跨度 × 默认格 150/120 → 像素(旧 2×2 → `300×240`);三档须满足逐轴`min ≤ recommended ≤ max` 且 min ≥ 75×60;运行时 `BlockLayoutInfo` 字段不变。
- 关联 Agent Note:[2026-09-07-block-size-pixel-three-tier](../agent-notes/implemented/2026-09-07-block-size-pixel-three-tier.md)

## Changelog
- v1.3.0:移除 `BlockKind.page`(撤销整页独占语义) + 新增 `BlockPlacement` 落点偏好(2026-09-10)。
- v1.2.0:`BlockKind.page` 独占整页 + `PlacedBlock.isPage` 回落标记(2026-09-10)。**已被 v1.3.0 撤销**。
- v1.1.0:像素三档 + 打包期遮挡校验(2026-09-07)。
- v1.1.0:活动岛移除 + 活动摘要通道(2026-09-03)。
- v1.0.0:NotchCenter 插件宿主架构(2026-08-21)。
