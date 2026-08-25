# Calibre Server（服务控制卡）

控制本机 `calibre-server` launchd 服务的启停，随手管理电子书服务器。

## 提供的块

- **抽屉块 `calibre.service`**：服务状态卡——运行状态、启停按钮与最近操作结果。点击操作会调用 `launchctl`（经 `LaunchdControlKit`），必要时请求管理员授权。

## 说明

- 服务定义按 LaunchAgent 模板探测；未安装服务时卡片给出提示。
- 与 DSH Service 同构：launchd 探测/控制逻辑全部复用 `LaunchdControlKit`，不在插件内另写。

详细机制见 [`docs/服务控制类插件开发指南.md`](../../docs/服务控制类插件开发指南.md)。
