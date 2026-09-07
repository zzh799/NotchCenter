# Agent Note:官方媒体播放控制插件(MediaControlsPlugin)

status: implemented
date: 2026-09-03
deciders: zhouzihang
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 目标:新增官方插件,控制系统当前正在播放的媒体(播放/暂停/上一首/下一首),以抽屉块承载控制面(封面/标题/进度条),并把"正在播放"的简介与进度接入活动摘要通道,供紧凑带展示(展示形态见 [`2026-09-03-compact-area-activity-summary`](2026-09-03-compact-area-activity-summary.md),两提案配套)。
- macOS 无公开 API 控制其他应用(Spotify/Music 等)的播放状态,这是本提案技术路线必须面对的核心约束。
- 契约约束(见 [`插件开发约定`](../../agents/插件开发约定.md)):与官方插件走完全相同的加载路径、无特权;登记只写 `Plugins/<Name>/Plugin.plist`;主类必须 `@objc(MediaControlsPlugin)`;不引入新 SPM 远程依赖;UI 字符串本地化(en 基准 + zh-Hans 键集一致)。
- out of scope:歌词/均衡器/媒体库管理;控制宿主自身播放(宿主不是播放器);系统级全局媒体键接管。

## Decision(决策)

- 技术路线(用户拍板):**MediaRemote(私有框架)只读观测 + 控制**——`MediaRemoteSession` 单层封装 dlopen/dlsym,符号用无下划线现代导出(`MRMediaRemoteGetNowPlayingInfo` / `MRMediaRemoteGetNowPlayingApplicationIsPlaying` / `MRMediaRemoteSendCommand`,本机 runtime probe 验证),Now Playing 字典用字面量 key;命令值 play=0 / pause=1 / toggle=2 / next=4 / previous=5;框架不可用时插件整体优雅降级(显示"不可用"空态,不启动轮询)。
- 命名与登记:目录 `Plugins/MediaControlsPlugin/`,主类 `@objc(MediaControlsPlugin)`,PluginID `com.notchcenter.media-controls`,仅此一处登记。
- 状态模型:播放状态是瞬态,由插件级共享 `ObservableObject`(`MediaPlayerController.shared`,全局单实例)持有——1s ticker + Darwin 通知(`com.apple.MediaRemote.NowPlayingInfoChanged`)驱动,不落 stateStore;`NowPlayingProviding` 协议抽象观测源,测试注入假实现。
- 摘要接入:播放中提交「曲名 + Artist — Album + 播放进度」(id `media-controls.summary`),暂停置态(`pause.fill`),停止/不可用收回;进度按整秒节流;封面经 `NSCache` 缓存、按曲目 key 去抖,解码失败即置空不阻断。
- 展示载体:单抽屉块 `media.controls`(large/extraLarge,defaultSize large,`playpause.fill`,scrollUsage none),内容=封面 + 曲目信息 + 进度条 + play/pause/previous/next;`isPreview` 副本不派发控制命令(预览契约)。
- 安全禁用:`suspend()` 置 `isActive = false` + 停 timer + 去注册通知 + 收回摘要;在途异步 fetch 回调经 `isActive` guard 丢弃;`poll()` 入口短路。
- 本地化:插件内文案走 `L()`/`LF()`(bundle 取 `MediaControlsPlugin.self`);Plugin.plist 的 DisplayNameLocales / DescriptionLocales 补 zh-Hans。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| MediaRemote(私有) | 跨应用取全局播放信息与控制,体验最完整 | 私有 API:版本兼容、崩溃与公证风险 | 采用(用户拍板;不可用优雅降级兜底) |
| MPNowPlayingInfoCenter + MPRemoteCommandCenter | 公开 API、无合规风险 | 仅当本 app 自身是活跃 Now Playing 源才生效,无法控制 Spotify/Music | 否(不满足主需求) |
| AppleScript / 播放器 URL scheme | 公开、可控制 Music 等 | 仅覆盖少数播放器;AppleScript 需自动化授权,体验割裂 | 否(留作备选 fallback 思路) |
| 仅接管键盘媒体键(NSEvent 监测) | 无私有 API | 覆盖面小、易与系统全局键冲突 | 否 |

## Consequences(影响)

- 新增一个官方插件目录(独立 bundle target);Kit 无新增远程依赖、无公共接口新增(复用 `HostController.showActivitySummary` 通道)。
- 私有框架风险(版本兼容/公证)以文件头注释与 README 书面明示;播放观测失败时 UI 走 `.unavailable` / `.idle` 降级空态。
- 新增 `MediaControlsTests` 状态机回归(13 例:摘要提交/暂停置态/停止收回/整秒节流/曲目切换/禁用时 in-flight 丢弃/框架不可用降级/命令转发/解码与缺字段;注入假 Provider 与 RecordingHost,不触碰真实私有框架)。
- 本地化键对齐由 `LocalizationTests` 覆盖(PomodoroPlugin、MediaControlsPlugin 均纳入 modules 清单)。
- 随 `2026-09-03-compact-area-activity-summary` 一并收口归档。

## Changelog

- v2:implemented 收口(2026-09-03)——MediaRemote 路线采纳并落地;摘要分工=播放中提交/暂停置态/停止收回;展示载体收敛为单抽屉块、无紧凑图标、无 seek;每实例设置不适用(全局单实例)。
- v1:proposed 草案(2026-09-03)。

## 修订(2026-09-07,像素三档模型)
本记录中 "large/extraLarge, defaultSize large" 等措辞属于已废弃的离散档位模型。同日决策见 `2026-09-07-block-size-pixel-three-tier` 与 `2026-09-07-block-min-size-occlusion-verification`：`media.controls` 现声明物理像素三档 `300×240 / 600×240 / 300×240`（= 旧 2×2/4×2 × 默认格 150/120），并带打包期遮挡校验探针。历史文字保留不改。
