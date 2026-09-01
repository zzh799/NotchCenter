# 页面胶囊设置面板：图标宫格 + 名称即时生效

## 目标
编辑模式下点击胶囊齿轮角标，不再进入就地文本改名，改为弹出设置浮窗：二维宫格点选图标（即时生效）、名称输入框（改变即生效，无保存按钮）；胶囊显示内容变为「图标 + 标题」。

## 设计决策
- **浮窗管线**：复用 Kit `SettingPopover.shared.present(anchoredTo:placement:.below:title:)`（胶囊在屏幕顶端，用 `.below`，与紧凑图标同一理由）。锚点 frame 用 `GlobalFrameReader` 挂在胶囊 `.background` 上报（与抽屉块齿轮同一模式）。
- **图标库**：精选 ~40 个 macOS 14 可用的 SF Symbols 宫格（DESIGN.md §10 强制 SF Symbols，不用 emoji），8 列 `LazyVGrid`，首格「无」清除自定义图标；选中态 = 白 0.14 底衬 + 发丝描边（沿用设置窗口选中语言）。
- **存储**：`LayoutModel` 新增 `drawerPageIcons: [String: String]`，与 `drawerPageTitles` 完全同构（键 = 索引十进制字符串、空 = 清除、删页连带清理、旧 JSON 缺键回落 `[:]`）。主页无自定义图标时默认 `house.fill`（观感不变）。
- **胶囊显示**：有图标 → `HStack(symbol, 标题)`；无图标 → 沿用现状（自定义标题 → 序号；主页空串画房子）。**定宽 34 → 52pt**（容纳图标+标题，超出截断；槽位数学全由常量派生，测试引用 `step` 符号，不受影响）。
- **名称语义**：清空 = 回落序号（现有 `setDrawerPageTitle` 空串语义不变）。

## 实施步骤

1. **LayoutModel.swift**：加 `drawerPageIcons` 字段（成员 init 默认 `[:]`）+ `CodingKeys` 加 case + 自定义 `init(from:)` 加 `decodeIfPresent ?? [:]`（注意 AGENTS.md 警告：漏 CodingKeys 会被合成编码器静默丢弃）；加 `static func pageIcon(page:icons:) -> String?`（自定义 → 主页回落 house.fill → 其余 nil）。

2. **LayoutEngine.swift / LayoutEngineMutation.swift**：
   - 引擎转发 `var drawerPageIcons`（仿 `drawerPageTitles` 行 106-108）。
   - `drawerPageIcon(_:)` getter + `setDrawerPageIcon(page:icon:)`（trim、空=清除、`saveToDisk()`）；`removeDrawerPage` 里补 `drawerPageIcons[String(page)] = nil`。

3. **PanelUIState.swift + NotchPanelContent.rebuildContent**：`@Published var drawerPageIcons` 镜像 + 行 120 旁同批同步。

4. **DrawerPageCapsule.swift 改造**：
   - `DrawerPagePillLayout`：`pillWidth` 34→52；删 `editorWidth`。
   - `DrawerPageCapsule`：输入加 `icons`；`onRename` 回调删除，换 `onShowSettings: (Int, CGRect) -> Void`。
   - `DrawerPagePill`：**删除就地改名全套**（`isRenaming`/`draft`/`editor`/`beginRename`/`commitRename`/`cancelRename`，`canDrag` 简化为 `isEditing`，ZStack 换单层 pressSurface）；齿轮角标 action 改为经 `.background { GlobalFrameReader }`（仿 DrawerBlockContainer.swift:64-66）上报全局 frame → `onShowSettings`。
   - `content`：图标+标题渲染（图标 9-10pt semibold + 标题 10pt 截断）；badge tooltip 换 `panel.help.page.settings`。

5. **新文件 Sources/NotchCenter/DrawerPageSettingsPopover.swift**：设置内容视图——名称行（`TextField` `.onChange` 即时回调）+ 图标宫格（`@State` 初值经 init 注入，浮窗每次新建）。

6. **NotchPanelContent.swift**：`drawerActions()` 的 `onRenamePage` 换 `onShowPageSettings`；新增 `showPageSettings(page:anchorFrame:)`：present SettingPopover（title = 页面设置），闭包绑定 `renameDrawerPage`（既有）与新 `setPageIcon`（setDrawerPageIcon + rebuildContent）。退出编辑/删块/删页路径既有 `SettingPopover.shared.dismiss()` 已覆盖收场。

7. **DrawerPanelView.swift**：`Actions.onRenamePage` 换 `onShowPageSettings: (Int, CGRect) -> Void`；胶囊构造传 `icons: ui.drawerPageIcons`。

8. **本地化**（en + zh-Hans 键集一致）：`panel.help.page.rename` 换 `panel.help.page.settings` = "Page settings"/"页面设置"；新增 `panel.page.settings.title`（"Page Settings"/"页面设置"）、`panel.page.settings.name`（"Name"/"名称"）、`panel.page.settings.icon`（"Icon"/"图标"）、`panel.page.settings.icon.none`（"None"/"无"）。

9. **测试**：`DrawerPageTests` 增补——图标 setter 落盘与回读、空串清除、旧 JSON 缺键回落、删页连带清理图标键；跑 `swift test` 全量回归。

10. **文档**：更新 AGENTS.md（工程结构里 DrawerPageCapsule 行描述、抽屉多页面 bullet 的「悬停改名/删除」表述、胶囊内容描述、drawerPageIcons 存储约定、测试列表）。

## 验证
`swift build` + `swift test` 全量；如需真机确认，用 `./Scripts/build.sh dev` 后重启运行（注意旧实例残留陷阱）。
