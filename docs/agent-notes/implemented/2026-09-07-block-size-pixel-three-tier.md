# Agent Note:组件尺寸三档模型(物理像素版)

status: implemented
date: 2026-09-07
deciders: 用户拍板 + 实现会话确认
replaces: 旧的"标定离散档位"(BlockSize 枚举 / supportedSizes)模型
superseded-by: <无>

## Context(背景与约束)

原需求(2026-09-07):"每个组件提供最小尺寸、最大尺寸、推荐尺寸;最小尺寸的最小尺寸是 75×60;本软件优先按推荐尺寸显示,用户不得将组件拖拽缩到小于最小或大于最大;插件打包时校验组件在最小尺寸下是否遮挡。"

中途纠偏(用户,推翻首版"格跨三档"设计):**最小/最大/推荐尺寸以像素(pt)为单位**——组件声明物理像素区间,宿主按当前用户格子尺寸实时换算格跨;无论用户把格子调成什么尺寸,组件物理尺寸都落在声明区间内。首版"三档格跨"在用户改格子后会失配,故废弃。

## Decision(决策)

1. **声明单位 = 物理像素**(`BlockPixelSize`),与格子尺寸无关;`globalMinimumPixel = 75×60 pt`(恰等于最小格 75×60,自洽)。
2. **换算规则**(用户确认,宿主唯一换算入口 `NotchBlock.sizeBox(cellWidth:cellHeight:)`):每轴独立,格数 ≥1;min 向上取整(物理 ≥ min)、max 向下取整(物理 ≤ max)、recommended 就近取整并夹进 `[min…max]`;用户把格子调大到 1×1 都超 max 时 1×1 兜底。
3. **换算不含格间间距**(用户确认):组件像素 = 格子之和;宿主渲染几何仍含间距,语义分离。
4. **存量超盒跨度照显不损坏**(用户确认):已摆放的块照常显示、不打断布局,再次拖拽按新边界钳制。
5. **官方插件迁移**:旧跨度 × 默认格 150/120 → 像素(如旧 2×2 → 300×240),运行时字段(`BlockLayoutInfo.widthColumns/heightRows/frame.size`)不变,插件 UI 逻辑零改动。
6. **打包期遮挡校验**(需求第 5 句):见 2026-09-07-block-min-size-occlusion-verification。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 物理像素三档 + 实时换算(采纳) | 用户改格子后组件物理尺寸恒落在声明区间;声明与布局解耦 | 需宿主换算层、存量迁移、像素↔格跨量化误差需兜底规则 | 采纳(用户纠偏后唯一方向) |
| B 格跨三档(首版) | 宿主零换算 | 用户改格子尺寸即失配(物理尺寸漂移出声明区间);min 全局下限 75×60 语义无法落地 | 废弃 |

## Consequences(影响)

- Kit:删 `BlockSize`/`supportedSizes`/`supportedGridSpans`/`defaultSize` 及按档 allows/clamping;增 `BlockPixelSize`、三档字段、`globalMinimumPixel`、`sizeBox/allows/clamping`(按当前格子换算);`GridSpan` 保留(布局/引擎内部仍用格跨)。
- 引擎/手势:允许盒 = 元素构建时换算一次(`DrawerElement.minSize/maxSize` 语义变为当前格下的盒角);`resizeDrawerBlock`/预览守卫改 `allows`(带 cell);移除 `sizeNotSupported` 相关 issue(存量盒外跨度不视为损坏)。引擎读 `NotchGridMetrics.cellWidth/.cellHeight`。
- 12 个官方插件迁移为像素三档;声明校验规则(三档齐全、min≤rec≤max、min≥75×60)。
- API 变更登记:[NotchBlock](../../api-changelog/NotchBlock.md)。
- 决策中"不打断存量布局"与"用户改格子"边界,测试见 LayoutEngineTests 换算单测三件套。

## Changelog

- v1:implemented(2026-09-07,本会话;上会话已完成实现、546 测试全绿,本会话续接收尾)。
