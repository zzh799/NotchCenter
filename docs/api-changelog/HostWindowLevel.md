# API 变更日志:HostWindowLevel

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。

## 2026-09-28 · v1.7.0 · added
- 新增 `HostWindowLevel`:宿主界面层级阶梯的**唯一真源**,七个有序常量 `drawer`(25) / `popover`(27) / `drawerAuxiliary`(28) / `utility`(101) / `utilityAuxiliary`(102) / `dragPreview`(103) / `effectOverlay`(999)。宿主与插件写窗口层级一律从这里取,不再手挑 `.statusBar ± n` 或 `CGWindowLevelForKey(.popUpMenuWindow)` 这类字面量。
- 新增 `HostWindowLevel.Anchor`(`.drawer` / `.utility`)与 `HostWindowLevel.auxiliary(above:)`:系统辅助窗口(文件面板、`NSAlert`、`QLPreviewPanel`)按**锚点所在界面域**抬层级。抽屉域抬到 `drawerAuxiliary`(盖过抽屉 25 与块浮窗 27,仍低于系统弹出菜单 101),设置域抬到 `utilityAuxiliary`(盖过设置窗与权限引导窗 101)。
- 为什么必须抬:**层级是全局排序**,低层级窗口永远渲染在高层级窗口之下,与谁是 key、谁后 `orderFront` 无关。而这些系统窗口的默认层级极低(实测 `NSOpenPanel` 0、`NSAlert.runModal` 强制 8、`QLPreviewPanel` 9)。插件不抬层级就会看到「点了没反应」。
- 兼容性:纯新增,无破坏性变更,既有插件零改动。新插件建议直接用 `SystemFilePanelPresenter` 呈现文件面板。
- 关联 Agent Note:[2026-09-28-host-window-level-ladder](../agent-notes/implemented/2026-09-28-host-window-level-ladder.md)

## Changelog
- v1.7.0:新增 `HostWindowLevel` / `Anchor` / `auxiliary(above:)`(2026-09-28)。
