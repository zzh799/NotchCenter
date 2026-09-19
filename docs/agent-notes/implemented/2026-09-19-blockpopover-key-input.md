# Agent Note: 浮窗面板获得 key 资格（修复输入控件无法聚焦）

status: implemented
date: 2026-09-19
deciders: 用户（首轮二选一：只修"点一下就能输入"；随后追加需求：新建任务浮窗打开即聚焦名称框）

## Context（背景与约束）

- 用户报告：定时插件「新建任务」浮窗里输入控件无法聚焦、打不了字。
- 根因（非推测，本机实测）：`BlockPopover` 用裸 `NSPanel(styleMask: [.borderless, .nonactivatingPanel])` 建窗且只调 `orderFrontRegardless()`，而无边框窗口的 `canBecomeKey` 默认是 `false`（实测 borderless `NSPanel` / `NSWindow` 皆为 `false`，且 `.nonactivatingPanel` 不改变这一点） - 窗口永远成不了 key window，内部 `TextField` / `TextEditor` 的字段编辑器（`NSTextView`）也就永远无法成为 first responder。
- 波及面不止定时插件：`SettingPopover` 承载的一切可输入内容都受影响，宿主自己的分页改名输入框（`Sources/NotchCenter/DrawerPageSettingsPopover.swift:53`）同样点不进去。这是宿主级缺陷，不是插件表单的 bug。
- 既有约定不可破：`docs/agents/面板与抽屉.md` 记明 `BlockPopover` 是"独立 `nonactivatingPanel`（不抢焦点）"，且其卡片被夹在块矩形内（`BlockPopover.cardInset`） - 因为宿主的鼠标「停留区」判定不含浮窗窗口，卡片一旦伸出块，鼠标一移过去抽屉就收、浮窗跟着 `dismiss()`。
- out of scope：模态弹窗/`runModal` 路线（`docs/agents/面板与抽屉.md` 已因"抽屉先收起 + 阻塞主线程"禁用）；其余浮窗（确认、历史、剪贴板）一律不自动取焦点。
- 追加需求（同日）：用户改主意要"新建任务浮窗打开即聚焦名称框"，故补上当初列为 out of scope 的自动聚焦，做成 Kit 的 opt-in（见决策 6）而不是全局行为。

## Decision（决策）

1. **面板获得 key 资格，但呈现时仍不主动抢焦点**：新增 `internal final class BlockPopoverPanel: NSPanel` 重写 `canBecomeKey = true`（`canBecomeMain` 保持 `false`），替代裸 `NSPanel`。`present` 仍只 `orderFrontRegardless()`，不做 `makeKey` / `makeKeyAndOrderFront` - "是否成为 key"由用户点进浮窗决定，故既有"呈现不抢焦点"的语义对纯按钮类浮窗（删页确认、剪贴板条目）完全不变。
2. **取消指令关闭浮窗走 `cancelOperation(_:)`**，不在 `sendEvent` 里复制 `NotchPanel` 的 Esc 判定。面板一旦可成为 key，Esc 就落到浮窗窗口而非抽屉窗口，不补这一步会变成"Esc 无反应"（原行为是抽屉收起顺带关掉浮窗）。选 `cancelOperation` 的依据：输入法处于 marked text 时 Esc 由输入上下文消费、`cancelOperation` 根本不会被调用，**天然 IME 正确**；若照搬 `NotchPanel.sendEvent` 那套，就得把"marked text 放行 / 带修饰键放行"的平台怪癖判定在各处复制一遍。代价是 Cmd+. 这类同样映射到 cancel 的组合也会关浮窗 - 按"取消当前操作"语义是合理的（抽屉面板当初选择只认裸 Esc，是因为它有 IME 编辑器同时吃 cancelOperation 的复杂背景，浮窗内容没有）。
   - 已实测（无边框 `nonactivatingPanel` + `NSHostingView`）：SwiftUI `TextField` 的 `_SystemTextFieldFieldEditor`、`TextEditor` 的 `PlatformTextView`、以及 `SwiftUIAppKitButton`（浮窗内什么都没聚焦、只点过按钮）作首响应者时，Esc 均能到达窗口 `cancelOperation`。
3. **关闭时把 key 归还给"打开前的 key 窗口"**：`present` 记 `NSApp.keyWindow`（weak），`dismiss` 在 `orderOut` 前，若浮窗此刻是 key 且该窗口仍 `isVisible`，则 `makeKey()`。理由是无边框面板 `orderOut` 后 AppKit 不保证自动补 key，抽屉会退化成无 key 窗口，Esc 收起与 `EditMenuInstaller` 的 Cmd+C/V/X/A/Z 全部失效。只记"打开前的 key 窗口"而非宿主块窗口：浮窗也可能开在设置窗口之上，归还目标必须是原来那个。用 `makeKey()`（非 `makeKeyAndOrderFront`）且带 `isVisible` 守卫，不触碰 `docs/agents/面板与抽屉.md` 的"隐藏窗口不得复活"红线。
4. **首击必须投递给内容**：`PopoverHostingView` 加 `acceptsFirstMouse -> true`（与宿主 `FirstMouseHostingView` 同款）。应用未激活时（紧凑区浮窗）默认首击只用于激活窗口，会把"点击输入框"吞掉成"要点两下"。
5. **两个被怀疑的连带风险经实测排除，不加防御代码**：
   - `.menu` Picker 点选**不会**误触"点击外部关闭"的本地监听：`NSMenu` 追踪期走自己的取事件循环，不经 `NSApplication.sendEvent`，本地 monitor 不回调（实测：追踪中投递的 mouseDown 未触发 monitor）。故不给监听加 popUpMenu 层级白名单。
   - 抽屉的 `ignoresMouseEvents` 光标穿透（`NotchPanelInteraction.updateDrawerMouseEvents`）只读 `isExpanded` 与光标位置，与 key 状态无关，不受本决策影响。
6. **打开即取焦点做成 opt-in 参数**（追加需求）：`present` / `SettingPopover.present` 增 `focusContent: Bool = false`，为 true 时在 `orderFrontRegardless()` 之后 `panel.makeKey()`；焦点落哪个控件由内容用 `@FocusState` 自行请求（Kit 只知道窗口，不知道控件）。定时插件 `TaskListView.presentEditor` 传 true、`TaskFormView` 在 `onAppear` 置 `nameFocused = true`。
   - 为什么是 opt-in 而不是全局：面板是 `nonactivatingPanel`，应用未激活时 `makeKey` 会直接从当前前台 App 抢走键盘输入，而紧凑区浮窗（`CompactPanelView`）正处于这种状态；确认/历史/剪贴板这类"打开不是为了打字"的浮窗也不该抢焦点。
   - 时序已实测（复刻 present 的真实顺序：挂 `contentView` → `orderFrontRegardless` → `makeKey`）：`onAppear` 晚于 `makeKey` 触发，再下一帧字段编辑器即成为 first responder，故 `onAppear { nameFocused = true }` 不需要额外的 async 延后。

## Alternatives considered（备选方案）

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 面板重写 `canBecomeKey` + 呈现不 makeKey（本方案） | 改动最小；点入即可输入；呈现语义不变；Esc 归 `cancelOperation` 天然 IME 正确 | 需同时补 Esc 与 key 归还，否则引入两个新坑 | **选此** |
| B. 打开浮窗即 `makeKeyAndOrderFront` + 表单自动聚焦 | "新建任务"开箱即打字，少一次点击 | 紧凑区浮窗会把键盘焦点从用户当前 app 抢过来（用户并未点击浮窗） | **部分采纳**：字面版的全局取焦点仍否；同一思路收窄为 `focusContent` opt-in（决策 6）后由定时插件表单使用 |
| C. 用 `NSPanel.becomesKeyOnlyIfNeeded = true` | 点按钮不抢 key、点输入框才抢，看似更稳 | 它**不能替代** `canBecomeKey` 覆写（默认仍是 false）；且依赖 `needsPanelToBecomeKey` 在 `NSHostingView` 内正确上报，本项目 `SettingsWindow.swift:61-62` 正因该机制在此环境不可靠才显式设 false - 有退化成"依旧无法输入"的风险 | 否 |
| D. 保持面板不可成为 key，把表单搬回抽屉内联 | 不碰窗口管线 | 与定时插件"决策 6B：配置走设置浮窗"直接冲突；抽屉块尺寸受限，多行表单放不下 | 否 |
| E. Esc 在 `sendEvent` 里拦截（照搬 `NotchPanel`） | 与抽屉面板行为字面一致 | 必须复制"裸 Esc + marked text 放行 + 有无修饰键"的判定，同一 why 两处写；`cancelOperation` 已能覆盖本浮窗内容（实测） | 否 |
| F. 为 `.menu` Picker 给本地监听加 popUpMenu 白名单 | 防御性 | 实测追踪期监听不回调，属无凭据的防御代码 | 否 |

## Consequences（影响）

- 代码：`Sources/NotchCenterKit/BlockPopover.swift` - 新增 `BlockPopoverPanel`（`canBecomeKey` / `cancelOperation`）、`present` 增 `focusContent` 参数并记录 `previousKeyWindow`、`dismiss` 归还 key、`PopoverHostingView.acceptsFirstMouse`；`Sources/NotchCenterKit/SettingPopover.swift` 透传 `focusContent`；`Plugins/CommandSchedulerPlugin` 的 `TaskListView.presentEditor` 传 `focusContent: true`、`TaskFormView` 加 `@FocusState` 并在 `onAppear` 聚焦名称框。
- 测试：`Tests/NotchCenterTests/BlockPopoverTests.swift` 改 `@testable import` + `@MainActor`，补 `canBecomeKey == true`（修复前该值为 false，是真正的回归锁）与 `cancelOperation` 触发 `onEscape` 两例；不做 `sendEvent` 全链路用例（需真实 IME 与字段编辑器，不稳定）。自动聚焦的时序同样不做单测（依赖真实窗口与 SwiftUI 聚焦，用下面的实测结论背书）。
- 额外实验（补在实现期）：Esc 的取消链对 SwiftUI 控件是透明的 - 首响应者为 `SwiftUIAppKitButton`（即浮窗内什么都没聚焦、只点过按钮）时，Esc 同样能到达窗口 `cancelOperation`，故"点按钮后按 Esc 无反应"不会出现。
- 文档：`docs/agents/面板与抽屉.md` 的 `BlockPopover` 条目补 key 资格/归还/Esc 语义；`docs/api-changelog/BlockPopover.md` 的未发布 v1.5.0 条目补 `focusContent`（新增）与行为变化（`changed`）；`NotchCenterKitAPI.currentVersion` 仍在 v1.5.0 内（该版本尚未发布，加法不另起版本号）。
- 行为变化（对既有调用方）：浮窗内容现在可被点击获得键盘焦点（此前不可能，是缺陷而非特性）；面板为 key 时取消指令（Esc / Cmd+.）关闭浮窗（此前是关掉整个抽屉）。既有纯按钮浮窗无需改动；`focusContent` 默认 false，不传就与从前一致。
- 真机验收清单（编译期与单测覆盖不到真实鼠标点击）：定时插件「新建任务」打开即光标在名称框、可直接打字；「编辑任务」同样聚焦名称框（同一表单，未按新旧区分）；名称 / 命令 / 工作目录 / 环境变量 / 各数字框 / 两个 `.menu` Picker 均可输入且 Picker 点选不关窗；分页改名输入框可输入；Esc 关浮窗后抽屉 Esc 仍能收起；点浮窗外区域关窗后抽屉键盘快捷键（Esc / Cmd+C/V）仍工作。
- commit 消息引用 `(note: 2026-09-19-blockpopover-key-input)`。

## Changelog

- 2026-09-19: 初稿（proposed）。根因经本机 AppKit 实验确认；方案 A 的 Esc 与 key 归还两处配套均给出实测依据。
- 2026-09-19: 实现落地（`BlockPopoverPanel` + key 归还 + `acceptsFirstMouse`；`BlockPopoverTests` 补 2 例），转 `implemented`。`./scripts/build.sh test` 全绿，`./scripts/build.sh test BlockPopoverTests` 定向复验 2 例通过。**真机点击验收待走**（清单见 Consequences）。
- 2026-09-19: 追加需求落地（决策 6）：用户要求"新建任务浮窗打开即聚焦名称框"，新增 `focusContent` opt-in + 表单 `@FocusState`，并回填时序实测结论；Alternatives 表 B 由"否决"改记"部分采纳"。
