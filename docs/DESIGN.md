# NotchCenter 设计规范（Design Spec）

> 本文档汇总 NotchCenter 的视觉语言、排版、动效、组件与交互模型，供 UI 改动与新增界面时遵循。
> 源码标识符与 UI 字符串用英文，注释可用中文（与项目约定一致）。

---

## 1. 设计原则

- **贴近刘海（Notch-first）**：所有界面都锚定在屏幕顶部中央的刘海区域，紧凑态常驻、展开态从刘海向下展开。
- **深色为主、近黑半透明**：抽屉强制深色配色（`.environment(\.colorScheme, .dark)`，面板 `appearance = .darkAqua`），背景接近纯黑、半透明，边缘带细发丝描边。
- **克制的白色层级**：UI 不引入彩色主题，所有前景/背景都用「白色 + 不同 alpha」表达层次，链接/高亮等少数语义色用系统色（`systemBlue`）。
- **物理感动效**：展开/收起与卡片出现一律用 spring（响应 0.28、阻尼 0.84 附近）；悬停态用极短的 easeOut（0.10–0.13s）。
- **无侵入**：以 accessory 策略运行，无 Dock 图标，仅状态栏一个菜单项；不抢焦点、不常驻前台。

---

## 2. 配色（Color）

所有颜色均为「白色叠 alpha」或明确的深色 RGB，便于在深色背景上保持统一质感。

### 2.1 表面（Surface）

| 用途 | 取值 | 出处 |
| --- | --- | --- |
| 抽屉主背景 | `Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98)` | NotebookView |
| 笔记编辑器面板背景 | `Color(red: 0.06, green: 0.06, blue: 0.07)` | MarkdownEditorPanel |
| Markdown 快捷工具栏背景 | `Color(red: 0.055, green: 0.055, blue: 0.065)` | MarkdownEditorPanel |
| 文件暂存区背景（空闲） | `RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.025))` | FileShelfView |
| 文件暂存区背景（拖入高亮） | `.white.opacity(0.055)` + 描边 `.white.opacity(0.16)` + 阴影 | FileShelfView |

### 2.2 前景（Foreground，白色 alpha 层级）

| 层级 | alpha | 说明 |
| --- | --- | --- |
| 正文/主文本 | `white.opacity(0.92)` | Markdown 正文（`bodyText`） |
| 次要图标（默认） | `white.opacity(0.76)` | 工具栏图标常态 |
| 次要图标（悬停） | `white.opacity(0.88)` | 工具栏图标悬停 |
| 次要图标（按下） | `white.opacity(0.55–0.62)` | 工具栏图标按下 |
| 静音文本 | `white.opacity(0.58)` | `mutedText`、暂存文件名 |
| 禁用文本 | `white.opacity(0.38)` | `disabledText` |
| 占位文本「Start typing…」 | `white.opacity(0.24)` | 空笔记占位 |
| 标题标记 `#` | `white.opacity(0.44)` | `headingMarker` |
| 选中态激活（保持唤醒） | `white.opacity(0.94)` | KeepAwake 激活态 |
| 暂存文件名（选中） | `white.opacity(0.92)` | chip 选中 |
| 暂存文件名（不可用） | `white.opacity(0.34)` | 源文件丢失 |

### 2.3 描边与发丝线（Hairlines）

| 用途 | 取值 |
| --- | --- |
| 抽屉外描边 | `.white.opacity(0.09)`，`lineWidth: 1` |
| 编辑器分隔线 | `.white.opacity(0.045)`，`height: 1` |
| 文件 chip 选中描边 | `.white.opacity(0.20)` |
| 框选矩形 | 填充 `white.opacity(0.055)`，描边 `white.opacity(0.34)` |
| 图片缩略图描边 | `.white.opacity(0.12)`，`lineWidth: 0.5` |

### 2.4 语义色（少量系统色）

| 语义 | 取值 |
| --- | --- |
| 链接 | `systemBlue` |
| 未完成链接 | `systemBlue` @ 0.75 |
| 查找高亮 | `systemYellow` @ 0.55（当前命中 `systemYellow` 不透明） |
| 文件不可用角标 | `orange.opacity(0.72)`（`exclamationmark.circle.fill`） |

---

## 3. 形状与圆角（Shapes & Radii）

- **抽屉遮罩：`TopAttachedRoundedShape`** —— 顶部齐平、仅底部两角为圆角的形状（见 `NotebookView`）。圆角在展开过程中插值：紧凑 `12` → 展开 `18`。
- **圆角按钮**：`RoundedRectangle(cornerRadius: 7, style: .continuous)`。
- **文件暂存区容器**：`RoundedRectangle(cornerRadius: 10, style: .continuous)`。
- **文件 chip**：`RoundedRectangle(cornerRadius: 8, style: .continuous)`。
- **缩略图**：`RoundedRectangle(cornerRadius: 4, style: .continuous)`。
- **移除按钮**：`Circle()`。
- **标签页圆点**：`Circle()`，直径 6–7pt。

圆角统一偏好 `style: .continuous`（平滑连续圆角），符合 macOS 现代质感。

---

## 4. 排版（Typography）

- **字体族**：系统 SF（编辑器 `fontName: "SF Pro"`，UI 用 `.system(size:weight:)`）。
- **正文**：`font size 15`（编辑器、占位文本）。
- **工具栏图标**：`system(size: 13, weight: .semibold)`（设置/保持唤醒），`system(size: 11, weight: .semibold)`（Markdown 命令、标签）。
- **行内代码按钮**：`system(size: 13, weight: .bold, design: .monospaced)` 的 `` ` ``。
- **标签页文本/帮助**：系统 9–11pt。
- **文件 chip 名**：`system(size: 9, weight: .medium)`，单行截断 `truncationMode(.middle)`，`width: 52`。
- **拖入提示「Release to add」**：`system(size: 10, weight: .semibold)`。
- 保持「深色背景 + 白色文字」的对比，避免重阴影与渐变。

---

## 5. 间距（Spacing）

来自 `NotebookView` 的常量（单位 pt）：

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `contentHorizontalPadding` | 18 | 抽屉内容左右内边距 |
| `contentBottomPadding` | 12 | 抽屉内容底部内边距 |
| `toolbarTopPadding` | `compactSize.height + 2` | 顶部工具栏距顶 |
| `editorSpacing` | 8 | 编辑器与暂存区之间 |
| `shelfSpacing` | 8 | 暂存区相关间距 |
| `fileShelfHeight` | 72 | 暂存区高度 |
| 标签页行高 / 行距 | 24 / 4 | `TabPagerControl` |
| 编辑器工具栏高 / 分隔线 | 38 / 1 | `MarkdownEditorPanel` |
| 暂存区内边距 | 6（水平） / 6（垂直） | chip 列表 |
| chip 尺寸 | 60 × 54 | `FileShelfChip` |
| 缩略图 | 38 × 30 | 图片预览 |

---

## 6. 布局与几何（Layout & Geometry）

尺寸计算集中在 `NotchGeometry`，输入为屏幕（优先内建显示器）的实测刘海尺寸，带安全回退。

- **回退刘海尺寸**：`210 × 32`（无刘海屏幕）。
- **紧凑态 `compactSize`**：
  - 宽：`clamp(notch.width - 6, 182, 238)`
  - 高：`clamp(notch.height + 2, 32, 38)`
- **展开态 `expandedSize`**：
  - 宽：`clamp(notch.width + 220, 480, 540, screenWidth - 36)`
  - 高：`clamp(notch.height + 374, 408, screenHeight - 84)`
- **拖拽命中扩展**：`fileDropTargetExtension = 28`，将紧凑热区向下延伸 28pt 以接住从顶部拖入的文件。
- **展开进度 `revealProgress`（0→1）**：
  - `revealWidth` / `revealHeight` 在紧凑↔展开尺寸间线性插值；
  - 圆角在 12↔18 间插值；
  - 内容不透明度在 `progress > 0.42` 后淡入（`(progress - 0.42) / 0.34` 限幅到 1），避免展开早期内容穿帮。
- **窗口定位**：`topCenteredFrame` —— 以屏幕中点在刘海正下方居中放置，全部由 `NotchGeometry` 决定；屏幕参数变化（`didChangeScreenParametersNotification`）时重建布局。
- **窗口层级**：`.level = .statusBar`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`。

---

## 7. 动效（Motion）

统一使用 spring 表达「物理弹入」，用短 easeOut 表达「悬停反馈」。

| 场景 | 曲线 |
| --- | --- |
| 抽屉展开 | `spring(response: 0.28, dampingFraction: 0.86)` |
| 抽屉收起 | `easeOut(duration: 0.16)` |
| 暂存区出现/拖入高亮 | `spring(response: 0.30, dampingFraction: 0.84)` |
| 标签页切换 | `spring(response: 0.26, dampingFraction: 0.82)` |
| 移除暂存项 | `spring(response: 0.28, dampingFraction: 0.84)` |
| 悬停背景/前景变化 | `easeOut(duration: 0.10–0.13)` |
| 收起延迟 | 鼠标离开停留区后 `0.22s` 再收起（`scheduleCollapse`） |
| 编辑器激活时机 | 展开后 `0.30s` 异步激活 |

- 内容显隐与 `revealProgress` 绑定；卡片出现多用 `move(edge: .bottom).combined(with: .opacity).combined(with: .scale(…))`。
- 若 `accessibilityReduceMotion` 为真，禁用「咖啡蒸汽」等非必要装饰动画。

---

## 8. 交互模型（Interaction Model）

- **两种触发模式**（`TriggerMode`，可在状态栏设置菜单切换，默认 `hover`）：
  - `hover`：鼠标进入顶部激活框即展开（不抢焦点）；移出「停留区」(`isPointInExpandedStayRegion`，含 10pt 外扩边距) 后延时收起。
  - `click`：点击激活框展开并激活；依赖全局鼠标监听（`addGlobalMonitorForEvents`）。
- **鼠标轮询**：`Timer`，30fps（1/30s），`RunLoop.main` `.common` 模式，用于判断悬停/停留。
- **文件拖入**：拖拽文件到顶部 → 紧凑热区向下延伸接住 → 展开抽屉并高亮暂存区（`.isShelfDropTargeted`），松手即入暂存。
- **保持唤醒**：点击咖啡杯按钮，通过 `osascript`+管理员权限调用 `pmset disablesleep` 并配合 `caffeinate -dims`；状态切换时播放蒸汽动画。
- **退出/收起**：`Esc` 键、`Hide Notes`(⌘W) 或鼠标离开停留区触发收起；`applicationWillTerminate` 走 `flush()` 可靠落盘。
- **状态栏菜单**：仅一个 `note.text` 图标，菜单含 New / Show / Hide / Quit；Edit 菜单含 Undo/Redo/Cut/Copy/Paste/Select All/Find。

---

## 9. 组件库（Components）

1. **CompactNotchView（紧凑刘海）**：透明命中区覆盖刘海；`click` 模式下悬停时显示一条 48×2 的胶囊指示器（`white.opacity(0.72)` + 微光）。
2. **NotebookView（展开抽屉）**：`TopAttachedRoundedShape` 遮罩；内含 `TabPagerControl` + `MarkdownEditorPanel` + `FileShelfView`；强制深色。
3. **TabPagerControl（标签页）**：自动换行的圆点（每笔记一个），选中态为更大更亮的白点 + 外发光；右侧「+」新建笔记；支持右键删除（仅剩 1 个时禁用）。
4. **MarkdownEditorPanel**：原生 `NSTextView`（`MarkdownEngine`）+ 1px 分隔线 + `MarkdownShortcutToolbar`。
5. **MarkdownShortcutToolbar**：命令按钮（bold/italic/strikethrough/inlineCode/link/quote/unorderedList/orderedList/todoList）+ `KeepAwakeButton` + `SettingsMenu`。
6. **FileShelfView（文件暂存区）**：横向滚动 chip 列表，支持拖出到 Finder/应用、框选（marquee）、拖入高亮、QuickLook 预览（空格）；不可用文件显示橙色角标。
7. **SettingsMenu**：`gearshape`，切换触发模式。
8. **KeepAwakeButton**：`cup.and.saucer` / `cup.and.saucer.fill`，激活时播放 `CoffeeSteamBurst` 蒸汽动画。

### 统一按钮样式（`RoundedHoverButtonBody`）

所有圆角按钮共用 `RoundedHoverButtonBody`：常态/悬停/按下三态的「白底 alpha」与「前景白 alpha」由各自 `ButtonStyle` 注入，圆角固定 7、`.continuous`，按下与悬停各带极短 easeOut，并统一 `pointingHandCursor()`。新增按钮请复用该基类而非自绘。

---

## 10. 图标（Iconography）

- 一律使用 **SF Symbols**（`systemImage`）+ `NSWorkspace` 系统文件图标，不引入自定义图标集。
- 关键符号：状态栏 `note.text`；设置 `gearshape`；新建 `plus`；保持唤醒 `cup.and.saucer`(.fill)；文件不可用 `exclamationmark.circle.fill`；Markdown 命令用 `bold`/`italic`/`strikethrough`/`link`/`quote.opening`/`list.bullet`/`list.number`/`checklist` 等。

---

## 11. 可访问性（Accessibility）

- 每个可交互控件都提供 `.help()` 与 `.accessibilityLabel()`（含当前状态，如「Current note: …」）。
- 键盘可达：空格预览、⌘A 全选、Delete/Backspace 移除、Esc 收起；`accessibilityReduceMotion` 时关闭装饰动画。
- 不可用文件用橙色角标 + 降低 alpha 表达，并暴露「is unavailable」帮助文本。

---

## 12. 窗口与系统外壳（Window & System Chrome）

- **面板类型**：`NSPanel`（`borderless` + `fullSizeContentView`），`isOpaque = false`、`backgroundColor = .clear`、`hasShadow = false`、`isMovable = false`、`animationBehavior = .none`、`acceptsMouseMovedEvents = true`、`appearance = .darkAqua`。
- **两块面板**：`hotPanel`（紧凑常驻）+ `drawerPanel`（展开抽屉），通过状态协调展开/收起。
- **激活策略**：`.accessory`（对应 `Info.plist` 的 `LSUIElement = true`）——无 Dock 图标，仅状态栏。
- **高分屏**：`NSHighResolutionCapable = true`。

---

## 13. 约定（Conventions）

- 标识符与 UI 字符串用英文；注释可用中文。
- 不引入新的 SPM 远程依赖，优先复用 AppKit / SwiftUI / vendored 引擎。
- **文件暂存区只持有路径引用**，绝不复制、移动、删除用户原文件（见 `FileShelfStore`）。
- 视觉改动保持「贴近刘海、近黑半透明、白色层级、连续圆角、spring 动效」的整体观感。
- 主线程隔离：store/controller 多为 `@MainActor`；跨线程注意 `Sendable`。
