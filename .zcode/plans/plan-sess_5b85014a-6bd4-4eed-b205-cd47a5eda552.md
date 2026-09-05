提交剪贴板历史插件：

1. 先跑 `swift test` 确认全绿（新插件 + LocalizationTests 登记后不能破坏双语闸门）。
2. 全部暂存：`git add Package.swift Tests/NotchCenterTests/LocalizationTests.swift Tests/NotchCenterTests/ClipboardHistoryTests.swift Plugins/ClipboardHistoryPlugin docs/agent-notes/proposed/2026-09-05-clipboard-history-plugin.md`。
3. 单条提交，信息：
   `feat: 新增剪贴板历史插件（纯文本轮询/置顶/搜索/点击写回）`
   正文列出插件实现、测试、Agent Note、LocalizationTests 登记、Package.swift 重扫注释。
4. 若 pre-commit 文档门禁在非 worktree 误拦，按其输出修复后再提交（不轻易 --no-verify）。