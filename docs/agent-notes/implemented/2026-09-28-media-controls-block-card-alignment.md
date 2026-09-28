# Agent Note:媒体控制块补齐卡片壳并按 NotchTokens 收敛

status: implemented
date: 2026-09-28
deciders: zhouzihang
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 背景:`MediaControlsPlugin` 于 2026-09-28 重建([重建决策](../implemented/2026-09-28-media-controls-plugin-restore.md)),视图层只做了单行版式,块表面沿用了旧版的"裸行"写法。落地后它是**唯一不自绘 `BlockCard` 的官方抽屉块**:宿主 [`DrawerBlockContainer`](../../../Sources/NotchCenter/DrawerBlockContainer.swift) 只做 `clipShape` 与编辑态压暗,卡片表面(近白填充 + 发丝描边)是插件义务。后果:该块在抽屉里常态无填充、无描边,是样式异类。同 2026-09-20 镜子块整改([记录](../implemented/2026-09-20-camera-mirror-block-styling.md))的判据完全一致。
- 次要问题(审计 [`插件优化审计.md`](../../插件优化审计.md) 记录):`MediaControlsMetrics.inset = 12` 未走 `NotchTokens.Space.cardPadding`(=10)也未注豁免;图标方块底色误用 `Surface.fillHighlighted`(语义是"选中 / 强调",用在常驻静态方框上让白 alpha 阶梯失真);状态文案与播放中的应用名同用 `Foreground.body`;`syncPresentation` 注释仍称"1s 心跳",而观测早已是推送式。
- 契约约束:DESIGN.md §9「所有抽屉块一致…统一套 `BlockCard`」、§14「插件 UI 推荐引用 `NotchTokens`」;改到插件领域前先读 [插件开发约定](../../agents/插件开发约定.md)。
- 不做(out of scope):声明的像素三档尺寸(`260×64 / 300×64 / 600×64`)与探针口径不动(避免连带改 README 与既有摆放);桥 / 控制器 / 数据源零改动;审计里另外两条 MediaControls P2(桥子进程退出后不重启、`send` 的 `terminationHandler` 赋值时序)属非 UI 范围,本次不动。

## Decision(决策)

- **块壳归位**:整块套 `BlockCard(hoverEffect: false)`([BlockCard.swift](../../../Sources/NotchCenterKit/BlockCard.swift)),填充与发丝描边交给 Kit;`fitScale` / `GeometryReader` 的窄盒等比缩放逻辑原样保留。
- **不开悬停微亮**:本卡自身不可点,悬停反馈由三个控制键各自的圆角底自己给;与 Notes / 命令调度 / 剪贴板这些"卡片内含自有控件的行"同档,而与"整卡即按钮"的 Clock / QuickButtonBox(开悬停)区分开。
- **内边距 token 化**:`MediaControlsMetrics.inset` 由字面量 `12` 改为 `NotchTokens.Space.cardPadding`(=10),与其余抽屉块的块内边距同源。总高随之 64 → 60,仍是声明 `minSize.height = 64` 之内的垂直居中行;打包期探针矩形同步收缩,校验仍过。
- **图标方块底色修正**:`Surface.fillHighlighted` → `Surface.track`(块内通用内嵌底,先例:摄像头取景框 / 相册占位 / 剪贴板图片面),描边由 `lineWidth: 1` 收到 `0.5`(对齐内嵌面统一口径),圆角维持 `Radius.card`。
- **状态文案分层**:应用名前景按 `controller.state.rendersMediaItem` 分流:播放 / 暂停用 `Foreground.body`,空态 / 降级态降到 `Foreground.muted`,不让状态说明与应用名抢同一声量(DESIGN.md §2.2)。
- **注释纠偏**:把"1s 心跳"改为"常驻的桥子进程";块视图头部补一句卡片壳归 Kit `BlockCard` 及其悬停取舍。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 套 `BlockCard` + 全部 token 收敛 | 与全部官方抽屉块同族;语义正确 | 观感有变化(常态多出填充与描边) | **采纳** |
| 只补 `BlockCard`,其余不动 | 改动最小 | `inset` token 违规与 `fillHighlighted` 语义误用留存 | 否 |
| 不补 `BlockCard`,仅登记豁免 | 零视觉变化 | 继续做唯一异类,违背 §9 统一壳约束 | 否 |
| 卡片开 `hoverEffect: true` | 整行泛亮,强调"控制面" | 光标落在应用名 / 空白处也亮,与按钮高亮叠加;与同类"含内置控件的行"不一致 | 否 |
| 去掉图标方块,图标直接落在卡片上 | 最克制 | 透明底 / 单色图标缺承托,空态只剩裸符号 | 否 |
| 内边距保留 12 并登记豁免 | 贴参考图原值 | 与全项目块内边距分叉,需长期维护豁免 | 否(改取 10) |

## Consequences(影响)

- 用户可见:媒体控制块与其余抽屉块同族(有近黑半透明底与发丝描边),行内边距由 12 收到 10,应用图标落在统一的可见底衬上;空态 / 降级态文案降为 muted,不再与播放中的应用名同亮。
- 布局:声明三档尺寸未动,格子默认 1 行 = 120pt,渲染高度不受总高 64 → 60 影响;`rowProbeRect` 由同一套常量推导,`BlockMinSizeVerificationTests` 仍过。
- 代码:`Plugins/MediaControlsPlugin/Sources/MediaControlsBlockViews.swift` 单文件;不新增 `NotchTokens` 取值,不改 `DesignTokens.swift` / `DESIGN.md`;本地化键集不变。
- 文档:[`插件优化审计.md`](../../插件优化审计.md) 中 MediaControls 的两条已修 P2 与跨插件共性项标注为已修并指向本记录。

## Changelog

- v1:2026-09-28 首版(proposed):补 `BlockCard` 壳 + `inset` 走 `Space.cardPadding` + 图标方块底色改 `Surface.track` + 状态文案分层 + 注释纠偏。
- v2:2026-09-28 落地(implemented):单文件改动;`./scripts/build.sh test` 全量 148 例通过,`verify-sizes` 通过,`scan-ui-tokens.sh` 无新增命中。
