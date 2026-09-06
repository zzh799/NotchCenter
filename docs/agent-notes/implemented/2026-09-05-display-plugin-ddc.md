# Agent Note:显示器亮度插件(DDC/CI 双后端，私有符号 dlopen 封装)

status: implemented
date: 2026-09-05
deciders: zeaven
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 官方插件新增「外接显示器亮度调节」（`Plugins/DisplayPlugin/`，块 `brightness.sliders`）。macOS 系统亮度键只管内建屏，外接屏亮度需经 DDC/CI（VCP 0x10）控制。
- 硬约束：App 未沙盒化（无 entitlements），进程内直调 IOKit 可行；App 是 arm64 + x86_64 通用二进制，DDC 的 Apple Silicon 路线（IOAVService 一族）符号在 Intel 切片不存在；宿主已有「私有 API + 优雅降级」先例（MediaControlsPlugin 的 `MediaRemoteSession`）。
- 范围决策（与需求方 grilling 会话定案）：v1 只做亮度；只列外接 DDC 可用屏，内建屏 / 虚拟屏 / 镜像非主屏不显示；不做亮度持久化恢复、低亮度 gamma 压暗、亮度键拦截、紧凑区 / 活动摘要入口；Intel 也要支持。

## Decision(决策)

- **双后端 + 单一帧编解码**：`DisplayDDCBackend` 协议下两个实现——Apple Silicon 走 `IOAVServiceBackend`（行为忠实移植 m1ddc，MIT，署名于文件头与插件 README）；Intel 走 `IOI2CBackend`（Apple 公开 IOGraphicsLib / IOI2CInterface API + VESA DDC/CI 帧）。选择逻辑：IOAVService 符号 dlsym 可解析即用之，否则回退 IOI2C。
- **私有符号只在 `IOAVServiceBackend` 一个文件内接触**，dlopen/dlsym 惰性解析 + 进程级缓存，与 `MediaRemoteSession` 同一封装形态；符号缺失即整体降级，绝不崩溃。`CoreDisplay_DisplayCreateInfoDictionary` 的宿主框架随系统版本漂移：macOS 14 及更早在 CoreDisplay，macOS 15 起框架移除、符号由 DisplayServices 承接（SkyLight 亦再导出）——解析按此顺序逐个探测（真机 macOS 15.6 已验证枚举 + 读 + 回写全链路）。
- **写入走串行合并通道**（`DDCWriteChannel` actor + `CoalescedWriteStateMachine`）：任一时刻至多一次 DDC 传输在途，在途期间只保留最新值，完成后补写终值，两次写入至少间隔 80ms——拖动滑杆的连发请求不会打满 DDC 总线。
- **初值回读 300ms 超时**，失败回退内存缓存或 50%（部分屏不支持回读，不视为不可调节）；「不可调节」以**连续两次写入失败**判定，命中后隐藏该屏滑杆行。
- **块不做滑动让路声明**（2026-09-06 修订）：初版按"滑杆以非 ScrollView 机制消费横向输入"声明 `scrollUsage: .always` 无条件让路；实测滑杆只经命中测试消费鼠标拖拽、不消费滚轮横向增量，整块让路反而造成"块上无法滑动切页"。同日 `BlockScrollUsage` 声明体系随最低支持提至 macOS 15 整体删除（探针反向推断恒可信），块上让路统一由宿主 `DrawerScrollProbe` 核实横向溢出。
- Intel 实现未经真机验证（开发机为 Apple Silicon），帧编解码 / 映射 / 合并逻辑由 `DisplayPluginTests` 覆盖；README 明示此边界。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. IOAVService 路线纯 Swift 移植进插件（m1ddc/MIT） | 无外部进程、错误处理与串行化在进程内可控、分发干净 | 需 dlopen 私有符号（有 MediaRemote 先例兜底） | ✅ 采用 |
| B. 随应用打包 m1ddc 二进制 shell 调用 | 零移植成本 | 多进程分发与签名负担、结构化错误处理差、build.sh 无携带可执行文件的通道 | ❌ |
| C. CoreDisplay 私有 API（MonitorControl 主路线） | Apple Silicon 上无需 IORegistry 匹配 | 依赖更深的私有符号（CoreDisplay_DisplaySetValue 族）、分发不可控、与已有 IOAVService 参考实现相比无额外收益 | ❌ |
| D. Intel 不支持（启动时不声明块） | 最省事 | 需求方明确要求 Intel 可用 | ❌ |
| E. Intel 路线移植 ddcctl 源码 | 直接可用 | ddcctl 为 **GPLv3**，代码移植会污染仓库许可 | ❌ 仅作行为参照，按公开 IOKit API + VESA 帧自实现 |

## Consequences(影响)

- 新增 `Plugins/DisplayPlugin/`（无 Package.swift / build.sh 清单改动，自动发现）与 `Tests/NotchCenterTests/DisplayPluginTests.swift`；`LocalizationTests.modules` 增补该插件目录。
- 插件内私有 API 接触面新增一处（`IOAVServiceBackend`），与 `MediaRemoteSession` 并列为「dlopen/dlsym + 降级」范式的两个实例；后续同类需求照抄该形态。
- v1 已知边界（README 明示）：不监听显示器热插拔（增删屏后重启刷新；可调屏为空时重开抽屉会重新枚举）；IOI2C 路线在同型号双屏且 serial 为 0 时靠顺序对齐，可能混淆。
- 后续扩展点：VCP 特征码已是常量表（`VCPCode`），加对比度 / 音量只需扩编解码调用方与 UI；`DisplayListFilter` / `CoalescedWriteStateMachine` / `DDCPacketCodec` 均为纯逻辑可直接单测。

## Changelog

- v1.0.0:随 DisplayPlugin 首次落地创建。
- v1.0.1:`scrollUsage: .always` 决策修订为无声明（声明体系删除，探针统一判定）。
