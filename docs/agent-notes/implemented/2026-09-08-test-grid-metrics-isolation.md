# Agent Note: 测试期网格指标隔离（DrawerPageTests 历史遗留失败根因）

status: implemented
date: 2026-09-08
deciders: 用户（报"历史遗留失败，建议另行排查"）+ 排查结论

## Context(背景与约束)

`DrawerPageTests.testGeometryIsScopedToPage`（几何计数 4≠2、2≠1）与 `testPushDownDoesNotDragOtherPageBlocks`（预览为 nil、缩放被拒）在干净工作树上稳定失败，用 `git stash` 复验属实，初步怀疑"分页几何最近被改动后未同步测试预期"。

约束：改的是测试隔离，不动任何生产断言语义，也不放宽被测行为；像素三档模型（`2026-09-07-block-size-pixel-three-tier`）下"档位 ↔ 格跨"的换算是格子尺寸的函数，格子来源必须确定。

## Decision(决策)

根因不是分页几何，而是**测试进程读到开发机上的真实偏好**：测试以宿主 App 为 `TEST_HOST`（Project.swift），`UserDefaults.standard` 就是用户在「设置 → 布局」里调过的那一份。本机持久化的是最小档 75×60，而像素夹具（`fixtureBox`）按出厂格 150×120 声明物理像素——`small`（150×120 点）被换算成 2×2 格：`autoPlaceDrawerBlock` 的默认格尺寸取实时 `NotchGridMetrics`，几何断言随之翻倍；`placeDrawerBlock` 的默认格是硬编码 150×120（不受影响），但 `resizeDrawerBlock` 按实时格算档位盒（large 档变成"最少 4 行"），于是 4×2 的缩放被拒、预览为空。

定位手法：`defaults read com.notchcenter.app` 看到 75×60 → 写回该值跑测试必现 7 条断言失败、删掉该键即全绿（决定性复现）。

- 新增 `Tests/NotchCenterTests/GridMetricsTestSupport.swift`：`GridMetricsSnapshot` + `XCTestCase.pinGridMetricsToFixtureDefaults()`（`setUp` 里调用，`addTeardownBlock` 自动还原；指标已在位时 store 的 `set` 直接返回，出厂机器上零副作用）。
- 钉定的套件（用像素夹具或读 `NotchGridMetrics` 者）：`LayoutEngineTests`、`DrawerPageTests`、`BlockPlacementTests`、`LayoutPerformanceTests`、`DrawerInteractionStateTests`、`ResizeHysteresisTests`。
- `fixtureCellWidth/Height` 改为直接取 `GridMetricsStore.default*`，不再养第二份常量。
- `GridMetricsStoreTests.testGridMetricsForwardsToSharedStore` 原以 `shared.resetToDefaults()` 收尾——它会**删掉用户持久化的格子设置**（每次跑全量抹一次），且中途把进程内指标改成 200/10 再复位到 150，使失败面随套件顺序漂移；改为快照还原，并断言"还原后 == 用户原本那份"（不比常量）。
- 测试指南「注意事项」补上这条纪律。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 改断言/改期望值（2、1 就地改成 4、2） | 改动最小 | 把"本机读到的偏好"写进预期，换台机器又红；掩盖真实前提 | 否决 |
| 每个调用点显式传 `cellWidth/cellHeight` | 不碰全局 | `resizeDrawerBlock`/`previewArrangement` 没有注入点，覆盖不全 | 否决 |
| 生产侧把 `placeDrawerBlock` 的硬编码 150×120 改成实时指标 | 顺手修一处真实不一致 | 会改变 App 行为，且使未钉定的套件全部转为依赖环境；需另开 PR | 否决（留在下文备注） |
| 每个用例 `setUp` 钉指标 + 快照还原 | 覆盖全、语义明确、还原后零残留 | 需按套件登记（已写入纪律） | 采用 |

## Consequences(影响)

测试不再受开发机网格设置影响：持久化 75×60 / 出厂默认 / 极端值 280×240+32+40 三种环境下 `./scripts/build.sh test` 均 559 通过。副作用：`GridMetricsStoreTests` 那个用例仍会经共享单例碰真实偏好域（它测的就是共享单例），还原时会把 `spacing` 以默认值落盘（值同出厂默认，`isDefault` 仍为 true，行为等价）。未修的一处**生产**不一致：`LayoutEngine.placeDrawerBlock` 默认格硬编码 150×120，而宿主调用点（`BlockDropTargeting` 设置目录拖入）没有传实时格——用户把格子调成非出厂值时，落位跨度按 150×120 算（偏小）。属独立缺陷，建议另开 PR 让调用点显式传 `NotchGridMetrics.cellWidth/cellHeight`，并同步给相关用例钉指标。另观察到 `DisplayPluginTests.testConsecutiveWriteFailuresHideRow` 在满载跑全量时偶发失败（写入投递后未等失败回传即断言），与本次改动无关，未处理。

## Changelog

- v1.0.0: 定位根因并完成测试期网格指标隔离（2026-09-08）。
