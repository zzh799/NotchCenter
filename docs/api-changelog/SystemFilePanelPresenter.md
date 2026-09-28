# API 变更日志:SystemFilePanelPresenter

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。

## 2026-09-28 · v1.7.0 · added
- 新增 `SystemFilePanelPresenter.shared.present(_:anchor:onCompletion:)`:系统文件面板(`NSOpenPanel` / `NSSavePanel`)的呈现收口,一次做掉三条缺一不可的规矩——**非模态** `begin`(模态循环会卡死抽屉的收起动画与悬停判定)、**抬层级**(经 `HostWindowLevel.auxiliary(above:)`,面板默认层级 0 会被自己的界面压住)、**长寿命持有者**(面板在设置卡随抽屉收起被拆掉后仍要活着)。同一时刻只保留一个面板,重复调用被忽略。
- 与 `AlbumPlugin` 原先自建的收口等价,插件侧调用从「自建 `NSOpenPanel` + 自己抬层级 + 自己持有」简化为一次 `present`。
- 兼容性:纯新增,无破坏性变更。
- 关联 Agent Note:[2026-09-28-host-window-level-ladder](../agent-notes/implemented/2026-09-28-host-window-level-ladder.md)

## Changelog
- v1.7.0:新增 `SystemFilePanelPresenter`(2026-09-28)。
