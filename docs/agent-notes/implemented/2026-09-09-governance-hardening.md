# Agent Note:治理加固 - 合规硬门禁与注释单源化

status: implemented
date: 2026-09-09
deciders: zhouzihang
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

治理体系([2026-09-02 治理落地记录](../implemented/2026-09-02-doc-driven-dev-governance.md))落地后,机器门禁只覆盖"已有文档的格式",两类问题没有被机器约束:agent 经常跳过决策记录流程直接执行任务;同一注释信息重复写在多个文件里,又长又难维护。

诊断数据(09-02 至 09-09,git 实测):

- 触及 `Sources/`、`Plugins/` 的 commit 共 55 个(feat 37 / refactor 8 / fix 5 / 其他 5),agent-note 仅 17 份(implemented 12 / proposed 4 / archive 1),大量非平凡变更无决策记录。
- 3 份 proposed note 实现已落地 main 却滞留原目录(见 D7),SOP 的"git mv 归档"步骤零执行。
- 根因一:规则两级跳转,AGENTS.md 只给索引,真正的"何时必须写 note"藏在工作流文档第 2 步,且判定词"非平凡"是主观判断,agent 易合理化跳过。
- 根因二:现有 7 项门禁只校验"已有 note 的格式",不存在"该有而没有"的检测。
- 根因三:注释重复属实:本地化辅助样板注释在 14 个文件逐字重复,placementStore 说明散在 17 个文件,离散 why 注释多处双份;docs 内部同样重复(工作流速查表红线列与 8 个子文档各存一份)。

目标:把"自觉"换成"机器可验证",把"重复"变成"可检测违规"。

## Decision(决策)

决策经 grill 访谈 4 轮收敛,共 15 项,分三组:

| 编号 | 决策 | 落点 |
|------|------|------|
| D1 | 混合强制:硬门禁管"有没有写",人审管"写得好不好" | commit-msg 钩子 + CI;质量评审由 decider 承担 |
| D2 | 触发规则:触及 `Sources/` 或 `Plugins/` 且消息类型非 `fix:`/`docs:`/`chore:`/`test:` 的 commit,消息须含 `(note: <日期>-<slug>)`,且 `docs/agent-notes/proposed/` 或 `implemented/` 下存在同名文件;同 commit 新增的 note 算数;无类型前缀视为非豁免;引用 `archive/` 不算数 | 脚本 1(commit-msg 钩子 + CI 区间模式) |
| D3 | 类型语义收紧:`refactor:` 必须带 note;小重构/纯格式/微调标 `chore:` | 写入 AGENTS.md 硬规则 |
| D4 | 生命周期硬线:note 自 frontmatter date 起滞留 `proposed/` 超 7 天 → 门禁红;处置 = git mv 至 `implemented/`/`archive/`/`rejected/` 之一 | 脚本 2(入 run-doc-checks.sh,pre-commit + CI 双挂) |
| D5 | 执行点:生命周期与重复注释检查并入 `run-doc-checks.sh`;note 覆盖检查走 commit-msg 钩子 + CI 区间步骤 | [run-doc-checks.sh](../../../scripts/run-doc-checks.sh)、[docs.yml](../../../.github/workflows/docs.yml) |
| D6 | 入口与预算:硬规则写进 [AGENTS.md](../../../AGENTS.md) 正文;预算 PR 提额 target 1700→2200、max 1900→2400;单入口只服务 pi + Zed,不新增 CLAUDE.md | [doc-budgets.manifest.json](../../../doc-budgets.manifest.json);实测新 AGENTS.md 全文 1698 字符,现上限 1900 已可容纳,提额仅为未来硬规则预留,可裁剪 |
| D7 | 存量不回溯:门禁自激活 commit 起算;3 份滞留 note 在实施时 mv 至 implemented | 见存量清理清单 |
| D8 | postmortem 维持人工判断,不进机器门禁 | 无脚本 |
| D9 | SSOT 分流:领域红线/历史事故/架构决策 → `docs/`;局部 why → 代码注释,且同一信息全局只写一次,重复即违规 | 写入 AGENTS.md 硬规则 |
| D10 | 重复注释脚本:归一化短语 ≥15 字符、出现在 ≥3 个文件 → 门禁红;只扫 `Sources/`、`Plugins/` 的 Swift 文件;排除 `MARK:` 行与许可证头;v1 无白名单,误报调参 | 脚本 3(入 run-doc-checks.sh) |
| D11 | 长度纪律:无机器门禁,评审指引"注释块 >6 行考虑外置 docs" | 写入 AGENTS.md |
| D12 | 存量清理:机械样板注释全量清;离散 why 注释边改边清 | 见存量清理清单 |
| D13 | docs 内部重复:速查表删"最易踩的红线"列,退化为纯索引(领域 → 链接),红线只在子文档存在 | [开发者工作流与门禁](../../开发者工作流与门禁.md) 第三节 |
| D14 | 方案即本 note;批准后 git mv 至 implemented,治理记录闭环 | 本文件 |
| D15 | 验收标准:负向用例被拦、正向用例放行、存量清单清零、全量测试与门禁绿 | 见实施步骤第 5 步 |

**脚本 1:`scripts/verify-agent-note-coverage.sh`(note 覆盖门禁)**

```text
# 模式 A(commit-msg 钩子):--message-file $1
#   msg=$(cat "$1")
#   files=$(git diff --cached --name-only)      # staged 文件
# 模式 B(CI 区间):--range <before>..<after>
#   for c in $(git rev-list $range):
#     msg=$(git log -1 --format=%B $c)
#     files=$(git diff-tree --no-commit-id --name-only -r $c)
#   跳过激活 commit 及更早提交(激活点 = git log --diff-filter=A 定位本脚本的那次提交)
# 判定:
#   1. files 未触及 Sources/ 或 Plugins/ → 通过
#   2. msg 匹配 ^(fix|docs|chore|test)(\([^)]*\))?!?:  → 通过(豁免,支持 scope 与 !)
#   3. 提取 msg 中所有 "(note: X)" → 一个都没有 → 失败,提示:加引用或改标 fix/docs/chore/test
#   4. 每个 X 校验 docs/agent-notes/proposed/X.md 或 implemented/X.md 存在(staged 即在工作树)
#      → 任一不存在则失败,列出两目录下可引用的文件名
#   5. 全过 exit 0
```

```bash
#!/bin/sh
# managed:doc-driven-dev v3 - 决策记录引用门禁(逻辑见 scripts/verify-agent-note-coverage.sh)
scripts/verify-agent-note-coverage.sh --message-file "$1" || { echo "note gate failed"; exit 1; }
```

**脚本 2:`scripts/verify-note-lifecycle.sh`(proposed 滞留硬线,入 CHECKS 数组)**

```text
# 扫描 docs/agent-notes/proposed/*.md(.gitkeep 忽略)
# 取 frontmatter 行 ^date: ([0-9-]+)
# today=$(date +%F);cutoff 按平台:Darwin 用 date -j -v-7d +%F,Linux 用 date -d '7 days ago' +%F
# date < cutoff → 违规,输出:该 note 滞留 N 天,处置 = git mv 至 implemented/archive/rejected
# 任一违规 exit 1,错误信息含精确的 mv 命令
```

**脚本 3:`scripts/verify-comment-duplication.sh`(重复注释门禁,入 CHECKS 数组)**

```text
# 收集 Sources/ 与 Plugins/ 下 *.swift 的 // 注释行(块注释 v1 不扫)
# 归一化:去行首空白与 //+ 前缀,trim 首尾空白;awk length() >= 15 才计数(字符数,非字节)
# 排除:^MARK: 行;含 Copyright/License 的许可证头
# 按"归一化文本 → 出现文件集合"统计;同一文本出现在 >=3 个文件 → 违规,列出全部文件
# 阈值常量 MIN_LEN=15 / MIN_FILES=3 写在脚本头,误报调参;v1 无白名单
# 任一违规 exit 1
```

**AGENTS.md 硬规则段(新文本草稿,替换现行"改前必读"段之前插入)**

```text
## 硬规则(机器门禁强制,违反的 commit 会被拦截)

- 触及 `Sources/` 或 `Plugins/` 的 commit,消息类型非 `fix:`/`docs:`/`chore:`/`test:` 的,须在消息里引用决策记录 `(note: <日期>-<slug>)`,且 `docs/agent-notes/proposed|implemented/` 下存在同名文件;无类型前缀视为须带 note;小重构/纯格式/微调标 `chore:`。
- 非平凡架构/接口/行为变更:动手前先按[模板](docs/templates/agent-note.md)在 `docs/agent-notes/proposed/` 写决策记录;实现落地即 `git mv` 至 `implemented/`;滞留 `proposed/` 超 7 天门禁红(移入 `archive/` 或 `rejected/` 亦可解)。
- 同一"为什么"信息全局只写一处:领域红线/历史事故 → `docs/agents/` 子文档;代码注释只写从代码看不出的局部原因,不得跨文件复制。
```

其余段落与现行 AGENTS.md 相同,仅两处机械修改:全文破折号统一为连字符;末段"字数预算"上限数字改为 2400(若 D6 提额被裁剪则保持 1900)。

**存量清理清单(实施第 3 步一次性完成)**

- 3 份滞留 note → git mv 至 implemented/:`2026-09-05-clipboard-history-plugin`、`2026-09-05-drag-dwell-page-switch`、`2026-09-08-service-block-compact-layout`(实现均已落地 main)。
- 速查表:[开发者工作流与门禁](../../开发者工作流与门禁.md) 第三节删"最易踩的红线"列,保留"领域"与"改前必读"两列。
- 本地化辅助样板:12 个插件 `L10n.swift` 与 `Sources/NotchCenter/Localization.swift` 中的重复注释删除,样板说明只留 `Sources/NotchCenterKit/L10n.swift` 一份;"带格式化参数"句(9 处)同步处置。
- placementStore 说明散在 17 文件:引用不删,说明性注释收敛至 Kit 定义处,其余改一行指针或删除。
- MARK 副本:长按浮窗(3 份)、浮窗入口(3 份)、抽屉块视图(2 份)等,留语义最完整一份,其余删。
- 离散 why 副本(抽屉收起 orderOut、ServiceBlockView 统一说明等):实施时逐条判定,离定义最近的一份为正本,其余删或改一行指针。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 混合硬门禁(D1 采用) | 机器管存在性、人管质量,缺一不可 | 新增两道 commit 摩擦 | 采用 |
| 纯软约束:重写措辞 + checklist,不加门禁 | 零摩擦 | 已实测无效:55 个 commit 仅 17 份 note | 否 |
| 同 commit 强制携带 note 文件 | 关联零歧义 | 粒度错位,多 commit 功能会重复写 note | 否 |
| 存量全量回溯补 note | 历史完整 | 半数以上是透明度 0.6 级微调,性价比极低 | 否(D7) |
| 注释长度机器门禁 | 可量化 | MARK 分区、公式推导误伤,催生拆碎注释的形式主义 | 否(D11) |
| swiftlint 全面接管注释规则 | 生态成熟 | 新增工具链;中文注释规则弱 | 否(D10) |
| 预算压缩腾空间(不提额) | 免 PR 仪式 | 挤占入口余量;实测草案 1698 已达标,提额仅预留 | 提额(D6,可裁剪) |
| 7 天线只挂 CI | 不扰无关任务 | 反馈慢,与强制归档目标不符 | 否(D4/D5) |

## Consequences(影响)

- 新 commit 门槛:pi / Zed 触及 `Sources/`、`Plugins/` 的非豁免 commit 必须带 note 引用,违规在 commit 时即被拦;纯 UI 微调改标 `chore:`/`fix:` 即可豁免。
- 归档强制:proposed 滞留 7 天即红;长周期规划若 7 天内无法实现,移至 `rejected/` 注明待排期,排期后按新日期重新提回 `proposed/`。
- 注释纪律:跨文件复制注释在提交时即红;存量样板一次性清理,离散 why 边改边清。
- 质量线仍靠人:note 写得好不好、注释是否真解释"为什么",由 decider 评审,机器不判质量。
- 本 note 批准即 git mv 至 implemented,完成治理记录的闭环(治治理者本身也走同一流程)。

## Changelog

- 2026-09-09:初稿(proposed)。grill 访谈 4 轮收敛 15 项决策;含 3 个新脚本设计、AGENTS.md 硬规则草稿、存量清理清单与实施步骤。
- 2026-09-09:批准。按 D14 git mv 至 implemented;同日实施:提额(D6,不裁剪)→ 存量清理 → 脚本/钩子/CI 激活 → 双向验收。
