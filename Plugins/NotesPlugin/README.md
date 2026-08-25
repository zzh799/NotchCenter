# Notes（笔记）

刘海里的多标签 Markdown 便签，由原 NotchNotes 的笔记功能移植而来。

## 提供的块

- **紧凑块 `notes.compact`**：点击新建一篇笔记并展开抽屉，焦点直接落到新笔记。
- **抽屉块 `notes.notebook`**：多标签 Markdown 编辑器（TextKit 2 渲染），支持 2/4 列 × 3-4 行跨度；编辑模式可拖动加高。

## 设置

设置视图展示当前笔记数量，并提供“新建笔记”入口。笔记内容与图片随写随存，无需手动保存。

## 数据位置

笔记与图片持久化在插件作用域的 `StateStore` 目录中（`PluginData/<pluginID>/`）。
