# LidAngleKit

读 MacBook **上盖铰链角度**的可复用动态库。

它是 [合盖透视插件](../LidAngleDepthPlugin/README.md) 的传感器层，同时对外开放——任何插件都可以引用它，用来做「合盖时做点什么」的功能。

> 本库移植自 [Mac Duo](https://github.com/sumimakito/Mac-Duo) 的 `LidAngleKit`
> （Apache-2.0，版权归 Makito 所有），在其上增加了 `LidAngleMonitor` 状态机。
> 署名与逐文件对应关系见 [`../LidAngleDepthPlugin/NOTICE`](../LidAngleDepthPlugin/NOTICE)。

## 为什么它不在插件目录里

本目录**没有 `Plugin.plist`**，因为它不是插件，而是被插件链接的动态库。`Project.swift` 与 `scripts/build.sh` 各有一份显式白名单（`sharedLibraryDirNames` /`SHARED_LIBRARY_DIR_NAMES`）把它排除在插件发现之外，并在 targets 里单独登记。

在白名单里显式列出、而不是「没有 Plugin.plist 就跳过」，是刻意的：后者会让漏写元数据的插件被静默漏打包，而那是发现逻辑里那条 `guard` 专门要拦住的事故。

## 怎么用

在插件的 `Plugin.plist` 里声明依赖：

```xml
<key>Dependencies</key>
<array>
  <string>LidAngleKit</string>
</array>
```

然后：

```swift
import LidAngleKit

let monitor = LidAngleMonitor()
guard monitor.isAvailable else { return }   // 没有传感器的机型

monitor.onReading = { reading in
    // 回调在 start(on:) 指定的队列（默认主队列）上
    print(reading.angle ?? -1, reading.state)   // 角度、open/closing/closed
}
monitor.start(interval: LidAngleMonitor.idleInterval)
```

一次性问一次：

```swift
let reading = monitor.sampleNow()
if reading.state == .closed { /* 盖子合上了 */ }
```

## 两个类型

### `LidAngleSensor` — 裸传感器

`AppleSPUHIDDevice`（vendor `0x05AC` / product `0x8104`，usage page `0x20` / usage `0x8A`）。两份 feature report 携带同一个角度：

- report 7：5 字节，小端百分之一度（0.01° 步进）；
- report 1：3 字节，小端整度 —— 并非所有机型都声明 report 7，故以此兜底。

读数约每 100 ms 刷新一次，**不需要任何系统权限**。

`angle()` 返回 `nil` 表示读取失败，此时 `lastRead` 留有诊断信息。注意 **`0` 是合法读数**（完全合上），所以不要写 `angle() ?? 0` 把失败与「合上」混为一谈 —— 用 `LidState` 判定，或显式区分 `nil`。

### `LidAngleMonitor` — 带状态的轮询

把裸读数变成 `LidReading`（角度 + `LidState` + 角速度 + 是否新鲜读数）。

- 节拍：空闲 `idleInterval`（8 Hz）、活动 `activeInterval`（30 Hz）。跟随合盖动画时
  用后者，其余时候用前者。
- **线程**：实例不绑定主线程，`sampleNow()` 可在任意线程调用；`onReading` 在
  `start(on:)` 指定的队列上回调。传感器读取是同步阻塞的，别把它塞进主线程高频路径。
- 系统唤醒后必须调 `resetBaseline()`：否则「几乎合着醒过来」会被误判成正在合盖。

阈值可在构造时覆盖：

```swift
LidAngleMonitor(thresholds: LidThresholds(closedAngle: 3, closingSpeed: 12))
```

默认值与上游 Mac Duo 的判定口径一致。
