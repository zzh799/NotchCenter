# Agent Note:恢复系统监控插件（SystemMonitorPlugin）

status: implemented
date: 2026-09-20
deciders: zeaven
replaces: （无；承 [2026-09-10-system-monitor-overview-pixel-density](../implemented/2026-09-10-system-monitor-overview-pixel-density.md)）

## Context(背景与约束)

- 背景：`SystemMonitorPlugin`（CPU / 内存 / 磁盘 / 网络四个单指标块 + 四合一总览块）在 [`b980ae1`](https://github.com/) 「回退 05b7f0a 之后的插件页面批次」中随 18 个插件一并删除，删除原因是被回退批次牵连，而非插件本身有缺陷。此后 9 天它未回归，而 `ui-token-baseline.json` 仍保留其条目、[2026-09-10-system-monitor-overview-pixel-density](../implemented/2026-09-10-system-monitor-overview-pixel-density.md) 仍描述其总览块降级逻辑——文档与代码早已脱节。
- 恢复源：`05b7f0a`（删除前最后一个版本，即 `b980ae1^`）的 `Plugins/SystemMonitorPlugin/` 与 `Tests/NotchCenterTests/SystemMonitorTests.swift`。该版本自 `877a52b` 起未再改动（最后一次改动是总览块像素降级）。
- 约束：删除点之后基线已变动 20 余个提交（像素三档换算、API 升到 v1.5.0、构建脚本增量管线、抽屉顶栏三段化、`BlockPopover` 新增 `cardInset` / `focusContent` 等），恢复不是纯 `git checkout`——须按当前基线复核编译、API 契约与门禁（决策记录 / 文档预算 / 尺寸探针）。
- 不做（out of scope）：不重写采样引擎、不改块形态与阈值语义、不新增块类型、不动 min/rec/max 尺寸声明；不恢复同批次被删的其它 17 个插件。

## Decision(决策)

- 从 `05b7f0a` 恢复插件源码、本地化资源、插件 README 与单测，逐项对齐当前基线，而非按记忆重写：既有行为（采样降频、阈值分级、跨度→布局映射、像素降级）是已验证资产。
- 源码回填：`Plugins/SystemMonitorPlugin/`（9 个 Swift 文件 + `Plugin.plist` + en/zh-Hans `Localizable.strings` + `README.md`）。对外依赖只有 `NotchCenterKit` 公开 API（`NotchBlock` / `BlockPixelSize` / `BlockProbe` / `BlockCard` / `StateStore` / `NotchTokens`），无私有框架、无第三方依赖，`Plugin.plist` 无需声明 `Dependencies`，`APIVersionRange` 走缺省 `1.0..<2.0`（当前 `currentVersion` 1.5.0 落在区间内）。
- 测试回填：`Tests/NotchCenterTests/SystemMonitorTests.swift`（35 个用例，含跨度映射、像素降级阈值、阈值钳制、差分采样、历史裁剪、排除表解析）。
- 顺带修复同 commit 被误删的门禁：`Tests/NotchCenterTests/BlockMinSizeVerificationTests.swift` 也在 `b980ae1` 一并删除（其清单含 MediaControls / OpenCodeUsage 两个被删插件），导致「官方 drawer 块必须声明探针」这条规则无人执行——`./scripts/build.sh verify-sizes` 按套件名过滤，套件不存在不会报错，只静默少跑（实测只剩 `BlockSizeVerifierTests` 的 10 个用例）。本次恢复该套件并补齐清单（含 Camera / LidAngleDepth / CommandScheduler 三个此前未登记者），恢复点见 [2026-09-07-block-min-size-occlusion-verification](../implemented/2026-09-07-block-min-size-occlusion-verification.md)。
- 测试登记：`LocalizationTests` 的两个插件清单（双语键集奇偶校验的 `modules`、`Plugin.plist` 中文元数据的 `pluginPlistCarriesChineseMetadataLocales`）补回 `SystemMonitorPlugin`——不补则新插件两份 strings 是否同键、plist 是否有中文译文都不在校验范围。
- 文档：`docs/agents/宿主开发约定.md` 的插件代码地图同步为现有 13 个插件，并摘掉 MediaControls / OpenCodeUsage 两个指向已删目录的僵尸条目、补上 `Plugins/LidAngleKit` 是复用库而非插件的例外说明。
- 门禁：commit 用 `feat:` 并引用本 note；恢复后跑 `./scripts/build.sh test`、`./scripts/build.sh verify-sizes`、`./scripts/run-doc-checks.sh`、`./scripts/scan-ui-tokens.sh --strict`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 从 `05b7f0a` 恢复后对齐基线 | 复用已验证实现与 543 行单测；风险集中在极少数 API 漂移点 | 需逐项复核 9 天基线漂移 | 采纳 |
| 按当前规范重写 | 结构最贴合现行约定 | 丢弃采样/布局的既有验证；工作量与回归风险远高于收益 | 否决 |
| 只 `git checkout` 不做复核 | 最快 | 基线已漂移 20+ 提交，编译/门禁/契约均未经校验，等于把回归塞进主干 | 否决 |
| 只恢复插件，不恢复探针门禁套件 | 改动面最小 | 插件探针声明无人校验（该插件 5 个块全靠这条门禁），且 `verify-sizes` 继续静默半残 | 否决 |

## Consequences(影响)

- 官方插件数由 12 增至 13，插件目录多出 5 个块类型（`system.cpu` / `system.memory` / `system.disk` / `system.network` / `system.overview`）；插件发现、target 生成、bundle 组装全部自动，`Project.swift` 与 `build.sh` 无需改动。
- `ui-token-baseline.json` 的 `SystemMonitorPlugin/Sources/BlockViews.swift: color-rgb=3` 条目重新生效（基线只降不升，无需更新；扫描结果与基线一致）。
- 探针门禁覆盖面为 19 个官方 drawer 块（恢复前该套件缺失，实际覆盖 0）：Camera / LidAngleDepth / CommandScheduler 三个此前漏登记的官方插件自此纳入校验，其探针声明若不合规会直接红（本次实测 19 块全部通过）。
- 采样时机语义：恢复后采样引擎只在有块落位时启动、抽屉收起降到 10 s、插件禁用即停表——与 [2026-09-11-drawer-content-warmth](../implemented/2026-09-11-drawer-content-warmth.md) 的 `isPreview` 契约一致（预览副本不插探针、不登记生命周期）。
- 决策落地后本 note `git mv` 至 `docs/agent-notes/implemented/`。

## Changelog

- 2026-09-20:初始版本。
