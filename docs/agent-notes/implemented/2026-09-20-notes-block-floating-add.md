# Agent Note: 笔记块撤设置入口，新建钮收进右上角悬浮角标

status: implemented
date: 2026-09-20
deciders: 用户

## Context(背景与约束)

用户提两项改动：**撤掉笔记组件的设置按钮**、**「+」改成像其他插件那样的右上角悬浮显示**。两项各自都有既有约束顶着：

- **笔记块上没有插件自绘的齿轮**。块内齿轮、✕、缩放握把的落位与显隐全归宿主 [DrawerBlockContainer](../../../Sources/NotchCenter/DrawerBlockContainer.swift)：齿轮条件是 `showsSettingsControl = hasSettings && (悬停中 || 手势中)`，而 `hasSettings` 由 [NotchPanelContent](../../../Sources/NotchCenter/NotchPanelContent.swift) 解析为「块声明了 `instanceSettingsView`」或「插件声明了 `settingsView`」。`NotesPlugin` 走的是插件级 `settingsView`，所以"撤掉齿轮"**只有一条实现路径**：不再声明 `settingsView`（宿主没有 per-block 隐藏开关）。设置面板里的内容只有「N 条笔记 + 一句说明 + 新建笔记按钮」——没有任何可配置项，删掉不丢信息（新建入口另有紧凑快捷按钮 `notes.compact` 与块内「+」两处）。
- **「+」原先在分页条右侧常驻**（[TabPagerControl](../../../Plugins/NotesPlugin/Sources/TabPagerControl.swift) 里 24pt 圆形、`NotchTokens.Surface.track` 底），是块内唯一的新建入口。同族改造有两份先例：[镜子块](../../../docs/agent-notes/implemented/2026-09-20-camera-mirror-block-styling.md) 与[定时命令块](2026-09-20-command-scheduler-floating-add.md)，都把块内动作钮收成右上角悬浮角标。
- **槽位不能不留**：分页条圆点会自动换行铺满可用宽度，而角标只在悬浮时才进视图树。若让圆点用完整个宽行，悬浮瞬间角标就压住最后一颗圆点——同族教训是「悬停浮出的角标必须落在自己的命中区内」（见 [抽屉分页与滑动切页.md](../../agents/抽屉分页与滑动切页.md)）。
- **角标几何恰好同带**：直径 22 + 内缩 6×2 = **34pt 见方**，与 34pt 分页条带（`notes.pager` 探针）同高，因此不侵入 `notes.textArea`（y = 42 起），也不需要新探针。
- **新建流程有写序契约**：`createNoteInTopmostPlacement` 与本块内的新建都必须在改 `activeTabID` **之前**把激活标签写进 `NotesModel`，否则标签跟随的 `onChange` 先读到旧记忆，会把本实例的选择弹回旧笔记。

out of scope（明确不动的部分）：紧凑快捷按钮 `notes.compact`、状态栏菜单项、标签页数据语义（`NotesStore`）、三条探针的几何、`BlockCard` / `IconCircleButton` 的 Kit 代码、宿主**全局**齿轮（本次只让笔记块不再声明设置，其他块照旧）。

## Decision(决策)

1. **不再声明 `settingsView`**：删 `NotesPlugin.settingsView` 与 `NotesSettingsView`，并清掉只有它引用的本地化键 `notes.count.one` / `notes.count.other` / `notes.settings.description`（en / zh-Hans 同步）。`NotesModel.editorInteractionState`（"无放置上下文的默认实例"）唯一使用者就是那个设置界面，一并删除。**笔记插件从此没有设置入口**，`notes.newNote` 复用为角标的 help / a11y。
2. **新建钮 = 块级右上角悬浮角标**：[NotebookBlockView](../../../Plugins/NotesPlugin/Sources/NotebookBlockView.swift) 挂 `.overlay(alignment: .topTrailing)` + Kit `IconCircleButton(systemImage: "plus")`，`if isHovering` + `.transition(.opacity)` + `NotchTokens.Motion.hover` + `padding(6)`（与宿主编辑角标同一环），`.disabled(isPreview)` 作滑动切页过渡副本护栏。整套照 ClipboardHistory / Camera / Scheduler 抄，并在 [DESIGN.md §9](../../DESIGN.md) 记为「块内动作角标的统一落位」。
3. **分页条退化为纯圆点**：`TabPagerControl` 删掉右侧按钮与 `onCreateNote` 参数；`availableWidth` 改由调用方扣掉**恒留的角标槽位**（22 + 6×2 = 34，`controlSlot`）后传入，`max(..., 160)` 下限不变。圆点可用宽度与改前逐点相同。
4. **新建流程搬进块视图的 `createNote()`**，写序与紧凑入口一致。"离开标签前把选区写回"原先只写在分页条的私有方法里，现在有两个调用方（圆点切换/删除、新建）——收敛为 `EditorInteractionState.commitSelection(to:tabID:)` 单一实现，漏掉就是切回来时选区落在文档开头。
5. **探针不动**，并把「块内悬浮角标不单列 `BlockProbe`」写成插件约定（[插件开发约定.md](../../agents/插件开发约定.md)）：角标必然叠在某个既有探针上，而 `BlockSizeVerifier` 对探针做互不重叠判定，单列会直接判错。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 保留 `settingsView`，想办法只把齿轮藏掉 | 设置面板还在 | 宿主没有 per-block 开关（`hasSettings` 只看"有没有声明"），要藏就得改公共容器——为一块只有展示内容的空面板改宿主，不划算 | 否 |
| 设置面板改挂 `instanceSettingsView` | 走"每实例状态三件套"惯例，符合插件约定 | 面板本身零可配置项，改成每实例只是把没有归属的东西换个地方放 | 否 |
| 「+」做成常驻角标（不悬浮） | 新建永远可见可达 | 与用户要求相反，块内多一个常驻控件；同族三块都是悬浮 | 否 |
| 「+」留在分页条，整条收进悬浮层 | 改动最小 | 分页条是常驻控件带，整条随鼠标忽隐忽现，比原样更糟 | 否 |
| 分页条不预留槽位，圆点铺满整行 | 圆点可用宽度多 34pt | 悬浮瞬间角标压住最后一颗圆点，被压住的圆点也点不到 | 否 |
| 顺带把分页条从 34pt 压到 28pt 多还 6pt | 编辑区多 6pt | 竖轴总和 201 是现有 `minSize` 240 的配平值，压下来要重推三条探针并全量尺寸回归——与本条改动无关 | 否（另立） |

## Consequences(影响)

- **用户可见**：笔记块左上角不再出现齿轮，插件无任何设置入口；鼠标悬浮块后右上角浮出标准圆形「+」（与宿主齿轮/✕/缩放握把同一环）。分页条只剩圆点，最右侧恒留 34pt 空槽。
- **布局**：竖轴总和不变（探针仍 34 / 120 / 39，201 ≤ 240）；圆点可用宽度与改前**完全一致**（先前也是扣 34）。编辑模式下右上角会与宿主 ✕ 重叠——ClipboardHistory / Scheduler 同样如此，且编辑模式本身屏蔽块内容手势，可接受。
- **待真机复核**：块内编辑器是 AppKit 子视图（`NativeTextViewWrapper`），SwiftUI `.onHover` 在 AppKit 子视图上的行为本次未在真机确认。若指针停在编辑区时角标不浮出，退路是把悬停探测量挪到分页条 / 整块封面层——不改架构，只换挂载点。
- **本地化**：删 3 键（en / zh-Hans 同步），键集奇偶与"值非空"门禁不受影响。
- **文档**：`Plugins/NotesPlugin/README.md`（块描述 + 设置段改为"无设置界面"）、`docs/DESIGN.md`（§9 组件 3 与《组件默认圆形按钮》条目）、`docs/agents/插件开发约定.md`（新增「块内悬浮角标不单列 BlockProbe」）。
- **测试**：`./scripts/build.sh test` 全绿（含 `NoteStoreTests`、`LocalizationTests`）。无新增测试：本次是视图摆放与插件设置声明，可测的纯逻辑（探针几何、store 语义）未变，`commitSelection` 只是两行薄封装。
- **无迁移成本**：不涉及持久化数据、布局槽位或设置项；`Plugin.plist` 与插件版本不动。

## Changelog

- v1.0.0: 初版（2026-09-20）。撤笔记块设置入口（不再声明 `settingsView`）、新建钮改右上角悬浮角标、分页条退化为纯圆点、选区收尾收敛到 `commitSelection`。
