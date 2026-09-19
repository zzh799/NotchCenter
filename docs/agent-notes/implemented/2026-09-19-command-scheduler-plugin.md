# Agent Note: 新增「定时命令」插件（宿主内调度 + run 历史浮窗）

status: implemented
date: 2026-09-19
deciders: 用户

## Context(背景与约束)

需要一个插件，把"按计划自动执行本机命令"做成刘海里的常驻能力，并能回看每次执行的输出。现有官方插件里没有同类：`DshPlugin` / `CalibrePlugin` 是"一个插件管一个固定 launchd 服务"（`docs/服务控制类插件开发指南.md` §1 明确不做扫描、不做通用面板），本需求是**用户可增删任意命令与调度**，语义上不属服务控制类。

约束（三条都是既有事实，不是本决策引入的）：

- **宿主是 accessory 常驻 app**（`setActivationPolicy(.accessory)`，登录自启走 `SMAppService.mainApp`）；插件跑在宿进程内，**宿主退出即全停**。
- **`LaunchdControlKit` 不能拿来当通用 launchd CRUD 用**：它是"per-plugin 固定配置 + 探测/控制"，且 §6 明确"想给已有服务加行为时改真实 plist / wrapper，不要试图让插件接管改写 plist 内容"。动态生成 N 个 LaunchAgent 需要另起一套 Kit。
- **`AGENTS.md` 的"共享数据放插件级 store，不要按实例复制"**（`docs/agents/插件开发约定.md`）：任务表与调度器必须是插件级单例，不是每 placement 一份。

out of scope（明确不做）：

- 不做交互式终端（PTY / ANSI 渲染）——"历史日志或会话"指**历次执行的记录与输出**，不是可敲命令的 shell。
- 不做系统通知（不引入 `UserNotifications`，不新增一类系统权限面）。
- 不做 launchd 提权路径（宿主没运行 = 不执行，见决策 1）。
- 不做每任务一个快捷按钮（`QuickActionStore` 只在插件启用/attach 时收一次，任务却能运行时增删，没有重注册钩子）。
- 不做 cron 字符串解析（见决策 2）。

## Decision(决策)

九条决策，逐条给落点。**决策 1–8 由反复追问敲定，决策 9 由代码勘验敲定**（`BlockPopover` 的停留区约束是设计末期才发现的硬边界）。

**1. 执行归属：宿主内 Timer，唤醒不补跑。** 调度器活在插件单例里；睡醒/重启后所有已过时刻一律丢弃，下次触发推到未来第一个时刻，不补执行积压。执行器留在插件内（`Task.detached` + `Process`），**不做成新 Kit**——`LaunchdControlKit.Shell` 合并 stdout/stderr 且阻塞到退出，拿不到流式输出也杀不了超时进程；抽取门槛按 `服务控制类插件开发指南` §1 的"第三个同类消费者"执行，现在只有一个。

**2. 调度表达：结构化选择器，不做 cron。** 五档 `{每 N 分钟 / 每小时第 M 分 / 每天 HH:MM / 每周指定星期 HH:MM / 每月指定日 HH:MM}`，Codable 枚举直接落盘。UI 长在抽屉格子里（min 480×340 起），用户在那种地方不该敲字符串；选择器天然要求结构化模型，cron 字符串会逼着在它上面再糊一层"选择器 → 字符串"的翻译。**"下次触发时刻"做成纯函数**（`lastFiredAt` + `now` → 下次），它是全插件唯一需要在无睡眠假设下做时间数学的地方，必须能被单测穷举。

**3. 命令形态：`/bin/zsh -c` 非登录 shell + 显式注入 PATH。** 宿主从 Finder 启动时 `PATH` 是 launchd 给 GUI app 的最小值，从终端 `build.sh run` 启动时继承 shell——不处理就是"开发时能跑、打包后找不到 pnpm"的确定性翻车。注入 = 宿主 PATH ∪ `/opt/homebrew/bin`、`/opt/homebrew/sbin`、`/usr/local/bin`、`/usr/local/sbin`、`~/.local/bin`、`~/.bun/bin`、`~/.cargo/bin`、`~/Library/pnpm`。**不用 `-l`**：rc 里的 `echo` / `nvm` 默认加载会污染任务日志且让结果不可复现；需要 nvm 时在任务命令里显式 `source ~/.nvm/nvm.sh && nvm use 18 && …`。`cwd` 默认 `$HOME`、任务级可覆盖；保留任务级 `env` 覆盖字段。

**4. 错过留痕：聚合，不塞流水。** 任务在跑导致本次跳过、宿主未运行/睡眠导致时刻流失——都不往执行流水里写条目，只在任务卡片上滚一条「近 24h 跳过 N 次 · 错过 M 次」，点开看最近若干次时间戳。执行流水是给你看"命令干了什么"的；把"没干什么"塞进去等于用一个会自我稀释的列表承载两类信息。

**5. 日志实时性：边跑边 append 落盘。** 输出不攒内存。`A`（跑完才写）的致命缺陷不是"看不到进度"，而是**崩了就什么都没有**——定时任务最需要日志的恰恰是"跑到一半被杀"那种；`B` 让已产生的输出自然落盘，实时可见是副产品。

**6. 编辑落点：任务表单走宿主 `SettingPopover`。** 块内只读展示 + 运行控制；配置（名字 / 多行命令 / cwd / env / 调度五档 / 守卫超时 / 启停）全部在设置浮窗里编辑。**入口必须补一个块内按钮直接调 `SettingPopover.shared.present`**：宿主对 `settingsView` 的标准触发点是"编辑模式下抽屉块左上角的齿轮"，让用户为了改一个命令先切进布局编辑模式是错的。同一份表单另挂在插件级 `settingsView` 上供齿轮走标准路径——**一份表单，两个入口**。

**7. 块内主视图：任务列表。** 每行 = 任务名 / 调度摘要 / 下次触发 / 上次结果 / 启停开关 / 立即运行。导航两层：块内任务列表 → 浮窗（run/history）。**启停开关与「立即运行」内联在行上，不经浮窗**——它们是运行控制而非配置编辑，配置去浮窗、控制留块内这条线划清楚。浮窗内另放「编辑」「立即运行」，避免"盯着失败历史想重跑却要先关浮窗回块里点行"。

**8. 失败反馈：不引系统通知。** 失败只在任务行点红点、活动摘要带警示色、错过计数器上浮。为"备份失败了"一个场景引入一类系统权限、还要裁定权限申请的归属层级，账不划算；且活动摘要在刘海紧凑带里本来就亮着，那是这个 app 最不容易被忽略的位置。

**9. run 列表与输出用 `BlockPopover`，卡片尺寸受块尺寸约束。** 容器是 Kit 的 `BlockPopover.shared`（`placement: .overlay`，锚定块自身 frame）。硬约束来自 `NotchPanelInteraction.isPointInExpandedStayRegion`：鼠标"停留区" = `visibleDrawerFrame ± 10pt`，**浮窗窗口完全不参与判定**；光标离开停留区 → 250ms 后 `collapse()` → 投递 `.notchCenterDrawerDidCollapse` → `BlockPopover` 自动 `dismiss()`。因此**卡片任何部分伸出块矩形，那块区域就是鼠标永远碰不到的**（手刚移过去浮窗就没了）。唯一稳定解法是让卡片 ⊆ 块：

```text
cardSize = clamp(理想尺寸, 下限, 块渲染尺寸 − BlockPopover.cardInset)
```

两张卡（历史卡、设置表单卡）共用这一条。**块三档因此必须往大定**：min 480×340 / rec 660×460 / max 960×760。块内的实际 frame 由块视图自建 `GeometryReader`（`.global`）捕获——**不能用 `context.layoutInfo.frame`**，宿主在正常渲染路径填的是 `layoutEngine.frame(for:)`，即网格本地坐标（`NotchPanelContent.swift:412`），只有齿轮设置路径才传 `GlobalFrameReader` 的真全局 frame，同一字段两义。

**配套 Kit 加法**：`BlockPopover.margin` 是 `private static let`，插件读不到。让插件硬编码一个 48 的镜像值就是往仓库塞一个必然腐烂的重复真相（违反 AGENTS.md"同一『为什么』信息全局只写一处"）。故新增 `public static let BlockPopover.cardInset: CGFloat`（`= margin * 2`）并在 `present` 内复用，纯加法、既有调用方零影响。

**其他直接定死的实现约定**（未单列决策，但影响实现）：

- 元数据/输出分离：run 索引（时间、状态、退出码、耗时、**命令快照**、输出文件名）走 `StateStore` 单键 JSON；完整输出走 `StateStore.resourceDirectory("runs")` 一 run 一文件。单键 JSON 每次追加要读全量再写全量，500 条 × 10KB = 每次跑完命令重写 5MB，不可接受。
- 存命令快照：任务定义会改，不存快照则三个月后翻历史不知道当时跑的是什么。
- 输出截断：保留头部 64KB + 尾部 64KB，中间标注省略字节数（只留头部切掉报错，只留尾部切掉上下文）。**实现期细化三点**（写代码时才发现原表述不足以落地）：
  - 输出文件另有**硬上限 1MB**，超过即停止写入并置截断标记——没有这个上限，一条 `yes` 就能把磁盘写满。
  - 「头 64 + 尾 64」是**读取时的投影**，不是写入策略。写入就是普通 append-only 日志，于是**运行中读文件尾即最新进度**（watch 语义，护住决策 5 的初衷：输出超过 64KB 时实时视图不该冻结），跑完才读头尾投影看完整上下文。
  - 只有"读"分两种，写只有一条路径。
- 调度规则的边界语义（纯函数单测锁死）：`每 N 分钟` 与整分对齐且**跨午夜后重新对齐**（step 不整除 1440 时对齐偏移会变）；`每月 31 日` 遇到没有该日的月份**跳过整月**（不顺延到月末——"每月最后一天"是另一个语义，不该由 `31` 隐式承担）；夏令时跳时日**整日跳过**（`bySettingHour` 在 02:30 不存在时会顺移到 03:00，校验 hour/minute 不符即判定该日无此时刻）。
- run 的生命周期 = **直接子进程**的生命周期：管道在子进程退出后再宽限 1 秒收尾（`descendantDrainGrace`），否则任务里 `my_daemon &` 这种会让 run 永远卡在"运行中"；宽限结束后关读端，那个后代再写标准输出会拿到 EPIPE。这是该语义的必然结果，已在插件 README 记明。
- ANSI 转义码存储保留原文、渲染时剥离。
- 保留策略：每任务最近 50 次 + 输出目录 200MB 双上限，超出按最旧删；另有手动清空。
- 同任务不重叠（到点仍在跑即跳过，与决策 1 的不补跑同源）；不做全局队列、不设全局并发上限；多任务各自独立并发。
- 守卫超时默认 30 分钟，任务级可改可关。无超时 = 卡死任务永久占住槽位且**失败是静默的**。
- 超时杀**进程组**：`POSIX_SPAWN_SETPGROUP` 让 zsh 当组长，`SIGTERM` 整个 `-pgid`、宽限数秒后 `SIGKILL`。只杀直接子进程时 `zsh -c "a | b"` 的 `b` 会变孤儿继续写日志。
- 宿主退出/插件禁用：杀运行中进程组，该 run 记 `aborted`（不是 `failed`——被你自己关掉不是失败）。
- 宿主启动：历史里所有 `running` 状态的 run 一律改 `interrupted`，否则崩溃几次后堆着永远"运行中"的僵尸记录。
- 保存任务时不校验 `cwd` 是否存在：定时任务跑在未来，那时外挂卷可能才挂载好；运行时失败并如实记录才对。
- "每 N 分钟"与整分/整点对齐（cron 语义），不是从创建时刻起算；夏令时跳时日直接跳过，不顺延。
- 不预置任何示例任务：调度器插件自带示例任务 = 装完就开始在你机器上执行命令。
- 不注册 `QuickAction`，不做紧凑块（活动摘要已占那个位置，紧凑块还要自绘视觉）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 宿主内 Timer（本方案） | 零 launchd 侵入；历史统一进 StateStore；执行/杀进程/取消都是进程内操作，UI 反馈即时 | 宿主退出/崩溃期间任务静默不跑 | **选此** |
| B. 每任务生成 LaunchAgent | 宿主没运行也照跑、活过崩溃，最接近真 cron | 要另写动态 plist CRUD + `bootstrap`/`bootout`；用户 `~/Library/LaunchAgents` 被塞 N 个文件，卸载不清就留垃圾；历史得从 launchd 的 stdout 文件里捞，与自己维护的索引对不上（任务删了 agent 还在跑、plist 被手改、`bootout` 残留，每条都是新事故源） | 否——现实里这个配件 app 就该一直开着，成本不在注册动作而在维护一份与 launchd 真相对齐的索引 |
| C. A 为默认 + 单任务可提权 launchd | 想要可靠性才付代价 | 两套执行路径、两种日志来源、两个真相位同时维护，v1 工作量约翻倍 | 否——留作将来可选 |
| 2A. cron 五段字符串 | 表达力拉满，开发者熟悉 | 解析器几百行 + 夏令时 / `0 0 31 2 *` / 跳时日等边界；且选择器 UI 上还要糊一层"选择器 → cron 字符串"翻译 | 否 |
| 2B. 结构化五档（本方案） | UI 全是选择器；无解析器 = 无解析 bug；Codable 直接落盘 | 表达不了"工作日 9:00–18:00 每 5 分钟""每月最后一天" | **选此**——表达力缺口出现时再加可选高级字段，不丢数据 |
| 3A. `zsh -lc` 登录 shell | 完全复用用户 rc，nvm/pyenv 直接可用 | 每次多几十到几百 ms；rc 里任何 `echo` / `nvm` 默认加载都混进任务日志；结果依赖本机 rc 内容，不可测试不可复现 | 否 |
| 3B. 结构化 argv 不经 shell | 无注入面，参数无歧义 | 写不了管道、重定向、`&&`、`$(...)`——这些是需求本身 | 否 |
| 5A. 跑完才落盘 | 实现最简 | 长任务期间无任何中间信息；进程崩溃即全丢 | 否 |
| 5C. 内存实时 + 结束后落盘 | 可见性与 B 相同 | 并发时内存常驻多份输出；崩溃全丢。是 B 的严格劣化版 | 否 |
| 6A. 块内主从导航（编辑也在块内） | 一处数据一处 UI，一个真相源 | 块内要自写导航状态机 | 否（用户选 6B） |
| 6B. 编辑走设置浮窗（本方案） | 复用宿主统一浮窗，省掉块内表单 | 列表/日志在块内、编辑在浮窗，两个容器；同一份任务 schema 要在两处渲染 | **选此**——代价是"改完命令视线要重新回到块内" |
| 7A. 执行流水为首页 | 诊断"最近跑了什么/有没有失败"最快 | 任务维度要切筛选条 | 否（用户选 7B） |
| 7B. 任务列表为首页（本方案） | 任务维度第一眼可见 | "昨天那次为什么失败"要两次点击 | **选此** |
| 8B. 失败弹系统通知 | 失败主动找到你，哪怕抽屉关着 | 新引入 `UserNotifications` + 通知授权；要裁定权限申请归属（并入 `PermissionCenter` 还是插件自申请，涉及宿主 bundle 声明） | 否 |
| 9A. 仍用 `BlockPopover` 但卡片压进块矩形（本方案） | 零新窗口代码，复用既有外观/动画/坐标换算 | 日志视图上限 = 块尺寸；读日志期间鼠标须留在抽屉范围内 | **选此** |
| 9B. 独立无边框 NSPanel（`DepthOverlay` / Scratchpad QuickLook 模式） | 尺寸自由；抽屉收起后窗口仍在屏上，可边读日志边干别的 | 自管窗口生命周期、层级、多屏、关闭时机；须守 `orderFrontRegardless` 纪律（`NotesPlugin` 踩过 `makeKeyAndOrderFront` 把已收起抽屉重新拉上屏） | 否（留作 9A 实测被卡时的退路） |
| 9C. 先 A 实测再退 B | 分步验证 | 可能白做一轮 | 否 |

## Consequences(影响)
- **新增插件** `Plugins/CommandSchedulerPlugin`（PluginID `com.zhouzihang.notchcenter.commandscheduler`，无额外 Dependencies——不需要 `LaunchdControlKit`，不动 Project.swift 的 `knownExtraDependencies` 白名单）。块 `command.scheduler`（抽屉，min 480×340 / rec 660×460 / max 960×760，`placement: .newPageWhenOccupied`），摘要 `command.scheduler.summary`。
- **Kit 公共 API 变更**：`BlockPopover.cardInset` 新增 → `NotchCenterKitAPI.currentVersion` 升 `1.5.0`，明细入 `docs/api-changelog/BlockPopover.md`（新建，该接口首条）。纯加法、非破坏、无迁移。
- **块视图必须自建 `.global` frame 捕获**，不得直接用 `context.layoutInfo.frame` 当浮窗锚点（网格本地坐标）。这是一个容易踩的坑，已在决策 9 记明来源。
- **块的 max 960×760 明显大于既有官方块**（`notes.notebook` 600×480、`pomodoro.page` 900×600）。这是 9A 约束的数学后果，不是随意放大。
- ⚠️ **发现一处既存门禁缺口（不是本决策引入）**：`scripts/build.sh verify-sizes` 用 `-only-testing NotchCenterTests/BlockMinSizeVerificationTests` 指向一个**测试源码里不存在的套件**（`BlockSizeVerifierTests.swift` 的注释、`docs/插件开发指南.md` §3 与 `2026-09-07-block-min-size-occlusion-verification` 都引用了它，但类已不存在）。xcodebuild 对不存在的套件名静默跳过，于是「官方 drawer 块必须声明 probes」这条被文档称为"门禁强制"的规则**实际是空转的**——现在只有 10 个纯几何用例在跑，没有任何测试枚举官方插件校验其探针声明。
  - 本次不越权重造全仓门禁（可能一次性点亮多个存量插件的红）：改为在 `CommandSchedulerTests` 里锁**本插件自己**的块声明——探针非空、在 `minSize` 下经 `BlockSizeVerifier` 无违规、`minSize` 装得下工具行 + 声明的最少行数、`minSize − cardInset` 不触到卡片兜底下限（即决策 9 的"卡片 ⊆ 块"不变量在最小尺寸下仍成立）。
  - 建议另开一条 note/PR 决定是全仓重建该门禁还是删除这条幽灵引用。
- 实现落地：note 由 `proposed/` 移入 `implemented/`。全量测试 54 项通过（含 7 项真跑进程的执行器用例：退出码与流合并、cwd/env 生效、注入 PATH 到达子进程、**守卫超时杀进程组（用"后代若存活就会写文件"作行为判据，不用 `kill(pid,0)`——它对僵尸同样返回 0）**、取消记 `aborted`、cwd 不存在如实报错、输出硬上限截断）。
- **`resourceDirectory("runs")` 的使用是对 `StateStore` 文档约定的一次援引**：约定写明"仅当键值模型不适合（媒体文件）时使用；普通状态一律走键值 API"——追加型大文本正是不适合塞进 JSON 单键的那种，run 索引仍走键值 API。
- 提醒：`docs/插件开发指南.md` 与 `docs/开发者工作流与门禁.md` 的插件清单类内容若列举官方插件，需补本插件（实现落地时核对）。已核对并补：`docs/agents/宿主开发约定.md` 的目录地图、`Tests/NotchCenterTests/LocalizationTests.swift` 的两处插件清单（`modules` 与 `pluginPlistCarriesChineseMetadataLocales` 参数表）——后者是硬编码数组，不补的话新插件的 en/zh 键位奇偶校验与双语元数据门禁都会静默漏过本插件。

## Changelog

- 2026-09-19: 初稿。九条决策经设计追问逐条敲定；决策 9 的停留区约束由代码勘验（`NotchPanelInteraction` / `BlockPopover`）发现并写入硬约束。
- 2026-09-19: 实现落地（插件、Kit 加法、单测齐备），状态转 `implemented`；补记输出截断的读取投影细化、规则边界语义、run 生命周期语义，以及发现的 `BlockMinSizeVerificationTests` 幽灵引用缺口。
- 2026-09-20: 决策 9 的块尺寸与门禁口径被 [2026-09-20-command-scheduler-floating-add](2026-09-20-command-scheduler-floating-add.md) **部分取代**——块内工具行撤销、新建钮改右上角悬浮角标、minSize `480×340` → `300×300`，卡片兜底下限不再是固定 320×200。本 note 的调度/执行/存储决策（1–5、6 的表单落点、7 的列表主视图、8 的失败反馈）全部仍然有效。
