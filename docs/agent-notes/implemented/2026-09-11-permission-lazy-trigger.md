# Agent Note:权限只在用时申请——启动期零 TCC 触发

status: proposed
date: 2026-09-11
deciders: zhouzihang
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 需求原文：「不要每次一打开，就请求权限，需要权限时，先打开设置中的权限弹窗，（不打开设置），不要让权限阻塞其他功能，只阻塞需要权限的功能。」
- 现状违背 [系统集成与多语言](../../agents/系统集成与多语言.md) 的红线「系统授权窗的触发点只有一处」，有三处漏口：
  - `CameraPlugin.attachServices` 在**插件装载期**（= 每次启动 App）调 `CameraStore.configureIfNeeded()`，其中 `AVCaptureDeviceInput(device:)` 会拉起系统摄像头授权窗 → 每次开机弹一次。
  - `LidAngleDepthPlugin` 同样的装载期走 `LidDepthController.start()` → `ScreenSnapshotter/Streamer.warmFilter()` → `SCShareableContent`，该调用本身就是屏幕录制授权窗的触发点 → 每次开机再弹一次。
  - `CameraPermissionGateView.openGuide` 在没有 `hostController` 时直接 `NSWorkspace.open(SystemSettingsURL…)`，绕过「权限管理」弹窗直开系统设置，与用户拍板的入口形态相反。
- 约束：`SystemPermission.requiresRelaunch` 语义不变（屏幕录制/辅助功能仍须重启 App 才生效）；不代改 TCC；不做启动期轮询提示。
- 明确不做：不加"启动时扫一遍缺哪些权限"的守卫；开关默认开启（`LidDepthPreferences.Factory.isEnabled`）也**不**构成启动弹窗的理由。

## Decision(决策)

### D1 采集类对象一律后移到"用户真的要用"的时刻构造

- 摄像头：`configureIfNeeded()` 从 `attachServices` 移入 `CameraStore.startSession()`（已在 `authorization == .authorized` 守卫之后），即用户点「点击预览」才建 `AVCaptureDeviceInput`。启动期只有一次只读的 `authorizationStatus` 查询。
- 屏幕录制：`ScreenStreamer.start()/warmFilter()` 与 `ScreenSnapshotter.rebuildFilter()` 前置权限判定（可注入 `permissionCheck`，默认 `CGPreflightScreenCaptureAccess`），未授权时**一次都不调用** `SCShareableContent`；`LidDepthController.start()` 也随之跳过启动期预热抓帧任务（插件侧的同一决策见 [合盖透视 note](2026-09-11-lid-angle-depth-effect.md) D5）。
- 已授权时行为不变：启动仍预热 filter（零延迟手感保留）。权限查询是只读的，不弹窗。

### D2 缺权限的唯一入口是宿主的「权限管理」弹窗

- 删除 `CameraPermissionGateView` 直开系统设置的分支，只保留 `hostController.presentPermissions(_:)`；系统设置由用户在弹窗内逐行点开（弹窗既有能力，保留）。
- 盖角控制台块与插件设置页在缺屏幕录制权限时给出「权限」按钮，同样只走 `presentPermissions([.screenRecording])`；「试播」在缺权限时改为弹权限窗，而不是演一遍什么都没有的效果。

### D3 权限只挡住"要画面的那部分"

- 缺屏幕录制权限：盖角读数、状态胶囊、开关、仪表照常；停摆的只有画面档（实时流与单帧同源同权限），块内以「权限」按钮说明。
- 缺摄像头权限：镜像块停在引导态（既有行为），不抛错、不整页失败。
- 授权后回到 App 立即重取状态（`CameraStore` 订阅 `NSApplication.didBecomeActiveNotification`），用户不必重开抽屉才看到解锁。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 维持启动期预热，只把"未授权"时的报错吞掉 | 改动最小 | `SCShareableContent` 未授权时调用**就会**拉起系统窗，吞错误不解决问题 | 否 |
| B 启动期用 `CGRequestScreenCaptureAccess()` 显式申请一次 | 能拿到权限 | 正是用户要禁的行为：未点任何按钮就弹系统窗且每次启动重复 | 否 |
| C 采集对象后移到使用时（采纳） | 启动期零 TCC 触发；授权后与上游观感一致 | 未授权期间不预热 filter；授权需重启 App，重启后照常预热 | **采用** |
| D 插件缺权限时直接 `NSWorkspace.open` 系统设置 | 少一次点击 | 用户明确否决（先弹窗）；绕过唯一权限链路，不可审计 | 否 |
| E 给 `HostController` 加"缺权限自动弹窗"的宿主级守卫 | 插件零改动 | 宿主无法判断"何时真的需要"；会变成另一处启动期打扰 | 否 |

## Consequences(影响)

- `Plugins/CameraPlugin/`：`attachServices` 不再建采集输入；`startSession()` 内建输入；gate 不再直开系统设置；`CameraStore` 增加激活重取与 `isConfigured` 只读暴露（给回归测试）。
- `Plugins/LidAngleDepthPlugin/`：`ScreenStreamer`/`ScreenSnapshotter` 增加权限前置（带默认值的注入点）；控制器不再在启动期预热；控制台块与设置页补缺权限引导按钮；新增文案键 `console.grant`(+`.help`)。
- `docs/agents/系统集成与多语言.md` 红线补一条：**启动/装载期不得触碰会拉起系统授权窗的 API**。
- 回归：`CameraPluginTests`（attach 不得配置采集会话）、`LidAngleDepthPluginTests`（无权限 `ScreenStreamer.start()` 必须是空操作）。

## Changelog

- v1.0.0:初稿（三处启动期/直开系统设置的越界修正；采集对象后移；缺权限的唯一入口收敛到权限弹窗）。
