# DSH Service（服务控制卡）

控制本机 `dsh-web` launchd 服务的启停，开发调试 DSH 时不用再开终端。

## 提供的块

- **抽屉块 `dsh.service`**：服务状态卡——运行状态、启停按钮与最近操作结果。点击操作会调用 `launchctl`（经 `LaunchdControlKit`），必要时请求管理员授权。

## 说明

- 服务定义按 LaunchAgent 模板探测（`~/Library/LaunchAgents` 等）；未安装服务时卡片给出提示。
- 插件只做状态查询与启停控制，不修改服务的 plist 内容。

详细机制见 [`docs/服务控制类插件开发指南.md`](../../docs/服务控制类插件开发指南.md)。
