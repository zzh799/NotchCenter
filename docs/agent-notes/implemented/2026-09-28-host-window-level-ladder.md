# Agent Note: 窗口层级阶梯单一真源 + 系统辅助窗口抬层级收口

status: implemented
date: 2026-09-28
deciders: 用户（拍板：提交相册插件后顺手梳理全部被本程序遮挡的窗口，并给统一方案，按全量落地执行）
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

相册插件的本地文件选择面板被本程序自己的界面整个压住（用户实测报「文件选择窗被挡住」），修法是 `AlbumLocalPicker`：非模态 `begin` + 抬到 `.statusBar + 3` + 长寿命持有者。修完之后要回答的问题是**还有哪些窗口会栽在同一坑里**，以及怎么让这类问题不再逐个复发。

根因不是某一个面板写错了，而是**没有层级真源**：宿主面板刻意压在系统常规窗层之上（抽屉要盖住其他应用），而系统出品的辅助窗口默认层级极低，且**层级是全局排序** - 低层级窗口永远渲染在高层级窗口之下，与谁是 key、谁后 `orderFront` 无关。于是「从自己界面里弹一个系统窗口」只要忘了抬层级，就被自己的界面压住，表象是「点了没反应」。

实测（`CGWindowListCopyWindowInfo` 前后序 + 层级探针，macOS 15，accessory 应用）：

| 窗口 | 位置 | 实测层级 | 判定 |
|---|---|---|---|
| 插件安装 `NSOpenPanel`（`PluginManagerWindow.installBundle`） | `runModal` | **0** | 被遮挡：设置窗为 101 |
| 停用 / 卸载插件确认 `NSAlert` | `runModal` | **8**（`runModal` 强制覆盖，事先设任何层级都无效） | 被遮挡：设置窗为 101 |
| 「抽屉页已满」提示 `NSAlert` | `runModal` | **8** | 同上 |
| 文件架 Quick Look `QLPreviewPanel` | `makeKeyAndOrderFront` | **9**（每次首次显示都会把层级重置回 9） | 被遮挡：抽屉 25 / 块浮窗 27 |
| SwiftUI `.alert`（`PluginManagerWindow`） | - | **101，跟随宿主窗并排在宿主之上** | 安全，无需改 |
| TCC 系统授权弹窗（`PermissionCenter` 触发） | - | 系统层，最高 | 安全，无需改 |
| 相册本地选择面板 | - | 28 | 已在本轮前一 commit 修复 |

同时，层级字面量散落八处（`popUpMenuWindow` 表达式重复 4 遍、`.statusBar ± n` 手挑 3 组、屏保层 -1 一处），没有任何排序定义 - 这正是相册面板能漏过去的原因。

明确不做（out of scope）：不改抽屉/浮窗/设置窗之间的相对次序（现有观感与摆位逻辑依赖它）；不把设置窗内的确认弹窗改造成内联浮窗（`PluginManagerView` 的开关走「影子值 + 取消回滚」的同步语义，改成异步会动到行为）；`SizeLabWindow`（DEBUG 专用诊断窗）保持普通层级不动 - 它是用来横向比对块尺寸的诊断视图，抬到常驻置顶反而干扰。

## Decision(决策)

**一、层级阶梯进 Kit，成为唯一真源。** 新增 `Sources/NotchCenterKit/HostWindowLevel.swift`：公开的有序常量，宿主与插件一律从阶梯取名，不再写层级字面量。

```text
drawer        25   抽屉面板 / 紧凑热区
popover       27   块浮窗 / 设置浮窗
drawerAuxiliary 28 抽屉域内的系统辅助窗口（文件面板、Quick Look）
utility      101   设置窗 / 权限引导窗
utilityAuxiliary 102 设置域内的系统辅助窗口与模态确认
dragPreview  103   拖拽预览面板
effectOverlay 999  全屏效果覆盖层（合盖透视）
```

**二、系统窗口的层级由锚点域推导，不手写。** 同一个类型里给 `HostWindowLevel.Anchor`（`.drawer` / `.utility`）与 `auxiliary(above:)`：抽屉域抬到 `drawerAuxiliary`，设置域抬到 `utilityAuxiliary`。契约是「任何不由我们创建、层级也不由我们决定的窗口，呈现前必须经这一个函数抬层级」。

**三、调用收口。** 新增 `Sources/NotchCenterKit/SystemFilePanelPresenter.swift`：文件面板的「非模态 `begin` + 抬层级 + 长寿命持有者」三条一次做掉，`AlbumPlugin` 的 `AlbumLocalPicker` 与宿主的插件安装面板共用。宿主内新增 `HostAlert.runModal(_:anchor:)`（`Sources/NotchCenter/HostAlert.swift`）收口 `NSAlert`：`runModal` 会把层级强制成 8，所以走「先 `layout()` 实例化窗口，模态循环起来后立刻抬层级」（实测这样设置生效且不再被重置）。

**四、修掉四处 + 删一处死代码。** 见上表四处被遮挡窗口；另删 `PluginManagerWindowController` 与 `NotchPanelController.showPluginManager()` - 全仓零调用点，其窗口层级为 0，一旦接线就是被全压的窗口。

**五、门禁。** `HostWindowLevelTests` 断言阶梯严格递增、`auxiliary(above:)` 严格高于对应域、且抽屉域辅助档低于 `utility`（系统弹出菜单仍在文件面板之上）。Kit 新增公开类型属对外变更，`NotchCenterKitAPI` 1.6.0 → 1.7.0 并立 `docs/api-changelog/HostWindowLevel.md`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 层级阶梯进 Kit + 锚点域推导 + 调用收口（本决策） | 一处定义全部次序；新增窗口照抄即可；系统窗口抬层级只有一条路径 | 新增 Kit 公开 API，需升次版本 | **采用** |
| B. 就地修四处，层级常量留在宿主内 | 不动公开 API | 插件（相册、文件架）自己也要弹系统窗口，没有常量可用只能继续各自手挑；下次新增窗口照旧踩 | 否决 |
| C. 设置窗内的确认改用 `beginSheetModal` 附属表单 | 完全绕开层级问题，且不再阻塞主线程 | 同步语义变异步，动到开关「影子值 + 取消回滚」的既有行为；四处调用点结构全改 | 否决（收益不抵行为风险） |
| D. 把所有确认提示统一换成 Kit 内联浮窗 | 与「抽屉内禁用模态弹窗」的既有红线完全一致 | 设置窗内的确认不是本次故障点（层级与模态循环都无问题），属于重做交互而非修缺陷 | 否决 |

## Consequences(影响)

- **API**：新增 `HostWindowLevel` / `HostWindowLevel.Anchor` / `SystemFilePanelPresenter`，`NotchCenterKitAPI` 1.6.0 → 1.7.0。纯新增，无破坏性变更；插件可用 `SystemFilePanelPresenter` 少写一遍三条规矩。
- **代码**：八处层级字面量改引阶梯；四处被遮挡窗口修复；删 `PluginManagerWindowController`（含 `NotchPanelController.pluginManagerWindowController` 属性）。
- **文档**：`docs/agents/面板与抽屉.md` 落阶梯表、`auxiliary(above:)` 契约与两个绕不过的坑（`NSAlert.runModal` 强制覆盖层级、`QLPreviewPanel` 首次显示重置层级）；`docs/DESIGN.md` 的抽屉窗口层级改引 `HostWindowLevel.drawer`。相册插件的既有 note 不回溯改写——决策记录记的是当时的事实。
- **遗留**：`NSAlert` 的层级是在模态循环启动后补设的（AppKit 强制 `runModal` 用 `NSModalPanelWindowLevel`），理论上存在一帧的呈现次序抖动；实测未观察到，若将来出现闪烁，出路是 C 方案。`SizeLabWindow` 刻意保持普通层级（见 out of scope）。

## Changelog

- v1:2026-09-28 首版：四处被遮挡窗口清单与实测层级、层级阶梯进 Kit、系统窗口抬层级收口、删死代码。
