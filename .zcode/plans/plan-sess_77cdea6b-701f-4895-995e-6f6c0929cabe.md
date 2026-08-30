合并抽屉顶栏「设置 / 编辑 / 添加组件」三个按钮为一个「设置」按钮：

1. **DrawerPanelView.swift（topBar ~162–222）**：删除「添加组件」与「编辑」按钮；保留「设置」按钮（gearshape），点击行为 = 打开设置窗口并默认落在「组件」页（`showSettings(page: .components)`）。现有管线自动：展开抽屉 → 进入编辑模式（`setComponentsPageActive(true)` → `startEditMode()`）。再次点击 = 关闭设置窗口 → 自动退出编辑模式（showSettings 现有 toggle 行为）。其余按钮（tidy/pin/collapse）不动。

2. **NotchPanelContent.swift（drawerActions）**：`onShowSettings` 改为 `showSettings(page: .components)`；删除 `onAddComponent` action 及 `DrawerActions` 中对应字段。`startEditMode/stopEditMode/setComponentsPageActive/onToggleEdit` 保留（组件页激活机制仍在使用）。

3. **本地化**：从 en 与 zh-Hans `Localizable.strings` 同步删除不再使用的 `panel.help.addComponent`、`panel.help.editLayout`、`panel.help.doneEditing`（键集一致性由 LocalizationTests 保证）。

4. **验证**：`swift build` + `swift test`。