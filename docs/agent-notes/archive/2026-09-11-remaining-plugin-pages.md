# Agent Note:剩余 P0/P1 插件页面（日历待办 / AI 监控 / 天气 / 摄像头 / 截图 OCR / 会议 / 效率与运维）

status: archived
date: 2026-09-11
deciders: 用户（勾选「继续实现 P0/P1 剩余全部项」）+ 实现代理
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 用户在 `docs/插件页面选题调研.md` 的候选清单里勾选了全部剩余 P0/P1 项，要求逐条实现、每条一个 commit。
- 渲染契约已在 `2026-09-10-drop-exclusive-page-blocks` 定稿：**不存在 `BlockKind.page`**。所有大页面 = 普通 `.drawer` 块 + `minSize/maxSize/recommendedSize` 三档 + `placement: .newPageWhenOccupied` + `symbolName`，**必须声明 `probes`**，**不得自套 `ScrollView`**（宿主已把抽屉块放进抽屉滚动容器）。
- 权限侧由同批的 `2026-09-11-permission-management-panel` 提供统一出口：`HostController.permissionStatus(of:)` 查询 + `presentPermissions(_:)` 弹窗引导。**权限缺失只改变块内呈现（引导态），块本身仍渲染、仍可交互、不报错**（`docs/插件页面选题调研.md` §6 纪律）。
- 不引入新的 SPM 远程依赖；不新增任何硬编码的 API key / token。
- 不做（out of scope，理由见各自小节）：通知镜像、iMessage、锁屏组件、终端页、全局文本展开、浏览器下载进度、GPU/SMC 温度、`ScreenCaptureKit` 的窗口/应用选择器高级形态、GitLab 之外的托管平台、非 GitHub 的 CI 厂商。

## Decision(决策)

### 1 插件切分：按数据源与权限边界拆，不按 UI 形态拆

| 插件 | 目录 | 块 | 数据源 / 权限 |
|---|---|---|---|
| CalendarPlugin | `Plugins/CalendarPlugin` | `calendar.month`（月视图+今日列表）、`calendar.today`（今日/明日日程）、`reminders.today`（待办清单） | EventKit（日历 + 提醒，两个授权） |
| MeetingPlugin | `Plugins/MeetingPlugin` | `meeting.next`（下一场倒计时 + 一键加入 + 静音/摄像头开关） | EventKit（复用日历授权）+ URL scheme |
| AgentMonitorPlugin | `Plugins/AgentMonitorPlugin` | `agent.monitor`（AI 代理状态总览） | 文件系统只读（`~/.claude` 等），**零系统权限** |
| WeatherPlugin | `Plugins/WeatherPlugin` | `weather.now`（当前天气 + 逐时/逐日） | `URLSession` → Open-Meteo（免 key），**零权限**（手填城市） |
| CameraPlugin | `Plugins/CameraPlugin` | `camera.mirror`（镜像预览）、`privacy.monitor`（摄像头/麦克风占用留痕） | AVFoundation（摄像头） |
| CapturePlugin | `Plugins/CapturePlugin` | `capture.ocr`（截图 + OCR + 取色） | ScreenCaptureKit（屏幕录制）+ Vision + `NSColorSampler` |
| WellnessPlugin | `Plugins/WellnessPlugin` | `wellness.eye`（20-20-20 全屏休息提醒 + 久坐/喝水 + 呼吸引导） | 纯本地计时 + 覆盖窗口，**零权限** |
| LauncherPlugin | `Plugins/LauncherPlugin` | `launcher.apps`（应用/文件快速启动） | `NSWorkspace` + `NSMetadataQuery`，**零权限** |
| FileConvertPlugin | `Plugins/FileConvertPlugin` | `convert.files`（图片/视频/PDF 转换与压缩） | ImageIO / PDFKit / AVFoundation，**零权限** |
| DeviceStatusPlugin | `Plugins/DeviceStatusPlugin` | `device.battery`（电池健康/循环/温度 + 蓝牙外设电量） | IOKit（`IOPSCopyPowerSourcesInfo`），**零权限** |
| DevPanelPlugin | `Plugins/DevPanelPlugin` | `dev.panel`（PR / Issue / CI 一览） | `URLSession` → GitHub API + **Keychain** 存 token，**零权限** |
| ServicesPanelPlugin | `Plugins/ServicesPanelPlugin` | `services.panel`（launchd 服务 + brew 包状态） | `LaunchdControlKit` + `brew` CLI，**零权限** |

- **为什么日历与待办放一个插件**：同源 EventKit、同一份 `EKEventStore`、同一个「今日」时间轴，拆开会让两页各持一个 store 并各自请求授权（用户看到两次系统弹窗）。会议助手**拆出去**是因为它只读日历且以 URL scheme 为主，独立插件可单独禁用。
- **为什么摄像头与隐私监控同插件**：两者都只依赖 `AVCaptureDevice` 的公开占用属性，同源同权限，拆开没有收益。

### 2 各页面的关键取舍

- **日历页**：`EKEventStore` + `events(matching:)` 谓词取当月/当日；月视图自绘（日历网格是纯数学，可单测）。「一键加入会议」解析 Zoom / Google Meet / Teams / Webex URL——**解析是纯函数**，放独立类型单测。macOS 15+ 用 `requestFullAccessToEvents()`（旧 `requestAccess(to:)` 在 15 上已废弃）。
- **待办页**：`EKReminder` 列表 + 到期分组（逾期/今天/明天/以后/无日期，分组是纯函数）。勾选走 `EKEventStore.save`。
- **AI 监控页**：可插拔 `AgentProvider` 协议 + 适配器注册表。本批落地 **2 个真实适配器**（Claude Code 的 `~/.claude/projects/**/*.jsonl` 会话文件、Codex 的 `~/.codex/sessions/**`），其余（Cursor / Windsurf）留**明确的扩展位**并在 UI 里显示"尚未支持"——**不伪造数据**：目录不存在、文件解析不出状态一律显示空态。文件监听用 `DispatchSource`（目录级）+ 全量重扫，不用 FSEvents（`DispatchSource` 无 C 回调跨线程负担）。**只读文件名/时间戳/JSON 里显式的状态字段，不读代码与聊天内容**，README 明写。
- **天气页**：Open-Meteo（`api.open-meteo.com`，免 key）。**默认手填城市**（经 Open-Meteo 的 geocoding 接口把城市名换成坐标），定位权限**不申请**——`SystemPermission.location` 在权限弹窗里仍列出（诚实告知可选项），但 `PermissionCenter.status(of: .location)` 恒为 `.notDetermined` 且请求返回 `.failed`，UI 明说"请手动填写城市"。网络失败/无数据 → 空态 + 重试按钮，绝不显示假数据。
- **摄像头镜像**：`AVCaptureSession` + `AVCaptureVideoPreviewLayer` 走 `NSViewRepresentable`。权限被拒 → 引导态（走权限弹窗），不崩不报错。
- **隐私监控**：`AVCaptureDevice.isInUseByAnotherApplication`（**公开属性**）+ 麦克风侧 `kAudioDevicePropertyDeviceIsRunningSomewhere`（AudioToolbox 公开 API）轮询，变化时留痕（进入/退出的时间戳列表，存 `StateStore`）。**不读进程名**（那要私有 API 或额外权限），只记"何时被占用"。
- **截图 + OCR**：`SCScreenshotManager.captureImage`（macOS 14+）截全屏 → Vision `VNRecognizeTextRequest` OCR；取色走 `NSColorSampler`。**屏幕录制授权后必须重启 App**，UI 里明说并在权限弹窗的该行挂 `requiresRelaunch` 提示。**明确没做**：交互式框选（`SCStream` 的实时几何选择器是重活，本批只做全屏截图 + 可选的区域裁剪坐标）。
- **会议助手**：复用日历授权，取"下一场带会议链接的事件"，倒计时用 `TimelineView`。静音/摄像头开关 = 调 `osascript` 设置系统输入设备音量/触发摄像头禁用——**明确没做**：没有公开 API 能可靠地"静音系统麦克风"（`AudioObjectSetPropertyData` 设 `kAudioDevicePropertyMute` 只在部分设备可用），本批只做**跳转/打开**类动作与"打开会议链接"，开关按钮标注为"打开系统设置面板"。诚实降级而非假装可用。
- **护眼与数字健康**：`Timer` 驱动 20-20-20；全屏休息提醒用 borderless `NSPanel` 覆盖窗口（含呼吸引导动画）。**覆盖窗口是插件自有窗口**，`pluginWasDisabled` 必须关掉（插件开发约定 §3.4）。
- **启动器**：`NSMetadataQuery` 查 `kMDItemContentTypeTree == public.application`；搜索过滤是纯函数（模糊子序列匹配）。**明确没做**：不索引全盘文件（只查应用 + 用户指定目录），不做命令执行（安全边界）。
- **文件转换**：ImageIO（HEIC/JPEG/PNG/WebP 互转 + 质量压缩）、PDFKit（合并/拆页/压缩）、AVFoundation（视频转码 presets）。**转换参数推导是纯函数**（输出尺寸/质量/格式），实际转换在 `Task.detached` 后台跑。
- **电池与设备**：`IOPSCopyPowerSourcesInfo` + `IOPSCopyPowerSourcesList` 取电池快照（健康/循环/温度经 `IORegistryEntryCreateCFProperty` 读 `AppleSmartBattery`）。**明确没做**：蓝牙外设电量——`IOBluetooth` 的 `batteryPercent` 是**私有/未公开**属性，本批不碰；README 与 note 都写明降级为"暂不支持"。
- **代码托管面板**：`URLSession` 直连 GitHub REST API（`/issues?filter=created`、`/pulls`、Actions runs）。token 存 **Keychain**（`Security` 框架，`kSecClassGenericPassword`）。**Keychain 读写全部经协议注入**，单测用假实现（绝不真写 Keychain）。未配置 token → 显示"未配置"引导，不发请求。
- **服务与包管理**：launchd 侧复用 `LaunchdControlKit`（`Plugin.plist` 的 `Dependencies` 声明，已在 `Project.swift` 白名单里）；brew 侧 `brew list --versions` / `brew outdated --json=v2`，**输出解析是纯函数**。**明确没做**：不做 `brew upgrade` 的一键批量执行（长任务 + 需要用户在场确认），只提供单项升级入口 + 打开终端提示。

### 3 probes 声明纪律

所有新增 `.drawer` 块**必须**声明 `probes`（`verify-sizes` 硬门禁）。大页面的探针只声明"必须完整可见"的区带（顶部标题栏 / 关键动作行），**中段自适应区域不声明**——纵向内容多的页面在 `minSize` 下收缩中段是设计意图，把它声明成探针会让门禁误报越界。探针一律只依赖 `info.frame.size`。

### 4 多实例状态与共享数据

- 每实例设置（如天气城市、启动器搜索范围）走 `BlockContext.placementStore` + `NotchBlock.instanceSettingsView` + `placementWasRemoved` 三件套。
- 插件级共享（如 AgentMonitor 的文件监听、天气的 HTTP 缓存、设备状态的采样结果）走插件级单例 store，多屏同实例的视图副本观察同一个 `ObservableObject`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 日历与待办拆成两个插件 | 各自独立可禁用 | 两个 `EKEventStore`、两次系统授权弹窗、无法共享「今日」时间轴 | 否（合一） |
| 日历与待办合成**一个**大页面块 | 用户一眼看全 | 月视图 + 清单挤一屏，`minSize` 下必然要牺牲一方；且用户可能只想要待办 | 否（两块同插件，可分别放置） |
| AI 监控用 FSEvents | 系统级、递归天然 | C 回调跨线程 + `@MainActor` 隔离成本高；目录级 `DispatchSource` 对本场景（少数几个固定目录）足够 | 否 |
| AI 监控猜测/推断代理状态 | "看起来更满" | 伪造数据，用户按错误状态行动（以为跑完了其实没有） | 否（读不到就空态） |
| 天气申请定位权限 | 免手填 | 为一次 HTTP 查询换一个隐私权限，收益远小于成本；且开发态裸二进制下定位授权无法稳定验证 | 否（手填城市，定位作为清单里的"可选"项诚实列出） |
| 截图做交互式框选 | 体验完整 | `SCStream` 实时选择器 + 覆盖窗口 + 多屏坐标是重活，本批投入产出比低 | 否（全屏截图 + 手动区域裁剪） |
| 会议助手用私有 API 控制系统麦克风静音 | 一键真静音 | 无公开可靠 API；硬做会时灵时不灵 | 否（打开系统设置面板，诚实降级） |
| 蓝牙电量走 `IOBluetooth` 私有属性 | 功能完整 | 私有属性、版本间会变、审核风险 | 否（降级为"暂不支持"，写进 README） |
| Keychain 直接写在 store 里 | 代码更少 | 单测会真写 Keychain，违反测试隔离纪律 | 否（协议 + 假实现注入） |
| 每个功能一个 commit | 语义清晰、易回滚 | 无 | 是 |

## Consequences(影响)

- **新增**：12 个插件目录（各含 `Plugin.plist` / `README.md` / `Sources/` / `Resources/{en,zh-Hans}.lproj`），全部由 `Project.swift` 自动发现，不改任何插件列表。**新建插件后必须 `tuist clean` 再 `tuist generate`**（GenerationMetadata 缓存会吞掉新目录）。
- **测试**：新增套件覆盖会议链接解析、日程分组排序、提醒分组、AI 状态文件解析、天气响应解析与降级、城市搜索、OCR 结果整理、护眼计时、启动器过滤、文件转换参数、电池读数换算、GitHub 响应解析、brew 输出解析、Keychain 假实现分支。全部依赖注入假实现，**不触发网络 / 摄像头 / 屏幕录制 / Keychain 写入 / 真实 `brew`**。
- **权限**：`Resources/Info.plist` 的用途键由同批权限 note 声明；本批插件只**消费** `HostController` 的权限通道，不新增权限。
- **门禁**：全部新块必须过 `verify-sizes`；新增 md 必须过 `run-doc-checks.sh` 九项。
- 落地后本 note 移入 `docs/agent-notes/implemented/`。

## Changelog

- v1.0.0:初稿（插件切分、各页面取舍与明确不做的部分、probes 纪律、多实例状态）。

- v1.1.0:归档（2026-09-19）。本规划对应的插件批次已由 `b980ae1` 回退（CalendarPlugin / MeetingPlugin / AgentMonitorPlugin 等目录均不存在），规划本身仍有效但暂不排期，故从 `proposed/` 移出归档，避免滞留门禁长期常红；重新排期时移回 `proposed/` 并更新 date。
