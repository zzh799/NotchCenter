# Agent Note: 剪贴板采集图片与文件（富媒体条目）

status: implemented
date: 2026-09-20
deciders: 用户（要求"剪贴板组件，支持更多的剪贴类型"）+ 实现代理（逐分支征询后定稿）
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

剪贴板历史自 [2026-09-05-clipboard-history-plugin](../implemented/2026-09-05-clipboard-history-plugin.md) 起只采集**纯文本**。`ClipboardEntryKind` 里的 `image` / `file` 一直是**预留位**，其类型注释写明了当初的取舍："富媒体采集涉及落盘、去重与缩略图缓存，是独立一期的工作量；枚举先占位，使持久化格式与筛选 UI 的形状定下来，二期接采集时不需要再动存储结构。"本决策就是把这两条预留位落地，并回答"收哪些类型"这个根问题带出的全部下游依赖。

现状有五条硬约束，改动面由它们决定——

- **采集路径只认文本**：`ClipboardSnapshot` 只有 `text: String?` + `typeNames`；`SystemClipboardReader.snapshot()` 只读 `.string`，`writeBack(_:)` 只写 `.string`。
- **`ClipboardEntry.text` 非可选**：`init(from:)` 用 `decode(String.self, forKey: .text)` 读**必填键**；搜索（`filtered` 的 `localizedCaseInsensitiveContains`）、连续重复去重（`entries.first?.text == trimmed`）、无障碍标签全部建立在这个字段上。
- **单条上限 100KB**（`maxSingleBytes`）：对文本是合理的防爆，对截图等于直接拒收。
- **1 秒轮询**（`activeInterval`，抽屉可见时）：每拍只取一个字符串。改成每拍取图像数据，等于常年挂着的宿主每秒拷贝数 MB。
- **持久化是"一个 JSON 对象"**：`stateStore.setObject(entries, forKey:)` 每次 persist 序列化**全部**条目；往里塞 MB 级图片数据会让每次命中都重写几 MB、每次启动全量解码。

**不做**（out of scope，逐条都是本期显式否决）：富文本（RTF / HTML）采集；任意 `UTType` 泛化（表格 / 日历 / 通讯录 / 代码等）；图片 OCR（因此图片条目搜不到内容，见 D4）；模拟 `Cmd+V` 直接粘贴到前台 App（沿用 v1 契约）；「复制为文件」动作（见 D7）；`sourceApp` 填充（1 秒轮询拿不到可靠的"谁写的剪贴板"，记错来源比不记更糟）；静态加密（见 D8）。

## Decision(决策)

**一句话：把"一条剪贴板历史 = 一段可比对的纯文本"换成"一次复制 = 一条条目，类型决定载荷形态与去重键"，同时保证文本路径的行为逐字不变。**

**D1 — 类型范围只收图片与文件。** 依据是 `ClipboardEntryKind` 的预留位注释本身就是为这个范围写的。富文本被否的真正理由不在采集而在**写回保真**：README 已声明 v1 不做直接粘贴，那格式保真就完全取决于用户自己 Cmd+V 的目标 App——收一个保证不了保真度的类型是在造预期落差。任意 `UTType` 泛化则会让筛选栏、缩略图与搜索三套体系同时面对无界类型空间。

**D2 — 一次复制 = 一条条目（聚合粒度）。** 多选多个文件复制时聚合为一条，写回时整组放回。核心不是 UI 省纵向空间，而是 `copyBack` 的契约："把用户当时复制的东西原样放回去"。拆成 N 条会同时废掉批量粘贴能力，并让一次复制就吃满置顶 5 条上限（`maxPinned`）。载荷走 `ClipboardEntry.fileURLs: [String]`。

**D3 — 采集拆成两段：`probe()` 轻探测 + `readPayload()` 重读取。** 前者只读 `changeCount` 与类型名表（**不读任何载荷字节**，transient 判定也只用它）；只有确认这次变化值得记录（计数变了、非自循环、未暂停、非 transient）之后，才走第二次读重数据。这是 D1 的**准入条件**而非优化项——每拍直接读图像数据，等于常年挂着的宿主每秒拷贝数 MB。

第二段必须持**第一段发出的门票**（`pendingRecordChangeCount`）才能消化载荷。这条约束是踩出来的，不是设计出来的：`lastSeenChangeCount` 当门票会错，因为它在第一段**无论是否放行**都会被更新（暂停、transient、自循环都要认领计数，否则下一拍会反复读同一次变化），于是它证明不了"这次变化被放行了"——暂停期间或 transient 的载荷会在恢复记录后被补记进来，正好违反"暂停期不补记"的既定契约（回归见 `ClipboardHistoryTests.testPausedSkipsRecordingAndResumesFromFreshCount` 与 `testIngestSkipsTransientAndEmpty`）。门票只在放行后发放、被消化时即销毁，因此同一份载荷重复投递也只会记一次。

归类优先级固定为：`.fileURL`（且 `FileManager.fileExists` 为真）> 裸图像数据（`.png` / `.tiff`，兜底收任何声明为 `public.image` 的类型）> 颜色 > 链接 > 文本。理由是 Finder 复制一张图片时 pasteboard 上同时挂着 fileURL 与图像预览数据，用户意图是"这个文件"而不是"这张图"；反过来截图与网页复制图片没有 fileURL，才落成图片条目。**（本句已被 [2026-09-20-clipboard-image-file-and-cache-echo](2026-09-20-clipboard-image-file-and-cache-echo.md) 反转，见 Changelog。）**

**D4 — `text` 保持非可选，改当"可搜索的显示代理"，真实身份另走内容哈希。** 把 `text` 改成可选会波及每一处视图调用与 `history.entries.v1` 的解码契约，收益为零。四条语义分支：`text` / `link` / `color` 照旧按正文去重与搜索；`file` 条目 `text` 存路径串、按路径集合去重；`image` 条目 `text` 存**空串**、按 `contentHash`（原始字节 SHA256）去重。

图片条目存空串是刻意的：没有可搜的文本就是没有，硬造一个"图片 1920×1080"描述串只会让搜索出现假阳性（搜"图片"命中全部图片，零信息量），并把 L10n 拖进刻意不依赖 AppKit 的 `ClipboardHistoryLogic`。**代价要认**：搜索不覆盖图片条目，无障碍标签改由视图层按 `kind` 分支生成（`ClipboardRowView` / `recentRow` / `pinnedCard` 三处）。

**D5 — 原图字节落盘，不塞进 `history.entries.v1`；原样存，不做有损重编码。** 落 `StateStore.resourceDirectory(named: "Media")` 下的扁平目录，条目自己持有 `storedFilename` 直接拼路径。

- **为什么落盘**：见 Context 第五条，整个历史是单个 JSON 对象。先例是 [NotesImageStore](../../../Plugins/NotesPlugin/Sources/NotesImageStore.swift) 的 `Images/` 目录，其注释写明了"媒体文件不适合键值存储，键值 API 仍用于普通状态"。
- **为什么不要 manifest**：`NotesImageStore` 用 `manifest.json` 是因为 `EmbeddedImageRequest` 只带 id / name、需要反向查 `displayName` 与原始路径；剪贴板没有反向查找需求，manifest 是纯负债。
- **为什么不重编码**：`copyBack` 的契约是原样放回。转 JPEG / HEIC 省磁盘、毁契约；而 `NotesImageStore` 那条"非 PNG 转 PNG"的策略在这里也不适用——截图常带 TIFF、网页图常是 JPEG，统一转 PNG 会**膨胀**。所以按原始字节存，格式由 `byteSize` / UTI 记录。
- **缩略图单独落盘生成、单独缓存**，尺寸按 D9 的抽屉行排版定。绝不在行渲染时现解码原图：`LazyVStack` 一次物化十来行，每行解一张数 MB 的 PNG，抽屉直接卡死。

**D6 — 容量用"条数 + 总字节"双上限，字节只对落盘类型计账。** 条数上限对文本够用，对图片**完全失效**：50 条 × 单条 16MB 最坏 800MB。定：

- 总字节预算 **200MB**（`maxMediaBytes`），计账口径是 `ClipboardEntryKind.usesDiskStorage`——**只有图片**。文件条目正文里存路径串、本身不落盘，把它算进字节账只会白白挤掉真实图片的额度（实现期把原定的"文本按 utf8 计入"收窄成"只计落盘类型"，效果同向、口径更诚实，落点见 `ClipboardHistoryLogic.mediaByteSize(of:)`）。
- 单条拒收阈值 **16MB**（`maxMediaSingleBytes`），拦住误复制整个视频文件的情况。超限整份丢弃，不截断。
- 超预算 → 淘汰**最老的未置顶**图片（连同磁盘文件），与 `sanitized` 既有的"从末尾淘汰未置顶"同源。
- **置顶占满预算 → 停收新的富媒体，而不是自动解顶。** 置顶是用户的显式意图，不能被体积预算静默推翻；`sanitized` 现有的"置顶溢出自动解顶"只发生在置顶**数**超 `maxPinned` 时，不得被体积预算复用。判据收敛成一句：`admitsMedia` 只在"仅置顶就已超预算"时返回 false，其余情况由淘汰兜底——新条插在未置顶区首位，从末尾开始的淘汰永远轮不到它。
- **淘汰必须同步删磁盘文件。** 所有条目变更收敛到 store 的单一出口 `commit`（先算被移除的媒体名 → 落盘条目 → 删文件；顺序不能反，否则 persist 失败会留下指向不存在文件的条目）。另在启动时做一次**孤儿对账**（扫 `Media/` 与 entries 集合求差、删无人引用者），因为"写完文件、还没 persist entries 就崩"必然留孤儿，只靠删除路径兜不住。

**D7 — 写回：多文件走多 pasteboard item，图片只写图像数据，失效文件显式报错。**

- **多文件必须 `writeObjects([NSURL, NSURL, ...])`，写成一个 item 一个文件。** 现在是 `clearContents()` + 单次 `setString`。若改成"一个 item 塞多个 URL"，Finder 只认第一个、粘出来少文件，**而且不报错**——静默丢数据。
- **图片条目只写图像数据，不写 `.fileURL`。** 语义稳定性优先：若同时写 fileURL 指向插件数据目录里的原图，微信 / 飞书这类输入框若优先取 fileURL 会把"贴图"变成"发文件"，同一份剪贴板在不同 App 里行为不一致。
  - 表示的具体形态在实现期进一步收窄为：**原始字节挂它自己的 UTI**，外加能由**魔数**确认的同格式标准类型别名（`.png` / `.tiff`）。原定写的"PNG + TIFF 双表示"与同段那条"拆掉运行时编码"的性能约束自相矛盾——生成对侧表示要整图解码，正是 D7 要避免的事；而接收方自行转换是系统常态。别名走魔数嗅探、零解码成本。落点见 `SystemClipboardReader.imagePasteboardTypes(for:uti:)`。
  - **代价要认**：往 Finder 里 Cmd+V 贴图片条目会没反应，README 已写明这是既定行为。
- **文件条目要么整组写回、要么完全不写。** 只写存活的那几个会让用户以为复制了 3 个、实际只拿到 2 个，正是本决策要消灭的静默丢失。任一原路径失效即拒写并在行内显示失效态；不复制副本保活（项目红线），也不静默丢。校验**只在写回时做**，不在渲染时做：每行一次 `fileExists` × 50 行 × 每秒重渲染是白送的 syscall。
- **本期不做「复制为文件」动作**（往 Finder 贴图的显式入口）：需要新交互路径、新 i18n 键，而抽屉块行尾已经挤了置顶 / 删除两颗按钮；收益场景可用"直接去 Finder 拖原文件"替代。
- **写回先保持同步，不引入异步状态机。** 图片写回确实阻塞主线程，但拆掉运行时编码（原始字节直接 `setData`，不做 `NSImage → TIFF` 转换）后是 memcpy 量级。本插件有整套 `NOTCHCENTER_CLIPBOARD_*` 诊断探针传统（`diagnosticRowCap` / `DiagnosticMode`），先量出实际耗时再决定要不要为它加 pending 态——没数据的复杂度不写。

**D8 — 隐私立场不变，但 README 要把话说满。** 图片与文件路径照旧明文躺在 `PluginData/com.notchcenter.clipboard/`，不加密、不上传、不申请系统权限。加密方案被否不是因为工作量，是**威胁模型不成立**：宿主进程本身必须能解密，本地能读该目录的攻击者通常也能读 Keychain，换来的是一整套密钥迁移与失效处理。但截图比文本敏感得多（可能含密码、私聊、客户数据），所以 README 必须明确写出：截图会明文落盘、落盘位置、如何暂停记录与一键清空。

**D9 — UI：抽屉块混合行高 + 库页筛选栏改图标-only chip。**

- 抽屉块：**文本行与文件行维持 30pt，只有图片行 44pt，行内放 32×20 缩略图**（`.aspectRatio(contentMode: .fill)` + 圆角裁切——32×20 是 1.6:1，截图是 16:10 或 16:9，竖图 / 方图必须裁切，否则变形或留白）。多花 14pt 换"图片能一眼认出来"；抽屉块的存在意义就是"认出是哪一条然后取走"，认不出的图片等于不存在。30pt 是实测的既有内容高度（库页原本的固定行高也是它），不是新引入的数字。
- 行高与缩略图尺寸收敛到 `ClipboardRowMetrics`（两处列表共用），**不进** `ClipboardLibraryMetricsProbe`：后者那一族是库页纵向骨架、被打包期探针逐条镜像，而行高不进探针（列表在块内自管滚动）。混在一起会把"改行高也要动探针"这个假约束传下去。
- 缩略图单档生成：长边 **256px** 的 PNG，只服务**列表**（抽屉行 32×20、库页置顶看板卡、库页最近列表行），靠显示侧 `.fill` 裁切适配不同尺寸。两档会让落盘与失效逻辑翻倍，换不来可见收益。落盘用 `CGImageSource` 的降采样接口，不解全图。**（本项已被 [2026-09-20-clipboard-hover-preview](2026-09-20-clipboard-hover-preview.md) 改为 512px 并让预览也共用它，见 Changelog。）**
- **长按预览读原图，不用缩略图。** **（本项已被同一决策取代——改为预览也读缩略图，见 Changelog。）** 这是实现期回头修的一处：预览卡尺寸 256–276pt，用长边 256px 的缩略图放大到那个尺寸会糊——"预览"就成了看着像预览、实际看不清。整图解码只发生在用户长按的那一次，不在逐行渲染路径上，所以与"列表不许解原图"那条不冲突。相应地视图收敛成一个 `ClipboardImageView`（`source: .thumbnail | .original` 决定读哪个文件与 `fill`/`fit`），缓存分两个实例：缩略图按条目上限给容量，原图只留当前看的一两张（50 张原图全驻留是几百 MB）。
- 库页筛选栏：`collectable` 由 3 种扩到 5 种后**会溢出**。库页 `minSize` 宽 300、`padding` 12×2 → 内容宽 **276pt**；单个 chip ≈ icon 12 + 间距 4 + 文字 20 + 内边距 16 = **52pt**，5 个加 4 个 6pt 间距 = **284pt**，溢出 8pt（英文文案更长）。改为**图标-only chip**，并用 `ViewThatFits` 在两种排布里挑最富的一种：**够宽时选中项展开成"图标 + 文字"**（回答"我到底筛了哪几个"，不靠悬停猜），不够宽时全部退回图标。不做横向滚动——宿主把抽屉的横向滑动用作切页手势，被筛选行消费掉会打架。

**D10 — 持久化键不换，兼容继承既有契约。** 新字段（`fileURLs` / `contentHash` / `storedFilename` / `byteSize` / `mediaUTI`）一律走 `decodeIfPresent` + 默认值，**沿用 `history.entries.v1`**。这是继承 `ClipboardEntry` 里那条已被写成硬约束的契约（"不要改成非可选且无默认值的形式，也不要依赖编码器补键"），换 v2 键要写迁移代码而收益为零。降级到旧版也是安全的：旧版的 `ClipboardEntryKind` 里已有 `image` / `file` 两个 case，Codable 能解出来，旧版会显示这些条目、只是筛选栏筛不到。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A1. 只收图片 + 文件 | 预留位本就是为它留的；剪贴板最高频的非文本就这两类 | 富文本用户仍需手动转纯文本 | **采用**（D1） |
| A2. 图片 + 文件 + 富文本（RTF / HTML） | "复制网页段落"能保格式 | 写回保真度不可控——收进来贴不出原样，造预期落差 | **否决**：坑在写回不在采集 |
| A3. 泛化收任意 `UTType` | 未来无需再开期 | 类型空间无界，筛选栏 / 缩略图 / 搜索三套体系同时重设计 | **否决**：长尾类型的收益远低于成本 |
| A4. 只做图片，文件另开一期 | 单期最小 | `file` 与 `image` 的落盘 / 去重 / GC 机制同源，拆开等于做两遍 | **否决**：无独立性 |
| B1. 聚合为一条（一次复制 = 一条） | 保住批量粘贴契约；一次复制只占 1 个置顶位 | 删除 / 置顶 / 预览只能整组操作，粒度粗 | **采用**（D2） |
| B2. 拆成 N 条 | 每个文件可单独搜 / 单独置顶 | 一次复制炸成 N 行、**一次就能吃满置顶 5 条**；批量粘贴能力直接丢失 | **否决**：破坏 `copyBack` 契约 |
| C1. 两段式（changeCount 轻探测 → 命中才读重数据） | 空闲成本与现状同级 | 多一次分支判断 | **采用**（D3） |
| C2. 每拍直接读全量类型数据 | 实现最短 | 常年每秒拷贝数 MB，D1 的准入条件都不满足 | **否决**：不成立 |
| C3. 归类以图像数据优先于 fileURL | 截图 / 网页图判定更直接 | Finder 复制图片会被错判成"图片条目"，丢掉文件名 | **否决**：与用户意图相反 |
| D1. `text` 保持非可选、改当搜索代理 | 零解码迁移、零视图波及 | 图片条目搜不到（诚实，但要知道） | **采用**（D4） |
| D2. `text` 改可选 | 语义更干净 | 波及每处视图调用与 `history.entries.v1` 必填键契约 | **否决**：收益为零、面很大 |
| D3. 图片生成描述串当 `text` | 搜索能按"图片"命中 | 假阳性；把 L10n 拖进纯数据层 | **否决**：见 D4 |
| E1. 原字节落盘 + 缩略图单独缓存 | 保真、写回便宜、渲染不卡 | 目录里多一类文件，要 GC | **采用**（D5） |
| E2. 图片数据塞进 `history.entries.v1` | 单文件、无需 GC | 每次 persist 重写数 MB、每次启动全量解码 | **否决**：见 Context 第五条 |
| E3. 统一重编码（PNG / HEIC 收敛格式） | 格式单一、写回实现简单 | 有损毁契约；PNG 化对 JPEG / TIFF 来源会膨胀 | **否决**：与 `copyBack` 契约冲突 |
| E4. 行渲染时现解码原图 | 无落盘缩略图、无缓存失效问题 | 一次物化十来行 × 数 MB PNG 解码，抽屉卡死 | **否决**：性能不成立 |
| F1. 条数 + 总字节双上限（200MB / 单条 16MB） | 磁盘占用有硬上界，与既有淘汰语义同源 | 新增一条不变量，与置顶的交互要显式定规则 | **采用**（D6） |
| F2. 只加单条拒收阈值，其余照旧 | 改动最小，`sanitized` 一行不动 | 磁盘不可控——最坏仍是 800MB | **否决**：没解决问题 |
| F3. 后台巡检清孤儿（替代删除路径挂钩） | 兜底最稳 | 巡检治不了"预算本身没定义" | **否决为主、并入 D6**：巡检只作启动对账 |
| G1. 多文件走多 pasteboard item + 图片只写图像数据 | 写回正确；跨 App 行为一致 | 往 Finder 贴图片无反应（需 README 声明） | **采用**（D7） |
| G2. 图片附带 fileURL 指向插件数据目录 | 全场景通吃、零额外落盘 | 微信 / 飞书可能改判成"发文件"，同一剪贴板行为不一致 | **否决**：语义稳定性优先 |
| G3. 显式「复制为文件」动作 | 想要文件时显式要 | 新交互路径 + 新 i18n 键，行尾已有两颗按钮 | **另立**：留作后续可选增量 |
| G4. 校验失效时自动删条目 | 历史自洁 | 静默删用户数据；文件可能只是临时移走 | **否决** |
| G5. 写回异步 + pending 态 | 大图不卡主线程 | 无实测数据支撑的新状态机 | **另立**：先量测（D7 末条） |
| H1. 明文落盘 + README 声明 | 与既有契约一致，跨重启可用 | 截图明文躺在 `PluginData/` | **采用**（D8） |
| H2. 图片只留内存、重启即失 | 隐私最好 | 直接废掉剪贴板历史的核心价值 | **否决** |
| H3. 落盘 + 加密（Keychain 管密钥） | 静态数据受保护 | 威胁模型不成立；换来密钥迁移 / 失效处理 | **否决**：见 D8 |
| I1. 抽屉块混合行高 + 库页图标-only chip | 图片可辨认；5 个 chip 在 276pt 内不溢出 | 密度降；chip 发现性靠选中态补偿 | **采用**（D9） |
| I2. 统一行高（文本行也拉到 44） | 视觉更整齐 | 密度掉到约 4 条，为少数类型付全体代价 | **否决** |
| I3. 图片行只显示图标 + 文件名 | 密度零损失 | 认不出是哪张图，等于功能在但没用 | **否决** |
| I4. 筛选栏加"更多"下拉 / 横向滚动 / 提 `minSize` 到 360 | 保留文字 chip | 分别引入隐式规则、与宿主横向切页冲突、为一行筛选栏动块尺寸 | **否决** |
| J1. 沿用 `history.entries.v1`，新字段 `decodeIfPresent` | 零迁移代码；继承既有硬约束契约；旧版降级安全 | 键名语义与内容轻微不符（键名不含"媒体"） | **采用**（D10） |
| J2. 换 `history.entries.v2` + 写迁移 | 键名语义干净 | 要写迁移与回滚处理，收益为零 | **否决** |

## Consequences(影响)

- **改动落点**：`ClipboardHistoryLogic.swift`（载荷模型 `ClipboardCapture`、五类 `collectable`、按类型分支的 `matchKey`、媒体预算 `admitsMedia`/`applyingMediaBudget`、`recording` 拆成"载荷入口 + 已构造条目入口"两段以备 store 回填落盘名）、`ClipboardMediaStore.swift`（**新增**：`Media/` 目录的原子写、缩略图降采样、删除、孤儿对账、SHA256 内容哈希）、`ClipboardHistoryStore.swift`（`ClipboardReading` 协议换成 `probe`/`readPayload`/`writeText`/`writeFiles`/`writeImage`、两段式采集与门票、落盘先于入库、`commit` 单一变更出口、启动对账、`copyFailedID`）、`ClipboardHistoryViews.swift`（`ClipboardRowMetrics`、`ClipboardEntryPresentation`、`ClipboardThumbnailView` + 缓存、混合行高、失效态、按类型区分的 a11y 标签）、`ClipboardLibraryViews.swift`（`ViewThatFits` 筛选 chip、看板卡与列表行缩略图、`rowHeight` 外移）、`Plugin.plist`（`Version` 1.0.0 → 1.1.0，描述改为含图片与文件）、双语 `Localizable.strings`（新增 `drawer.copy.failed` / `drawer.row.a11y.files` / `drawer.file.multiple`）、`README.md`（四节重写，含"往 Finder 贴图片无反应是既定行为"）。**不新增**"是否记录媒体"的实例开关。
- **布局探针必须同步**：`ClipboardLibraryMetricsProbe` 是"视图与打包期探针的唯一真源"，`clipboardLibraryLayoutProbes` 按它推导区带、并受打包期 `BlockSizeVerifier` 的**互不重叠**判定约束。改任何视觉常量（筛选行高、chip 尺寸、看板卡尺寸）必须同步该函数；悬浮角标按既有约定**不单列探针**、只用 `minSize` 做边界核对。
- **回归面**：置顶 / 解顶跨分区（[2026-09-12-clipboard-lazy-list](../implemented/2026-09-12-clipboard-lazy-list.md) 的扁平单 `ForEach` 结构假设已从"等高"变为"可变高"）、搜索过滤、清空未置顶、`displayCount` 档位、实例删除清理、`history.entries.v1` 旧数据解码、`transient` 启发式对富媒体的生效情况（`concealed` / `transient` 标记同样出现在媒体类型上）。
- **新引入的不确定性（未验证，需真机核对）**：混合行高下 `LazyVStack` 的 offset 估算——置顶 / 删除会让条目跨分区移动、内容整体位移，滚动位置可能轻微跳动。原稿写的"`Experiments/ClipboardListProbe/` 新增混合行高用例"口径不对：那份台账断言的是"行身份与渲染值逐字段一致"，而混合行高两者都不改，**那个探针量不到这个风险**。真要量得靠真机滚动手感，或另做一个记录滚动 offset 漂移的观测。**本轮未做。**
- **性能待量测**：大图写回（16MB 级）在主线程的实际阻塞耗时；含图片条目的抽屉块展开耗时是否因缩略图解码而回退——两者都沿用 `NOTCHCENTER_CLIPBOARD_*` 探针口径复量，量测结论决定 G5 是否要做。
- **测试**：`ClipboardHistoryTests` / `ClipboardLibraryTests` 的假剪贴板（`ClipboardReading` 的测试实现）需扩展出富媒体快照；新增用例覆盖内容哈希去重、字节预算淘汰序、置顶占满时的"停收"行为、多文件写回的 item 结构、失效路径不写回。
- **文档**：`README.md` 需重写"记录规则"、"设置"、"隐私说明"、"注意"四节（当前明确写着"v1 不记图片与文件"）；`Plugin.plist` 的 `Description` / `DescriptionLocales` 仍写"remembers recent plain-text copies"，需一并更新；`docs/agents/插件开发约定.md` 的"文件暂存区只持有路径引用"契约在本插件新增了第二条适用场景，考虑在那边补一句交叉引用。

## Changelog

- 2026-09-20: 初稿（proposed）。逐分支与用户确认：类型范围 A、聚合粒度 A、预算策略 A、隐私 A、写回表示 A、行高 A（改为混合行高）、筛选栏 A、图片 `text` 语义 A。
- 2026-09-20: 实现落地，同期修正四处表述、补一条实现期发现的机制（均在对应条目内标注）——D6 字节口径收窄为只计落盘类型；D7 图片表示改为"原始 UTI + 魔数别名"（原表述与同段的性能约束自相矛盾），并定死"文件条目要么整组写回要么不写"；D3 补两段式门票机制及其踩坑原因；D9 行高按实测改为 30pt、补缩略图单档 256px 与 `ViewThatFits` 降级行为。
- 2026-09-20: 复查"图片会不会预览"时发现长按预览在用缩略图放大（会糊），改为读原图；视图收敛为 `ClipboardImageView` + 双缓存实例。同期给测试补上"缩略图必须解得出来且长边等于上限、原图像素不被改写"的断言——原来的用例只查文件存在，正是会漏掉"解不了所以没预览"的那种查法。
- 2026-09-20: 上一条的修法被 [2026-09-20-clipboard-hover-preview](2026-09-20-clipboard-hover-preview.md) 取代：悬浮预览是高频路径，为它解原图不可接受，于是把缩略图长边提到 512px 让列表/长按/悬浮**共用同一份派生图**，原图退回"只在写回时读"。`ClipboardImageView` 的 `source: .thumbnail | .original` 随之简化为 `contentMode`，双缓存实例合回一个。
- 2026-09-20: **D3 的归类优先级被 [2026-09-20-clipboard-image-file-and-cache-echo](2026-09-20-clipboard-image-file-and-cache-echo.md) 反转**（单个图片文件改按图像记录；`~/Library/Caches/` 下的文件引用不再收）。D3 原本的理由"用户意图是那个文件而不是那张图"被用户实测否决。该记录另附复现证据（`Experiments/ClipboardPasteboardProbe/`）。
