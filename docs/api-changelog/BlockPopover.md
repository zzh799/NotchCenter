# API 变更日志:BlockPopover

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。

## 2026-09-19 · v1.5.0 · changed
- `BlockPopover.present(anchoredTo:cardSize:placement:content:)` 行为变化:浮窗面板获得 key 资格,浮窗内容里的输入控件被点入即可获得键盘焦点;裸 Esc 关闭浮窗;关闭时把 key 归还给打开前的 key 窗口。此前无边框面板 `canBecomeKey == false`,浮窗内 `TextField`/`TextEditor` 的字段编辑器永远无法成为 first responder - 表现为"输入框点不进去"。
- 兼容性:非破坏,既有纯按钮/只读内容的浮窗无需改动（`present` 仅新增带默认值的参数,见下条 `added`）。两处可观察差异:(1) 浮窗内容现在能拿到键盘焦点(此前拿不到,属缺陷);(2) 面板已成为 key 时 Esc 关闭浮窗,而不是落到抽屉去收起整个抽屉。默认仍不主动抢焦点(只 `orderFrontRegardless()`)。
- 迁移:<无>。
- 关联 Agent Note:[2026-09-19-blockpopover-key-input](../agent-notes/implemented/2026-09-19-blockpopover-key-input.md)

## 2026-09-19 · v1.5.0 · added
- 新增 `present(anchoredTo:cardSize:placement:focusContent:content:)` 的 `focusContent: Bool = false` 参数（`SettingPopover.present` 同名参数透传）：传 true 时浮窗一上线就成为 key window，内容可立刻取得键盘焦点（表单配合 `@FocusState` 用，见定时插件的 `TaskFormView`）。
  - 语义:仅"打开就是为了输入"的表单类浮窗该传 true。面板是 `nonactivatingPanel`，应用未激活时它会直接从当前前台 App 抢走键盘输入 - 紧凑区浮窗正处于这种状态，故默认 false、不主动取焦点。
  - 迁移:<无>；需要"打开即聚焦首个输入框"的浮窗，在自己的表单里加 `@FocusState` 并在 `onAppear` 置 true，同时给 `present` 传 `focusContent: true`。
  - 关联 Agent Note:[2026-09-19-blockpopover-key-input](../agent-notes/implemented/2026-09-19-blockpopover-key-input.md)
- 新增 `public static let BlockPopover.cardInset: CGFloat`（= 卡片四周透明留白的合计，即 `margin * 2`）；`present` 内部改用同一常量推导窗口尺寸。
- 语义:插件据此把浮窗卡片尺寸**夹在自己的块矩形内**——`cardSize = min(理想尺寸, 块渲染尺寸 − BlockPopover.cardInset)`。宿主对抽屉块有鼠标"停留区"判定（`NotchPanelInteraction.isPointInExpandedStayRegion` = 抽屉可见矩形 ±10pt），**浮窗窗口不参与该判定**；卡片一旦伸出块矩形，伸出部分既收不到鼠标（光标一离开停留区即触发 250ms 后收起抽屉 → 投递 `.notchCenterDrawerDidCollapse` → `BlockPopover` 自动 `dismiss()`）。因此"卡片 ⊆ 块"是插件侧唯一稳定的尺寸约束。
- 兼容性:非破坏（`focusContent` 是带默认值的新参数，`cardInset` 是纯新增常量；窗口尺寸仍是 `cardSize + margin * 2`；`present` 的行为变化见上一条 `changed`）。
- 迁移:<无>；此前插件若自行硬编码 48 作为留白合计，应改引用本常量，避免与 Kit 内部 `margin` 失配。
- 关联 Agent Note:[2026-09-19-command-scheduler-plugin](../agent-notes/implemented/2026-09-19-command-scheduler-plugin.md)
