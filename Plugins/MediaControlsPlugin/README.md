# Media Controls（媒体控制）

抽屉里的一行媒体控制：左边是正在播放的应用图标与名字，右边是上一首 / 播放暂停 / 下一首。控制的是**系统当前播放的媒体**，不管它来自音乐、Spotify 还是浏览器。

- **抽屉块 `media.controls`**：单行，物理尺寸 `260×64`（最小）/ `300×64`（推荐）/ `600×64`（最大）。高度锁死、宽度弹性：拉宽只是把应用名与按钮之间的空隙撑开，拉高（把格子调大时）整行垂直居中。窗口窄于声明的下限时整行等比缩小，不会顶到邻居块上。
- **能看到什么**：应用图标取自带图标的应用本体（`NSWorkspace`），名字是系统的本地化显示名（例如 `音乐.app`、`Google Chrome.app`）；按 bundle id 找不到时退回按进程号反查运行中的应用；两者都拿不到时才显示「正在播放」占位。没有正在播放的内容时按钮置灰、文案为「暂无播放」。
- **能控制什么**：上一首、播放/暂停、下一首。暂停时中间按钮翻成播放图标。预览副本（滑动切页的非激活页、组件目录）只读展示，点击不投递任何命令。
- **开销**：只有在抽屉里真的看得到这个块时，才会常驻一个 `/usr/bin/perl` 子进程接收推送；抽屉收起即退出，不留后台进程。

## 实现注意：为什么要经过 Perl

macOS 没有公开 API 能观测/控制其他应用的播放，只能用私有框架 **MediaRemote**；而 **macOS 15.4 起系统只放行 bundle id 以 `com.apple.*` 开头的进程**访问它。NotchCenter 是无沙盒、ad-hoc 签名的进程，直连查询恒返回空（实测：同一份二进制在自建 `.app` 里返回空、在 `/usr/bin/perl` 里返回数据）。

所以本插件借 `/usr/bin/perl`（bundle id 恰是 `com.apple.perl`）加载一个 helper framework 代跑查询，把 JSON 打到 stdout，宿主这边逐行读。这套桥用的是上游 [`ungive/mediaremote-adapter`](../../Vendor/mediaremote-adapter/VENDORED.md)（BSD-3，署名见本目录 `NOTICE`）；`MediaRemoteBridge` 是本插件内**唯一**与子进程打交道的地方。

构建侧：`scripts/build.sh` 用 clang 把 `Vendor/mediaremote-adapter` 编成 `.build/bridge/MediaRemoteAdapter.framework`，再复制进插件 bundle 的 `Contents/Resources/Bridge/`（白名单常量 `BRIDGE_PLUGIN_IDS`）。

风险、判定依据与升级方式见 [`docs/agents/系统集成与多语言.md`](../../docs/agents/系统集成与多语言.md) 的「私有框架访问」一节；本次重建的决策见 [`docs/agent-notes/implemented/2026-09-28-media-controls-plugin-restore.md`](../../docs/agent-notes/implemented/2026-09-28-media-controls-plugin-restore.md)。
