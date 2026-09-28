# Agent Note:重建官方媒体控制插件（MediaControlsPlugin）

status: implemented
date: 2026-09-28
deciders: zhouzihang
replaces: [2026-09-03-media-controls-plugin](2026-09-03-media-controls-plugin.md)
superseded-by: <无>

## Context(背景与约束)

- 背景:`MediaControlsPlugin` 曾于 `c408e61` 落地,后被 `b980ae1`「回退 05b7f0a 之后的插件页面批次」连带删除。删除原因是批次牵连而非插件缺陷;`docs/产品路线图.md` 至今把「恢复 MediaControls」列为优先级第 1,且 `Plugins/DisplayPlugin/Sources/IOAVServiceBackend.swift` 的文件头注释仍以它作为私有框架访问的范例。文档与代码早已脱节。
- 目标:重建插件,以**参考图版式**承载控制面,单个抽屉块内一行排布「应用图标 + 应用名 + 上一首/播放暂停/下一首」。用户明确的形态边界:严格照参考图,补一个上一首;不要紧凑带活动摘要、不要快捷按钮、不要设置界面。
- 与旧版的实质差异:旧版展示**曲目**信息(封面/曲名/歌手/进度条/时间),新版展示**媒体来源应用**(图标 + 本地化应用名)并按单行收敛。故不是纯恢复,而是按新形态重写视图层与状态模型。
- 技术约束(本轮最贵的一条):macOS 无公开 API 观测/控制其他应用的播放,只能用私有框架 MediaRemote;而 **macOS 15.4 起系统只放行 bundle id 以 `com.apple.*` 开头的进程**访问它。宿主是无沙盒、ad-hoc 签名的进程,直连查询恒返回空。判定依据、可信探针的口径与踩坑记录见 [`系统集成与多语言`](../../agents/系统集成与多语言.md) 的「私有框架访问」一节,本记录不复述。
- 契约约束:登记只写 `Plugins/<Name>/Plugin.plist`;主类必须 `@objc(MediaControlsPlugin)`;不引入新 SPM 远程依赖;UI 字符串 en 基准 + zh-Hans 键集一致;官方 drawer 块必须声明尺寸探针。
- 不做(out of scope):歌词、均衡器、媒体库管理;seek / 音量 / 循环模式;紧凑带活动摘要与快捷按钮;控制宿主自身播放;接管系统媒体键。桥那边随上游带进来的 `seek / shuffle / repeat / speed` 源码保留但不调用。

## Decision(决策)

- **借 `/usr/bin/perl` 进程代读,桥用 vendored 上游而非自研**。落点是 `ungive/mediaremote-adapter`(BSD-3):helper framework 由 `scripts/build.sh` 的 `build_mediaremote_bridge()` 用 clang 直接编(不引入 CMake),连同 `mediaremote-adapter.pl` 复制进白名单插件的 `Contents/Resources/Bridge/`,运行期由 `MediaRemoteBridge` 起 `/usr/bin/perl … stream --no-diff --no-artwork --debounce=200` 子进程逐行读 JSON、用短命子进程投 `send <MRCommand>`。取舍理由:该桥已有两个独立项目在跑,`stream/get/send` 的行为与 JSON 契约稳定;自研最小桥要重写同一层 ObjC + Perl 胶水,省下的只是不调用的四个命令,不划算。
- **观测改为推送式,不再按秒轮询**。桥自己会在变化时逐行输出,旧版的 1s ticker 与 Darwin 通知观察一并删掉;`NowPlayingProviding` 从 `refresh(completion:)` 改成 `start(onChange:) / stop()`。子进程只在**块真的可见**期间常驻(按 `placementID` 维护呈现集合,视图在 `onAppear` / `onDisappear` / `onChange(of: \.isDrawerPresented)` 共用同一个幂等登记函数,预览副本不登记),收起即退出,不留后台进程。
- **应用身份两条路**:优先按桥给的 `bundleIdentifier` 走 `NSWorkspace` 取本地化显示名(得 `音乐.app` 形态)与图标;桥不给 bundle id 时按 `processIdentifier` 反查 `NSRunningApplication`。两条都拿不到才退回「正在播放」占位。名字走 `FileManager.displayName`、图标走 `NSWorkspace.icon(forFile:)`,都不是占位图。
- **展示载体**:单抽屉块 `media.controls`(`playpause.fill`),物理像素三档 `260×64 / 300×64 / 600×64`(高度锁死的单行块,宽度弹性);布局常量收敛为 `MediaControlsMetrics` 一份,探针与视图共用同一套推导。窄于声明下限的盒(存量落位 / 用户把格子调小)整行等比缩小,不顶到邻居块。
- **桥不可用与"没有媒体"必须分开**:桥的失败(资源缺失 / 子进程起不来或中途退出)单独成态,组件显降级空态;空 payload 才是正常空态。这条直接来自本轮踩过的坑——早前正是分不清这两者才误判成"直连能用"。
- **构建侧**:`build.sh` 新增 `BRIDGE_PLUGIN_IDS` 白名单 + `bridge_fingerprint` / `build_mediaremote_bridge` / `plugin_uses_bridge`;`bundle_fingerprint` 把桥产物纳入(桥重编即重打 bundle),`assemble_bundle` 复制 `Contents/Resources/Bridge/`,缺失即硬失败;`package` 时桥按 `arm64 x86_64` 出通用二进制。
- **署名与升级**:`Vendor/mediaremote-adapter/VENDORED.md` 记录固定 commit、纳入文件子集、未纳入项与升级步骤;`Plugins/MediaControlsPlugin/NOTICE` 保留上游版权与许可,`LICENSE` 原文随 vendored 目录入库。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| vendoring `ungive/mediaremote-adapter` + perl 宿主 | 两个开源项目已在跑;`stream` 推送、JSON 契约、`get/send` 语义都现成 | 引入第三方源码树与 vendored 目录;多一条 clang 编译步骤 | **采纳**(用户拍板) |
| 自研最小桥(约 120 行 ObjC + 30 行 Perl) | 零第三方源码,只要 `get/stream/send` | 重写同一层胶水;上游已验证的边界处理要重新踩;省下的只有不调用的四个命令 | 否 |
| 宿主进程内直连 MediaRemote(旧版做法) | 无子进程、无构建改动,旧代码可直接复用 | macOS 15.4+ 被系统拦截,查询恒空 | 否(**已被实测证伪,不可行**) |
| `osascript -l JavaScript`(JXA)+ ObjC 桥 | `com.apple.osascript` 满足前缀,无需编译任何东西 | 实测 `ObjC.import` 进不了私有框架、`bindFunction` 也取不到符号;且所有读接口都要 block 回调,JXA 支撑不了 | 否 |
| AppleScript / 播放器 URL scheme | 公开 API,无兼容与构造风险 | 只覆盖可脚本化的少数播放器;需 TCC 自动化授权;拿不到统一的「当前播放应用」语义 | 否 |
| 沿用旧版版式(封面 + 曲目 + 进度 + 三键) | 信息量最大 | 与用户选定的参考图形态不符 | 否 |
| 只做 UI 组件、不接数据源 | 工作量最小 | 不满足「可实际控制播放」的诉求 | 否 |

## Consequences(影响)

- 官方插件数由 13 增至 14;新增 1 个 drawer 块类型 `media.controls`。插件发现与 target 生成仍全自动,`Project.swift` 无需改动。
- **新增 vendored 第三方树** `Vendor/mediaremote-adapter`(BSD-3,固定 commit 见其 `UPSTREAM_COMMIT`);纳入构建的文件子集、未纳入项与升级步骤见该目录 `VENDORED.md`,署名见 `Plugins/MediaControlsPlugin/NOTICE`。
- **`build.sh` 多了一段构建链**:白名单 + 桥编译 + bundle 复制 + 指纹纳入。桥编译幂等(源码指纹未变即复用),dev 增量不受影响;`package` 的桥为通用二进制。
- 运行期开销:只有块可见时才有 1 个 `/usr/bin/perl` 子进程常驻(收起即退);控制命令每次一个短命子进程。相对旧版的每秒轮询,静止时反而更省。
- 新增 `Tests/NotchCenterTests/MediaControlsTests.swift`(20 例:状态推导、桥输出解码含脏输入、应用身份发布与 pid 退化、观测起停与幂等、命令转发、桥不可用降级、停止后丢弃迟到推送),注入假 Provider,不启动真实子进程。
- 门禁登记:`LocalizationTests` 的双语键集清单与 `Plugin.plist` 中文元数据清单、`BlockMinSizeVerificationTests.officialBlocks` 三处各补一项;`ui-token-baseline.json` 摘掉已不成立的 MediaControls 条目(新文件 raw token 命中为 0,基线只降不升)。
- 文档:`docs/agents/系统集成与多语言.md` 新增「私有框架访问」并记下 `swift -e` 假阳性的教训;`docs/agents/宿主开发约定.md` 插件代码地图补 `MediaControlsPlugin`;`docs/产品路线图.md` 更新「音乐中心页」前置信与恢复优先级项。

## Changelog

- v1:2026-09-28 首版(proposed):参考图单行形态 + 直连 MediaRemote + 呈现集合驱动的轮询档位。
- v2:2026-09-28 落地(implemented):插件 6 个源文件 + 双语资源 + 14 例单测,三处门禁登记补齐。
- v3:2026-09-28 **技术路线推翻重做**。v1/v2 的「直连 MediaRemote」建立在 `swift -e` 探针上,而该探针跑在 `com.apple.dt.swift-frontend` 里,是假阳性;换自编译二进制与真实 `.app` 复测后确认 macOS 15.4+ 的 `com.apple.*` 限制成立。改为 vendoring 上游 + `/usr/bin/perl` 宿主 + 推送式观测(删掉 ticker 与 Darwin 通知),`build.sh` 增加桥构建与分发,单测扩到 20 例,并在真机验证了「插件 → perl 子进程 → 解码 → 状态/应用身份」整条链路。
