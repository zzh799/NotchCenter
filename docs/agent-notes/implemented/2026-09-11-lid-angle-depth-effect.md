# Agent Note:刘海角度感应与合盖透视效果插件（移植 Mac-Duo）

status: implemented
date: 2026-09-11
deciders: zhouzihang

## Context（背景与约束）

- 需求：把 [Mac-Duo](https://github.com/sumimakito/Mac-Duo)（Apache-2.0）的「iPhone Duo 式合盖效果」移植为 NotchCenter 官方插件——合盖时内置屏内容做透视倾斜、高斯模糊与变暗，随盖角实时驱动。
- 上游能力由三块组成：`LidAngleKit`（`AppleSPUHIDDevice` 私有 HID 读盖角）、`ScreenSnapshotter`/`ScreenStreamer`（ScreenCaptureKit 单帧预热与实时流）、`DepthOverlay` + Metal 渲染器（全屏覆盖窗）。
- 本机已验证具备角度传感器（vendor `0x05AC` / product `0x8104`，usage page `0x20` / usage `0x8A`；report 7 读数 0.01° 步进，report 1 为 1° 兜底），无需额外权限即可读角。
- 约束：
  - **效果本身不是"块"**：覆盖窗盖满整屏（含菜单栏），必须由插件自持窗口生命周期，不能进抽屉视图树。
  - 宿主此前**从未有任何插件使用屏幕录制权限**（`SystemPermission.screenRecording` 在册但无消费方）。实时流是首个消费方，权限缺失时的降级路径必须成立。
  - 上游窗口用私有 `CGShieldingWindowLevel()` 且 `collectionBehavior` 含 `.fullScreenAuxiliary`；宿主自身有刘海面板窗口层级，两者必须不打架（见 [面板与抽屉](../../agents/面板与抽屉.md)）。
  - 上游代码是 `swiftLanguageMode(.v5)` 的独立 SPM 包；本仓库是 **Swift 6 严格并发 + `@MainActor` 隔离**（[插件开发指南](../../插件开发指南.md) §5）。
  - 状态持久化必须走 `StateStore`，不能像上游那样直接写 `UserDefaults`。
- Out of scope：不做 iPhone 侧联动；不做外接屏效果（上游同样只作用于内置屏）；不改宿主核心对屏幕录制权限的既有引导实现。

## Decision（决策）

### D1 复用库 `LidAngleKit`，而非把传感器塞进插件内部

- 位置 `Plugins/LidAngleKit/`，动态库 target，走 `Project.swift` 的 `knownExtraDependencies` 白名单 + `extraDependency(_:)` 映射（与 `LaunchdControlKit` 同族）；`build.sh` 的 Frameworks 组装需同步补一份（宿主不直接链接，Xcode 不会自动嵌入）。
- 对外暴露：盖角读数、可用性、分辨率档位、**合盖/开合状态**（上游只有裸读数，合盖语义由 `LidController` 的速度阈值承担；这里把阈值判定下沉到库里，插件与第三方都能用）。
- 传感器无权限依赖，因此该库对第三方插件零门槛。

### D2 效果忠实移植，但权限降级为**两档**

- 实时档（默认）：`ScreenStreamer` + Metal 实时流，效果最贴近上游。
- 降级档：`ScreenSnapshotter` 单帧（合盖前预热抓帧）。**屏幕录制权限缺失或实时流启动失败时自动落到本档**，而不是整页报错——符合 [插件开发指南](../../插件开发指南.md) §"权限要诚实"的降级纪律。
- 两档都不可用时（无权限 + 抓帧失败）：抽屉块显示引导态，「去系统设置」按钮走 `hostController.presentPermissions([.screenRecording])`。

### D3 覆盖窗层级不用 `CGShieldingWindowLevel`

- 上游的屏蔽层级会盖住宿主自己的刘海面板；改为屏幕保护层级之下的一档，并在效果激活期间不接收事件（`ignoresMouseEvents = true`），点击照旧穿透。
- 窗口只在**内置屏**上创建，`collectionBehavior` 保留 `.canJoinAllSpaces` / `.stationary`。

### D4 刘海侧呈现：抽屉块（控制台）+ 设置页 + 快捷按钮

- 抽屉块 `lidangle.console`：实时盖角仪表 + 合盖状态 + 开关 + 「试播效果」；声明 `probes`（官方 drawer 块门禁强制，`verify-sizes` 校验）。
- 设置页：阈值角、模糊跨度、最大模糊半径、变暗强度、视距比、透视后退比、实时/单帧档位。
- 快捷按钮 `lidangle.toggle`：总开关，状态与 store 双向同步。

### D5 屏幕录制权限：惰性触发，不在装载期预热

- 抓帧预热会枚举窗口（`SCShareableContent`），**未授权时那次调用本身就是系统授权窗的触发点**。因此 `LidDepthController.start()` 在无权限时直接返回，不预热、不抓帧。
- 权限一律由用户在宿主的权限弹窗内显式发起（`hostController.presentPermissions([.screenRecording])`），插件不代开系统设置、不在启动或装载时无条件弹窗。
- 缺权限时抽屉块与设置页显示引导按钮，盖角读数与开关照常可用。
- 授权后需**重启 App**（TCC 的屏幕录制走独立进程缓存），重启即预热，手感不受影响。

### D6 上游许可与署名

Mac-Duo 为 Apache-2.0。移植代码在 `Plugins/LidAngleDepthPlugin/NOTICE`（含逐文件对应表）与 `LICENSE-Mac-Duo` 中保留原始版权与来源声明，满足许可证的署名义务；每个移植文件头部注明上游文件名与「与上游的差异」。

## Alternatives considered（备选方案）

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 仅角度感应，不做效果 | 工作量最小、零权限 | 丢掉上游全部价值，用户要的是效果 | 否 |
| B 完整移植（本决策） | 与原版观感一致 | 引入 Metal + ScreenCaptureKit + 私有层级，约 1000+ 行 | **采用** |
| C 用 Core Image 近似替代 Metal | 代码量小很多 | 每帧 CPU/CI 开销大，60fps 实时流会掉帧 | 否 |
| D 传感器写死在插件内 | 不用动 Project.swift | 第三方插件无法复用；`LidAngleKit` 本就是独立库 | 否 |
| E `LidAngleKit` 挪出 `Plugins/` 目录 | 不必改发现逻辑 | 破坏「插件资产集中在 Plugins/」的既有约定 | 否 |

## Consequences（影响）

- `Project.swift`：白名单 `sharedLibraryDirNames` 加 `LidAngleKit`（**白名单而非「没有 Plugin.plist 就跳过」**——后者会让漏写元数据的插件被静默漏打包）；`knownExtraDependencies` 与 `extraDependency` 补映射；targets 加一项动态库；测试 target 显式依赖它。
- `scripts/build.sh`：`SHARED_LIBRARY_DIR_NAMES` 常量 + 发现循环跳过；Frameworks 组装与 ad-hoc 重签补 `libLidAngleKit.dylib`（同 `LaunchdControlKit` 的处理，dev 与 package 两条路径都要）。
- `Tests/NotchCenterTests/LocalizationTests.swift`：模块清单加 `Plugins/LidAngleDepthPlugin`（该清单是硬编码列表，新增官方插件必须登记，否则键位奇偶校验不覆盖）。
- 屏幕录制权限出现**首个消费方**，两档降级路径见 D2/D5。
- 新增插件目录 `Plugins/LidAngleDepthPlugin/` 与库目录 `Plugins/LidAngleKit/`，前者随目录自动发现，PluginManager 无需改动。
- Swift 6 严格并发适配：上游编译在 Swift 5 模式，其 `nonisolated` 存储属性与 CaptureKit 交接在本仓库都要改写。新增两个 `@unchecked Sendable` 信封（`ScreenCaptureFilterBox` / `ScreenStreamBox`），理由写在各自注释里；这是**有意识的 unsafe 承诺**，不是绕过检查。

## 已知缺口

- 仓库声明了 `NotchCenterTests/BlockMinSizeVerificationTests`（官方抽屉块最小尺寸门禁），
  但该测试类**在 `Tests/` 下并不存在**——`verify-sizes` 实际只跑到 `BlockSizeVerifierTests` 的纯几何单测，没有任何官方块被真正校验。本插件的 `probes` 因此只经过人工推导，未经门禁验证。修复该门禁超出本决策范围，另开。

## Changelog

- v1.0.0:初稿（移植 Mac-Duo 为 NotchCenter 插件，含复用库 LidAngleKit 与两档权限降级）。
- v1.1.0:实现落地；补 D5 屏幕录制惰性触发、E 备选方案、Consequences 落点与「已知缺口」。
