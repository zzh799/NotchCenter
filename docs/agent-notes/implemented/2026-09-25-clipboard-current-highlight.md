# Agent Note: 剪贴板列表高亮改为持续追踪"当前剪贴板内容"

status: implemented
date: 2026-09-25
deciders: 用户（"点击列表项从显示绿色✅改为列表项高亮，高亮持续到剪贴板内容与当前不同，即始终高亮当前剪贴板内容"）+ 实现代理
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

现状：点击列表项写回剪贴板后，被点击的行短暂（1.5s）显示绿色 ✓ 与高亮底色（`justCopiedID` + `flashCopyFeedback` 定时清除）。这是**点击反馈**语义，闪一下就消失，用户无法从中看出"现在剪贴板里到底是什么"。

要改的是**状态追踪**语义：高亮永远标记"内容等于当前剪贴板内容的那条历史"，即：

- 点击写回 → 该条持续高亮（不再是 1.5s 闪示）；
- 外部复制了新内容且被记录 → 高亮随记录转移到新条；
- 再复制历史里已有的内容（去重命中旧条）→ 高亮命中条；
- 剪贴板变成历史里没有（或未记录）的内容 → 无高亮。

约束与既有机制——

- **轮询是两段式**（`ClipboardHistoryStore` 文件头）：`probe()` 只读计数与类型名表，载荷字节只在确认值得记录后才读。持续高亮不能破坏这个结构——不能为"对齐高亮"而每个 tick 读载荷。
- **隐私红线**：transient / concealed / 暂停期的载荷刻意不读不记。高亮语义下这些内容的对应条目不存在，只能表现为"无高亮"，不能为对齐高亮去偷读它们。
- 高亮的**事件源已经齐全**：写回（`copyBack`）、记录（`ingest(payload:)`）、去重（`recording` 命中旧条）都是离散事件，各自天然知道"此刻剪贴板内容对应哪条"；无需额外轮询。
- **启动时刻**剪贴板内容与历史的对应关系未知（attach 只认领计数不读载荷）。一次性读一次载荷做匹配可以补齐，但要防"读载荷期间剪贴板又变了"的过期写入。
- 文件写回被拒（原路径失效）的**失效闪示**（`copyFailedID`）与本决策正交：它是错误反馈不是状态追踪，保留原样。

**不做**（out of scope）：对每个 tick 做内容级比对（破坏两段式轮询）；为高亮在抽屉/库页之外新增指示；改 `copyFailedID` 的失效闪示行为。

## Decision(决策)

**一句话：把 `justCopiedID`（1.5s 闪示）替换为 `currentClipboardEntryID`（持续状态），由事件驱动维护"当前剪贴板内容对应的历史条目 id"，视图层据此高亮行；剪贴板内容对不上任何条目时无高亮。**

**D1 — 事件驱动维护，不做内容轮询。** 维护点只有四处，全部复用既有事件：

1. `copyBack` 写回成功 → 置为该条 id（持续，不定时清除）；
2. `ingest(payload:)` 记录成功 → 置为 `next` 里与本次载荷同 `matchKey` 的条目 id（新记录是新 id、去重命中旧条是旧条 id，同一段匹配代码两者都覆盖）；
3. `ingest(probe:)` 认领了一次**未记录**的变化（暂停 / transient / 空载荷 / makeEntry 拒收）→ 置 nil（剪贴板已变成历史里没有的内容，无高亮才是诚实态）；自循环认领（写回快照）→ 不动；
4. `attach` 启动对齐：轻探测非 transient 时读一次载荷做匹配（见 D3）。

理由：两段式轮询的红线是"每个 tick 只读计数、不读载荷"（决策记录 2026-09-20-clipboard-media-types 的 D3），事件点的语义已经足够精确，为高亮再开一条轮询读取纯属浪费且更易漏。

**D2 — 匹配身份复用 `matchKey`。** "剪贴板内容对应哪条"的判定与去重同源：文本按正文、图片按内容哈希、文件按路径集合（`ClipboardHistoryLogic.matchKey`）。不另造一套相似度比较——两套"内容是否相同"的判定必然漂移。

**D3 — attach 时一次性对齐，且有过期防护。** 启动时剪贴板里大概率是历史里已有的内容（上次会话复制的），此时无高亮违背"始终高亮当前内容"的语义。做法：`attach` 里轻探测，transient 直接无高亮（不偷读）；否则后台读一次载荷、主线程匹配后置 id，**应用前核对 `lastSeenChangeCount` 仍等于探测时的计数**——读载荷的几十毫秒里剪贴板又变了的话，这份快照过期，交给后续 ingest 收口。

**D4 — 删除/清理条目时 prune。** 高亮条目被 `delete` / 清理移除 → 置 nil（内容虽还在剪贴板上，但历史里已无对应条目）。并入既有 `pruneCopyFeedback(keeping:)`。

**D5 — 视图层：✓ 移除，高亮底色接棒。** 抽屉块行：行背景 `isCurrent ? fillHighlighted : fill`（沿用原 `justCopied` 的底色 token，动画值同步换）；库页最近列表行：`isCurrent ? fillHighlighted : .clear`；库页置顶卡常显 `fillHighlighted` 底色、无处可"更亮"，改用选中描边（`Hairline.chipSelected`，与筛选 chip 选中态同款）表达。行内绿色 ✓ 图标与 `drawer.button.copied` 文案键一并移除。行 a11y 追加 `.isSelected` trait。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 事件驱动维护 currentClipboardEntryID（本决策） | 零额外轮询；复用 matchKey；语义精确 | 依赖事件点覆盖完整（漏一处就漂移） | **采用** |
| B. 每个 tick 读载荷做内容比对 | 无事件遗漏风险 | 破坏两段式轮询红线；暂停期/transient 的载荷不该读；每秒读数 MB 图片不可接受 | 否决 |
| C. 高亮只标"最后一次写回的条目"，不随外部复制转移 | 实现最简（一行） | 剪贴板内容变了高亮不跟，违背"始终高亮当前剪贴板内容"的需求本意 | 否决（用户拍板） |
| D. attach 不做启动对齐 | 少一条一次性读取路径 | 启动后直到下一次复制前，当前剪贴板内容明明在历史里却没有高亮，语义破洞 | 否决（D3 兜住成本与过期风险） |
| E. 保留 1.5s ✓ 叠加在持续高亮上 | 保留旧反馈 | 两套反馈闪烁同一行，视觉噪音；高亮本身已是"写回成功"的充分反馈 | 否决 |

## Consequences(影响)

- **改动落点**：`ClipboardHistoryStore.swift`（`justCopiedID` → `currentClipboardEntryID`、`flashCopyFeedback` 拆分、`ingest` 两处维护、`attach` 对齐、`pruneCopyFeedback` 扩展）、`ClipboardHistoryViews.swift`（抽屉行）、`ClipboardLibraryViews.swift`（库页行 + 置顶卡）、双语 `Localizable.strings`（移除 `drawer.button.copied`）、`ClipboardHistoryTests.swift`（断言迁移 + 新增用例）。
- **行为变化**：写回反馈从"1.5s 闪 ✓"变为"持续高亮直到剪贴板内容改变"；暂停期 / 复制密码（transient）后高亮消失（剪贴板内容已不可知）。
- **回归面**：文件写回被拒的失效闪示（`copyFailedID` 不变）；自循环认领（`writeBackSnapshot`）路径不得误清高亮。
- **测试**：断言迁移三处；新增"再复制已有内容高亮旧条""未记录的外部变更清空高亮"两例。

## Changelog

- 2026-09-25: 初稿（proposed）。需求由用户提出并拍板（C 方案否决）；D1-D5 由实现代理按两段式轮询红线与既有去重机制拍定。
- 2026-09-25: 实现落地（`ClipboardHistoryTests` 全量 122 例通过），同日移入 `implemented/`。写回被拒时持续高亮**保持不变**（剪贴板内容未变，仍对应该条），失效闪示（copyFailedID）叠加提示。**真机项**：抽屉行 / 库页行 / 置顶卡三种高亮观感与 attach 启动对齐的实际表现未做真机核对。
