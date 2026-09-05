# 设置页改造：侧边栏→顶栏 + 底部停靠 + 抽屉限高

## 现状与目标
- 现状：设置页是独立 NSPanel(780×560),内容为「176pt 侧边栏 + 内容区」,窗口贴挂在抽屉可见底缘下方 8pt,抽屉高度变化时 spring 跟随。
- 目标：① 侧边栏改为顶栏(图标在上、文字在下)；② 设置页停靠屏幕底部(不再跟随抽屉)；③ 设置打开期间限高抽屉，保证抽屉可见底缘不与设置页重叠。

## 1. 顶栏改造 — `Sources/NotchCenter/SettingsWindow.swift`

`SettingsRootView.body`(L151-170):`HStack { sidebar | Divider | content }` → `VStack(spacing: 0) { topBar; Divider().overlay(.white.opacity(0.07)); content }`,删除 `sidebar`/`sidebarItem`(L174-233)。

`topBar` 布局:`HStack { "NotchCenter" 小标题(现有样式) ; Spacer ; 四个 tab ; Spacer ; 退出按钮 }`,横向 padding 14、纵向 padding 8,底部分隔线沿用现有 Divider 样式。

tab 项(新 `topBarItem(_:)`,沿用现有视觉体系):`VStack(spacing: 3) { Image(systemName: page.systemImage)(13pt medium) ; Text(page.title)(10.5pt,选中 semibold) }`,前景白 `0.92(选中)/0.58(常态)`,选中底 `white 0.12` 圆角 7 `.continuous`,新增悬停底 `white 0.06` + 手型光标(与 `TopBarButton` 的悬停节奏一致),`.buttonStyle(.plain)`。退出按钮(power + `settings.quit`)保留现样式放顶栏 trailing。页枚举、图标、本地化 key 全部不变;组件页内部的二级插件分组侧边栏不动。

## 2. 底部停靠 — `positionSettingsWindow()`(SettingsWindow.swift:322-342)

- 定位改为:`originY = pair.screen.visibleFrame.minY + SettingsWindowMetrics.bottomInset`(新常量,建议 12;用 `visibleFrame` 避开 Dock),`originX = pair.screenFrame.midX - width/2`(水平居中不变)。
- 删除 `animated:` 参数与 NSAnimationContext 跟随分支——底部停靠不再随抽屉移动;同步删除 `NotchPanelContent.rebuildContent` 末尾的跟随调用(L175-180)和 `NotchPanelController.gridMetricsDidChange` 里的重定位(L133-135)。`showSettings` 里的调用保留(打开时定位)。
- `SettingsWindowMetrics`:`gapFromDrawer` → `bottomInset` + 新增 `gapFromSettings`(抽屉与设置页间距,8)+ `windowFrameHeight = height + 28`(titlebar 高度,L66 注释已记录 588 = 560+28,限高计算要用窗口真实高度)。
- 更新类头注释(L6-13)、`showSettings`/`positionSettingsWindow` doc comment 中的「贴挂抽屉下方」描述。

## 3. 抽屉限高 — `drawerWindowSize(for:)`(NotchPanelController.swift:418-436)

在现有屏幕封顶(L429-434)后追加:`isSettingsPresented` 时,允许的可见抽屉高度 = `screenFrame.maxY - (visibleFrame.minY + bottomInset + windowFrameHeight) - gapFromSettings - compactHeight`,与现有 maxHeight 取 min;下限用 `layoutEngine.drawerWindowSize(contentRows: minimumRowCount())` 的高度兜底(极端矮屏放不开时限高失效、允许重叠,不塌成 0)。数学抽成纯函数放 `NotchGeometry` 便于单测。

内容侧无需改动：网格已在 `ScrollView` 中,高度被封顶时滚轮可滚到被遮的行——这是既有「屏幕封顶截断内容」路径(`DrawerPanelView.swift:183-189`、`gridFrameHeight` 注释),指示条隐藏、行为一致。

## 4. 打开/关闭时序

- 打开 `showSettings`:cap 按常量计算、不依赖窗口已定位,创建顺序安全;已展开时追加 `refreshAfterLayoutChange(animated: true)` 让抽屉 spring 收到限高尺寸(未展开则 `expand` 经 `drawerWindowSize(for:)` 自动带上限)。
- 关闭:`closeSettings` 与 `settingsWindowDidClose`(guard 幂等,两条路径都要覆盖)在 `isSettingsPresented = false` 后调用 `refreshAfterLayoutChange(animated: true)` 恢复完整高度。
- 拖拽/缩放预览(`applyPreviewWindowSize`)经同一 `drawerWindowSize(for:)` 出口,自动受限;`DrawerStayConditions`(设置打开期间抽屉常驻展开)不变。

## 5. 文档与验证

- 文档同步:`docs/agents/面板与抽屉.md:26`(跟随描述→底部停靠+限高约束)、`docs/agents/宿主开发约定.md:48`(侧边栏多页→顶栏多页)。
- `swift build && swift test`(新增 NotchGeometry 限高函数的单测);`./scripts/build.sh run` 真机验证:顶栏布局、底部停靠位置、设置打开时抽屉限高不重叠、关闭后高度恢复。