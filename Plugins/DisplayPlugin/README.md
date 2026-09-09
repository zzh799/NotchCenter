# Display Brightness（显示器亮度）

经 DDC/CI 调节外接显示器亮度：抽屉块内每台外接屏一行滑杆，实时跟随拖动，写入串行合并不轰击总线。

## 提供的块

- **抽屉块 `brightness.sliders`**（中 / 大 / 超大，默认中）：每台可调外接屏一行「屏名 + 亮度滑杆」；没有可调外接屏时显示空态提示。
- **抽屉块 `brightness.single`**（单屏条，一实例一屏）：小单元整块当进度条（竖条自底 / 横条自左填充），大单元（单元任一轴 >100）切标题 + 药丸滑杆；1×1 为启动器（点按/长按弹浮窗调光）。

## 支持的显示器

- **Apple Silicon**：IOAVService 路线，行为忠实移植自 [m1ddc](https://github.com/waydabber/m1ddc)（MIT License, Copyright (c) 2021 waydabber），支持 USB-C / DisplayPort Alt Mode 与受支持的内建 HDMI 口；MCDP29xx 转换芯片自动切换 0xB7 芯片地址。
- **Intel**：IOKit IOI2C 公开 API（IOGraphicsLib / IOI2CInterface）+ VESA DDC/CI 标准帧实现，思路参考 MonitorControl 与 ddcctl（后者仅作行为参照，未复制代码）。⚠️ Intel 实现未经真机验证（开发机为 Apple Silicon），帧编解码与值映射有单测覆盖，欢迎 Intel 用户反馈。
- 内建屏不走 DDC（交给系统亮度键），不显示；虚拟屏（Sidecar / AirPlay）与镜像组非主屏不显示；不支持 DDC/CI 的外接屏（部分转接坞 / 采集卡）不出现在列表中。

## 实现说明

- 初值在块首次出现时回读显示器（300ms 超时），失败回退内存缓存或 50%——部分显示器不支持回读，回读失败不代表不可调节。回读期间该行只显示空槽占位，不渲染 0 值滑杆（避免初值落定时被动画事务插值成「从 0 涨到当前亮度」）。
- 写入经串行合并通道（`DDCWriteChannel`）：任一时刻至多一次 DDC 传输在途，拖动中只保留最新值、完成后补写终值，两次写入至少间隔 80ms。
- 连续两次写入失败判定该屏不可调节，滑杆行自动隐藏。
- 私有符号（IOAVService 一族与 CoreDisplay 显示信息字典）仅经 dlopen/dlsym 运行时访问，封装在 `IOAVServiceBackend`（插件内唯一私有 API 接触面）；符号缺失（Intel）时自动回退 IOI2C 路线，均不可用时显示空态，绝不崩溃。

## 注意

- v1 不做开机亮度恢复、低于硬件最小亮度的压暗、亮度键拦截与紧凑区入口。
- 显示器列表在首次展开抽屉时枚举；运行期间监听屏幕参数变化（`didChangeScreenParametersNotification`，与宿主重建布局同一事件）做差量刷新——拔出屏的滑杆行即时消失、新屏即时出现、存活屏状态保留。已知边界：同一物理屏以新 `CGDirectDisplayID` 重连时，亮度内存缓存按 id 键控匹配不到，初值回退 50%。
- 该块不声明滑动让路（2026-09-06 修订，见 Agent Note）；滑杆只经命中测试消费鼠标拖拽、不消费滚轮横向增量，块上横向轻扫照常切页。
