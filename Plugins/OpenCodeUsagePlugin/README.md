# OpenCode Usage（用量卡）

在抽屉里展示 [OpenCode](https://opencode.ai) 的用量窗口图与 Zen 余额。

## 提供的块

- **抽屉块 `opencode.usage`**：同心环用量图 + 各用量窗口明细 + Zen 余额，支持编辑模式缩放调整跨度。

## 设置

设置视图需要填写：

- **Workspace ID**：OpenCode 工作区标识（`wrk_...`）。
- **Cookie**：登录态凭证，保存后仅展示尾 4 位掩码，绝不写入日志。
- **Base URL**：数据源地址，默认官方站点。

数据抓取自 opencode.ai 的 SSR 页面；配置保存在插件作用域的 `StateStore` 中。
