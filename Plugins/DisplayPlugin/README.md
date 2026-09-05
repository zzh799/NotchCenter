# Display Brightness（显示器亮度）

经 DDC/CI 调节外接显示器亮度：抽屉块内每台外接屏一行滑杆，实时跟随拖动，写入串行合并不轰击总线。

## 提供的块

- **抽屉块 `brightness.sliders`**（中 / 大 / 超大，默认中）：每台可调外接屏一行「屏名 + 亮度滑杆」；没有可调外接屏时显示空态提示。

## 支持的显示器

- **Apple Silicon**：IOAVService 路线，行为忠实移植自 [m1ddc](https://github.com/waydabber/m1ddc)（MIT License, Copyright (c) 2021 waydabber），支持 USB-C / DisplayPort Alt Mode 与受支持的内建 HDMI 口；MCDP29xx 转换芯片自动切换 0xB7 芯片地址。
- **Intel**：IOKit IOI2C 公开 API（IOGraphicsLib / IOI2CInterface）+ VESA DDC/CI 标准帧实现，思路参考 MonitorControl 与 ddcctl（后者仅作行为参照，未复制代码）。⚠️ Intel 实现未经真机验证（开发机为 Apple Silicon），帧编解码与值映射有单测覆盖，欢迎 Intel 用户反馈。
- 内建屏不走 DDC（交给系统亮度键），不显示；虚拟屏（Sidecar / AirPlay）与镜像组非主屏不显示；不支持 DDC/CI 的外接屏（部分转接坞 / 采集卡）不出现在列表中。

## 实现说明

- 初值在块首次出现时回读显示器（300ms 超时），失败回退内存缓存或 50%——部分显示器不支持回读，回读失败不代表不可调节。
- 写入经串行合并通道（`DDCWriteChannel`）：任一时刻至多一次 DDC 传输在途，拖动中只保留最新值、完成后补写终值，两次写入至少间隔 80ms。
- 连续两次写入失败判定该屏不可调节，滑杆行自动隐藏。
- 私有符号（IOAVService 一族与 CoreDisplay 显示信息字典）仅经 dlopen/dlsym 运行时访问，封装在 `IOAVServiceBackend`（插件内唯一私有 API 接触面）；符号缺失（Intel）时自动回退 IOI2C 路线，均不可用时显示空态，绝不崩溃。

## 注意

- v1 不做开机亮度恢复、低于硬件最小亮度的压暗、亮度键拦截与紧凑区入口。
- 显示器列表在首次展开抽屉时枚举，v1 不监听热插拔；增删显示器后重启 NotchCenter 刷新（一台可调屏都不在时重开抽屉会重新枚举）。
- 该块声明消费横向输入（滑杆拖动），在其上滑动不触发抽屉切页；切页请在块外滑动。
