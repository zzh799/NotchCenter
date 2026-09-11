# 合盖透视（Lid Depth）

把 [Mac Duo](https://github.com/sumimakito/Mac-Duo) 的 iPhone Duo 式合盖效果带进 NotchCenter：合上 MacBook 时，屏幕内容随盖角在空间中向后翻转，越靠铰链越虚、越远越暗，最后归于黑场。

```text
PluginID     com.notchcenter.lidangledepth
版本         1.0.0
依赖         LidAngleKit（可复用动态库，盖角传感器）
```

## 它由三部分组成

| 部分 | 位置 | 说明 |
|---|---|---|
| 效果本体 | `DepthOverlay` + `DepthRenderer` | 一个覆盖内置屏全屏的无边框窗口。**不属于刘海的任何一种块**，窗口生命周期由插件自持 |
| 刘海侧入口 | 抽屉块 `lidangle.console`、设置界面、快捷按钮 `lidangle.toggle` | 效果是全屏的，刘海区放的是它的仪表盘与控制面 |
| 盖角感应 | `Plugins/LidAngleKit`（独立动态库） | 读上盖铰链角度并给出开合状态；**任何插件都能引用** |

## 用法

- **抽屉块「合盖透视」**：显示实时盖角、开合状态、一句总开关，以及一个随盖角收缩的
  透视示意条。不动机器也能按「试播」把效果演一遍。
- **快捷按钮**：总开关，可放进快速区或快捷按钮盒。
- **状态栏菜单**：试播效果 / 启用停用。
- **设置界面**：触发角、模糊跨度、最大模糊半径、变暗强度与范围、视距、透视强度、
  铰链边模糊；另有诊断区显示传感器与画面来源。

## 权限与降级

读盖角**不需要任何权限**（走 `AppleSPUHIDDevice` 的 HID feature report）。

实时跟随屏幕需要**屏幕录制**权限。这里刻意做成两档，而不是拿不到权限就整页报错：

| 档位 | 条件 | 表现 |
|---|---|---|
| 实时档（默认） | 屏幕录制已授权 | `ScreenCaptureKit` 实时流，画面与屏幕同步变化 |
| 静帧档 | 权限缺失，或实时流启动失败 | 合盖瞬间抓取的一帧，仍然有完整的透视/模糊/变暗 |
| 引导态 | 两档都拿不到画面 | 抽屉块提示「仅静帧」并给出跳转系统设置的入口 |

授权后**需要重启 App** 才生效（TCC 的屏幕录制走独立进程缓存），这一点在权限弹窗里有说明。

## 机型限制

只有带兼容盖角传感器（`AppleSPUHIDDevice`，usage page `0x20` / usage `0x8A`）的 MacBook 能用。没有传感器时：

- 抽屉块显示「无盖角传感器」降级态，设置与说明照常可用；
- 总开关与「试播」置灰；
- 插件不崩溃、不报错。

效果只作用于**内置屏**（合盖时看得见的就是它）。外接屏不受影响。

## 与上游 Mac-Duo 的差异

移植保持了渲染与几何的逐行一致，差异集中在宿主适配：

1. **覆盖窗层级**：上游用私有 `CGShieldingWindowLevel()`（屏保/屏蔽层级），会盖住
   NotchCenter 自己的刘海面板与插件管理窗口。这里改用**屏保层级之下、状态栏之上**的一档，效果依然盖住普通应用与菜单栏，但宿主面板仍在最上面，用户随时能把抽屉拉出来关掉效果。
2. **设置落盘**：上游直写 `UserDefaults`；这里走宿主注入的 `StateStore`
   （按 pluginID 隔离、原子写），键名与出厂默认值与上游逐项一致，观感不变。
3. **权限降级**：上游只有实时档；这里增加静帧档与引导态（见上）。
4. **盖角状态**：上游只有裸读数，合盖判定散在 `LidController` 的速度阈值里；这里
   下沉到 `LidAngleKit` 的 `LidAngleMonitor`，暴露 `open` / `closing` / `closed`。
5. **Swift 6 严格并发**：上游编译在 Swift 5 模式。这里的 CaptureKit 类型
   （`SCContentFilter` / `SCStream` / `SCShareableContent`）都没有 `Sendable` 标注，交接处用显式的 `@unchecked Sendable` 信封承担保证，注释写明了理由。

## 署名

本插件是 Mac Duo 的移植作品。Mac Duo 版权归 Makito 所有，以 Apache-2.0 授权。逐文件对应关系见 [`NOTICE`](NOTICE)，完整许可证见 [`LICENSE-Mac-Duo`](LICENSE-Mac-Duo)。

## 相关文档

- 决策记录：[`docs/agent-notes/implemented/2026-09-11-lid-angle-depth-effect.md`](../../docs/agent-notes/implemented/2026-09-11-lid-angle-depth-effect.md)
- 插件开发指南：[`docs/插件开发指南.md`](../../docs/插件开发指南.md)
