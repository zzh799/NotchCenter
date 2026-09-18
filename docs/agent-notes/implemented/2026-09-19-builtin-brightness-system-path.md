# Agent Note: 显示器亮度插件支持内建屏（系统亮度通道）

status: implemented
date: 2026-09-19
deciders: 用户（提出「让屏幕控制插件支持控制内置屏幕的亮度」）；实现路径由本 note 定稿

## Context(背景与约束)

DisplayPlugin 现有能力只覆盖外接屏：DDC/CI 走显示器自己的 I2C 通道（Apple Silicon 经 IOAVService，Intel 经 IOI2C），`DisplayListFilter.externalCandidates` 显式排除内建屏，README 写明「内建屏不走 DDC，交给系统亮度键，不显示」。用户要求补齐内建屏。

硬约束：内建屏背光没有 DDC 通道（DDC 是显示器侧的外部 I2C 总线，笔记本内屏由 SoC 的 PWM/DPCD 背光控制），只能走系统通道——即 `DisplayServices` 私有框架，系统亮度键、控制中心滑杆、「自动调节亮度」用的都是它。真机（macOS 15.7.5 / arm64）实测：`DisplayServicesGetBrightness` / `SetBrightness` / `CanChangeBrightness` 与 `RegisterForBrightnessChangeNotifications` 全部可 dlsym 解析，读写 0...1 浮点，set→get 往返无量化误差（0.60 → 0.6000），注册通知后每次亮度变化回调携带新值。

范围外的部分（本轮不做）：经系统通道控制 Apple 外接屏（Studio Display / Pro Display XDR）——那是另一条 HID/DPCD 链路，本轮外接屏一律仍走 DDC；不做亮度键拦截、不做「低亮度压暗」（软件调光）、不做开机亮度恢复；不动自定义区间的持久化语义。

## Decision(决策)

- 抽象从「DDC 后端」升为「亮度后端」：`ExternalDisplay` → `BrightnessDisplay`（新增 `control: .ddc | .system` 字段），`DisplayDDCBackend` → `DisplayBrightnessBackend`，`DDCError` → `BrightnessError`；新增 `CompositeBrightnessBackend` 按 `control` 分发（内建屏走系统后端、外接屏走 IOAVService/IOI2C），原两个 DDC 后端实现零行为改动。枚举顺序固定内建屏在前、外接屏在后。
- 新增 `Sources/SystemBrightnessBackend.swift`：内建屏唯一后端，也是本插件第二处（继 IOAVService 之后）私有 API 接触面，符号经 dlopen/dlsym 解析；内建屏亮度是 0...1 浮点，插件统一按 0...100 整数表达（`SystemBrightnessMath` 纯函数，对齐 DDC 的百分比语义），于是现有 `percent ↔ 原始值` 映射、自定义区间、写入合并通道、初值回读超时全部原样复用。候选资格：`CGDisplayIsBuiltin` 且 `DisplayServicesCanChangeBrightness` 为真。
- 亮度键跟随：注册 `DisplayServicesRegisterForBrightnessChangeNotifications(id, id, callback)`（真机实测签名是 C 函数指针，不是 block——按 block 调用会直接段错误，见 Consequences），回调经全局中继转发到 MainActor，用 userInfo 里的新值直接更新 `model.percent`，不回读。两条抑制规则：`model.isDragging` 期间丢弃（本机写入同样触发通知，不抑制会把滑杆从用户手边拽回）；本机写入后 250ms 内丢弃（合并通道的尾随通知落定用户已松手的窗口）。
- 用户可见文案去 DDC 化：`range.section` 由「DDC 范围」改「亮度范围」（两块共用的区间编辑器对两条通道都成立），空态由「未检测到可调节的外接显示器」改「可调节的显示器」（内建屏现在也算候选），新增 `display.builtin.name`（「内建显示器」/「Built-in Display」）。存储键 `ddc.ranges` 与 `DDCLuminanceRange` 类型名不动——键控 displayID 的映射对两条通道同构，改名只会白丢存量设置。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 内建屏只读展示（滑杆禁用，提示用系统键） | 零写入风险 | 不满足需求本身 | 否决 |
| `CoreDisplay_Display_SetUserBrightness` 读写 | 符号在 .tbd 里、比私有框架「公开」 | Apple Silicon 不生效，且无成功/失败反馈（nriley/brightness 的结论） | 否决 |
| 内建屏单独成区 / 单独一个块 | 不动现有列表语义 | 单屏条块要绑定内建屏，枚举必须归一；UI 两套列表徒增复杂度 | 否决，统一进同一 `rows` |
| 定时轮询 `GetBrightness` 跟系统键变化 | 不碰通知注册 | 常驻唤醒 + 必须按 `\.isDrawerPresented` 收尾，成本高于收益；通知本就带新值 | 否决 |
| 保留 `ExternalDisplay` 名字，另加 `isBuiltin` 标志 | diff 更小 | 内建屏叫「External」是长期误导，注释补丁塌陷 | 否决，一次性改名 |
| 通知里拿到值就无条件回灌 UI | 实现最短 | 自写自读会把拖动中的滑杆拽回旧值（真机实测 set 必触发通知） | 否决，加 isDragging + 250ms 双抑制 |

## Consequences(影响)

- 代码：`DDCBackend.swift` 协议/类型改名（`BrightnessDisplay` / `DisplayBrightnessBackend` / `BrightnessError` / `BrightnessWriteChannel`，文件改名 `BrightnessBackend.swift`，新增 `CompositeBackend` 与 `DisplayDescriptor.online()`）+ 新增 `SystemBrightnessBackend.swift`；`BrightnessController` 增观察生命周期（`startIfNeeded` / `runEnumeration` / `resume` 三处幂等建立，`suspend` 时撤销——已挂载的块不会重跑 `.task`，`resume` 是禁用—启用往返的唯一补建点）与 `applySystemBrightness` 回灌入口；视图、块定义、Kit 零改动（`rows` 语义不变）。
- 行为变更（存量用户可见）：`brightness.single` 的「跟随第一台显示器」现在跟到内建屏（内建屏排在 `rows` 首位），此前跟的是第一台外接屏。需要固定跟外接屏的实例在齿轮里显式选屏即可；不改存储、不迁移。
- 私有 API 从一处变两处：IOAVService 一族（外接屏）与 DisplayServices（内建屏，且 `CoreDisplay_DisplayCreateInfoDictionary` 本来就借道 DisplayServices）。两者都在符号缺失时优雅降级——系统后端解析不到符号就不出内建屏行，不崩。
- 测试：`DisplayPluginTests` 增内建候选过滤、`SystemBrightnessMath` 映射、Composite 按 `control` 分发、假后端驱动的通知回灌与「拖动中不覆盖」用例；既有 DDC 用例只随类型改名机械更新。
- 文档：插件 README「支持的显示器」「实现说明」「注意」三段重写，`Plugin.plist` 描述补内建屏，en/zh-Hans 键集合同步（`LocalizationTests` 强制奇偶）。
- 已知边界（写进 README）：「自动调节亮度」开启时系统会自发改内建屏亮度，可能超出用户设的自定义区间（此时滑杆钳在 0/100），插件不与之对抗。
- 实现落地后本 note `git mv` 至 `implemented/`。

## Changelog

- v1: proposed（2026-09-19，实现前落档）。
