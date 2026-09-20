# Agent Note:提醒事项块 `reminders.list`：EventKit 对接 + 三态双轴断点复刻

status: implemented
date: 2026-09-20
deciders: zhouzihang

## Context(背景与约束)

需求：按参考截图复刻「提醒事项」组件到大组件抽屉，并对接 macOS 真实提醒事项数据（EventKit）。

参考截图是三张不同尺寸的玻璃卡：左卡竖长（约 206×328）为「生活」清单，头部「名称左 + 计数右」+ 三行；中卡横扁（约 368×290）同清单，顶部圆形清单徽章 + 三行 + 底部大计数；右卡近方最大（约 406×435）为「今天」智能清单，头部「大计数左 + 名称右 + 右上角标」+ 分隔线 + 三行。左/中是同一数据源的两种版式，右是另一数据源。

**这是仓库第一个真正消费 EventKit 数据的插件**。现有 `CalendarPlugin` 明确把「日程事件（EventKit）」列为不做，全库无任何 `EKReminder` / `fetchReminders` 调用。

已查证可直接复用的既有基建（本 note 不重复其"为什么"）：

- 权限：`SystemPermission.reminders` 已在 Kit 定义（TCC 面板 `Privacy_Reminders`、用途键 `NSRemindersFullAccessUsageDescription`、`requiresRelaunch == false`）；`Resources/Info.plist` 已带该用途字符串；`PermissionCenter` 已实现 `EKEventStore.requestFullAccessToReminders()` 请求路径。**宿主与 Kit 零改动**。
- 权限纪律：系统授权窗触发点唯一，装载期不得触碰会拉起授权窗的 API，缺权限唯一入口是宿主的「权限管理」弹窗——见 [`2026-09-11-permission-lazy-trigger`](../implemented/2026-09-11-permission-lazy-trigger.md) 与 [系统集成与多语言](../../agents/系统集成与多语言.md)。
- 降级态形态：`Plugins/CameraPlugin/Sources/CameraBlockViews.swift` 的 `CameraPermissionGateView`（符号 + 标题 + 说明 + 「打开设置」按钮，按钮只调 `presentPermissions`）+ `RoundedHoverButtonBody` 基体。
- 块内自带滚动：`CommandSchedulerPlugin` / `ClipboardHistoryPlugin` / `QuickButtonBoxPlugin` / `DisplayPlugin` 既有做法（列表超出块高时块内滚动，不撑破块）。
- 渲染契约：`BlockCard` 壳 + 宿主统一 chrome + `blockPopoverTrigger` 驱动点击/长按（裸 `TapGesture` 真机不回调，是红线）。

**硬约束与已知数据面缺口：**

- 官方抽屉块必须三档尺寸齐全 + 声明 `probes`；`BlockSizeVerifier` 做「越界」与「自重叠」双几何判定，**且只用 `minSize` 跑一次**。
- 抽屉强制深色（`NotchTokens.Surface.drawer` = `rgb(0.02,0.02,0.025) @0.98`）、UI 走 `NotchTokens`、不引入彩色主题（DESIGN.md §2.1/§2.2）。
- **EventKit 拿不到 Reminders.app 的清单图标**：`EKCalendar` 只有 `title` / `cgColor` / `source` / `type` / `allowsContentModifications`，无图标字段（Reminders.app 的自定义图标存在其自身容器内，不在 API 面上）。截图里那两个徽章图标无法逐像素还原。
- **EventKit 不暴露手动排序序号**，`EKReminder` 也无对应字段；清单内顺序只能自推或沿用返回序。
- **「旗标」也读不到**：旗标与「优先级」在 Reminders 里是两个独立字段，而 EventKit 只暴露后者（`EKReminder.priority`：0 = 无、1 = `!!!`、5 = `!!`、9 = `!`），旗标只能靠**私有** ReminderKit 读取。因此智能视图提供的是「优先级」，不是旗标——这一条是初稿写错、查证后纠正的，见 Changelog。
- `EKEventStoreChanged` 是粗粒度通知：*"Individual changes are not described"*，收到后只能整体重拉（[Apple: Updating with notifications](https://developer.apple.com/documentation/EventKit/updating-with-notifications)）。

明确不做（out of scope）：新建 / 编辑 / 删除提醒、带提醒时间的本地通知、紧凑块、快捷按钮、活动摘要、状态栏菜单项、翻页与多源聚合看板。

## Decision(决策)

### D1 块身份与尺寸

`Plugins/RemindersPlugin`，**单一块 id** `reminders.list`，`kind: .drawer`，`symbolName: "checklist"`，三档 `min 150×150` / `recommended 300×360` / `max 900×600`。

单一块 id 而非「清单块 + 智能视图块」两块：两者的数据源、渲染、探针、设置面完全同构，拆两块只会把同一套代码与文案复制两份。

### D2 一块一源，源可切（两个入口）

每个放置实例绑定**一个**数据源，取值域为「某个具体清单」或「某个智能视图」。智能视图取四个：今天、计划、优先级、全部。

- 实例设置界面（`NotchBlock.instanceSettingsView`，宿主齿轮触发）承载正式选择。
- 块内右上角悬浮角标（Kit `IconCircleButton`，`if isHovering` + `.transition(.opacity)` + `NotchTokens.Motion.hover`）承载快速切换，点击弹 `BlockPopover` 列出全部可选源（清单带颜色点）。
- 选中即写入 `context.placementStore`。**不做「点击循环切下一条」**：清单一多就是灾难。
- 未设置过源的实例默认落在「今天」——它是唯一在零配置下就有意义、且截图里出现过的视图。

### D3 版式：宽 × 高双轴断点，三态

按截图三张卡的实际长宽比（左 0.63 竖长、中 1.27 横扁、右 0.93 近方）划分，而非单轴大中小（左卡比中卡还高，按高度排序会错位）：

| 态 | 条件 | 版式 | 对应截图 |
|---|---|---|---|
| 窄态 | `w < 宽阈值` | 名称（左）+ 计数（右）同一行头部，其下纯行列表，行间无分隔线 | 左卡 |
| 宽态 | `w ≥ 宽阈值` 且 `h < 高阈值` | 顶部圆形徽章，其下纯行列表，底部大计数 + 名称，行间发丝线 | 中卡 |
| 大态 | `w ≥ 宽阈值` 且 `h ≥ 高阈值` | 头部大计数（左）+ 名称（右），其下带分隔线的行列表，右上角标 | 右卡 |

阈值取网格整数倍的圆整值（宽阈值 300 = 2 格，高阈值 360 = 3 格），使三态分别对上 `1×2` / `2×2` / `2×3` 三档常见跨度。

三态常量与探针推导**集中在单个 `RemindersMetrics` 纯函数枚举**（行高、内边距、徽章直径、字号、各态区带矩形），版式与探针同源推导——违反这条会让探针与实际布局脱钩。

### D4 行信息集：严格按截图

行 = 空心圆（未完成）+ 标题（单行截断）+ 尾部 `arrow.triangle.2.circlepath`（仅当 `hasRecurrenceRules` 为真）。宽态与大态行间一条 `NotchTokens.Hairline.divider`，窄态无分隔线。

到期日、优先级、备注、来源清单名、子任务数**一律不显示**——截图里就没有。代价明说：源选「今天」时（跨清单聚合）看不出某条属于哪个清单。

### D5 徽章与角标图形：真实清单颜色 + 语义符号

EventKit 拿不到清单图标，替代方案：

- 具体清单：圆底填 `EKCalendar.cgColor`（真实用户数据），符号恒为 `checklist`；`cgColor` 取不到时回退 `white.opacity(0.14)` 圆底。
- 智能视图：圆底 `white.opacity(0.14)`，符号按语义取 `calendar`（今天）/ `calendar.badge.clock`（计划）/ `exclamationmark.circle`（优先级）/ `tray.full`（全部）。

**这需要在 DESIGN.md §2.4 补一条彩色豁免**：清单元色属用户数据而非主题，比照「数据可视化语义色」处理——允许留在插件本地，但必须收敛到插件内单一调色板常量并注明豁免理由（同 `SystemMonitorPlugin` 的存量做法）。除该色外，插件内所有前景/背景仍走白色 alpha 阶梯。

### D6 顺序：不排序，用返回序

直接用 `fetchReminders` 的返回顺序，不自推排序键。理由是实践上返回序通常即 Reminders.app 的存储序（往往等于用户手动序），保真度最高；但这是经验观察、无文档承诺。

配套纪律：**`ForEach` 的 id 必须用 `calendarItemIdentifier`**，不得用数组下标——否则返回序在任何一次 fetch 间抖动都会让 SwiftUI 错位复用行。

收尾方式：真机冒烟时对照 Reminders.app 核对「生活」清单行序。一致即结案；不一致则另开 note 改为「到期日升序 → 优先级降序 → 创建时间升序」。

### D7 计数口径

| 源 | 计数与列表内容 |
|---|---|
| 具体清单 | 该清单全部未完成项 |
| 今天 | 到期日 ≤ 当日 24:00 的未完成项（**含逾期**，与 Reminders.app 语义一致） |
| 计划 | 所有设有到期日的未完成项 |
| 优先级 | 所有 `EKReminder.priority != 0` 的未完成项 |

已完成项一律不进列表、不计入计数。

### D8 权限：装载期零 TCC 触发

`attachServices` 里**不建** `EKEventStore`、不调 `fetchReminders`（该调用本身就是授权窗触发点）。块视图先只做只读的 `context.hostController.permissionStatus(of: .reminders)` 查询，授权态下才构造 store 并取数。

缺权限时的唯一入口是 `hostController.presentPermissions([.reminders])`，插件不代开系统设置。授权后订阅 `NSApplication.didBecomeActiveNotification` 与 `EKEventStoreChanged` 自动重取，用户不必重开抽屉。

### D9 写入与刷新：先落盘，再重拉，再退避

点击圆 → 立即 `save(_:commit:)` 写 EventKit。**不做延迟落盘**（抽屉温存、App 可能随时退出，延迟写入存在丢失窗口）。

刷新分两条入口：

1. `save` 成功即**本地触发一次重拉**——写入已完成是确定事实，不必等通知；这条路径决定勾选到消失的延迟上界。
2. `EKEventStoreChanged` 只作为**外部变更**入口（Reminders.app 改动、iCloud 同步），带约 0.3s 节流合并（通知粗粒度且不描述变更，只能整体重拉）。

重拉必须幂等：进行中再触发则置 pending 标记，本次完成后补跑一次。

**不引入乐观状态**：列表内容一律来自重拉结果，store 里不存「本地已删除」这类影子集合。写失败时条目自然仍在原位，只补一行错误提示。

### D10 撤销：条目移出时起算

条目从列表移除的那一刻开始 2.5s 底部渐隐撤销条（文案含被勾选的标题）。点击撤销 = 写回 `isCompleted = false` 并重拉。

起算点绑在「移出」而非「点击」：用户看到的「它走了」与「能撤销」同时发生，语义自洽；且撤销条与列表状态不会互相矛盾。被撤销条目回到列表的位置由返回序决定。

### D11 异常态

| 状态 | 块内表现 |
|---|---|
| 权限未请求 / 已拒绝 / 受限 | 复用 `CameraPermissionGateView` 形态：`checklist` 符号 + 标题 + 说明 + 「打开设置」按钮 → `presentPermissions([.reminders])` |
| 选定清单已被删除 | 「清单已移除」+ 切换角标可用。**不自动回退**到别的清单——静默换源会让人以为数据丢了 |
| 源为空（清单无未完成项 / 当天无到期项） | 居中空态：符号 + 一句文案 |

### D12 不做项

紧凑块、快捷按钮、活动摘要、状态栏菜单项、新建/编辑/删除提醒、本地通知。截图里没有，且都是扩大权限面与状态面的方向。

### D13 测试与门禁登记

- 单测**绝不触碰真实 `EKEventStore`**（会弹系统授权窗）：`RemindersStore` 依赖一个可注入的数据源协议，测试注入假实现（同 `PermissionStatusProviding` 的既有做法）。
- `RemindersMetricsTests`：三态断点判定 + 三态几何（各态区带矩形不重叠、在对应尺寸下不越界）+ `minSize` 下窄态可完整容纳头部与最小行数。
- `RemindersSourceLogicTests`：四种智能视图的谓词与计数口径、`cgColor` 回退、优先级口径、`dueDateComponents` 解析（纯函数，注入固定日期）。
- `RemindersStoreTests`：写失败路径、重拉幂等与 pending 补跑、撤销写回。
- 登记落点：`Tests/NotchCenterTests/BlockMinSizeVerificationTests.swift` 的 `officialBlocks`、`Tests/NotchCenterTests/LocalizationTests.swift` 的 `modules`。漏登记不会报错、只会静默少跑，必须显式加。
- `Plugin.plist` 双语 `DisplayNameLocales` / `DescriptionLocales`；en 与 zh-Hans 键集必须一致。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 一块多清单看板（卡内堆叠多个清单分组） | 一块看全，信息密度高 | 单块纵向内容量不可控；探针只能声明不可滚动区带；与「截图是三张独立玻璃卡」的原始形态不符 | 否 |
| 拆成 `reminders.list` + `reminders.smart` 两块 | 块目录里语义直白 | 数据源/渲染/探针/设置面完全同构，等于把同一套代码与文案复制两份 | 否 |
| 只做具体清单，不碰智能视图 | 实现面最窄（省掉聚合查询与到期日谓词） | 截图右卡复刻不了，用户「今天」诉求无处落地 | 否 |
| 延迟落盘（点击后延 1–2s 才写） | 撤销天然免费 | 抽屉温存 + App 随时退出 ⇒ 存在确定性数据丢失窗口 | 否 |
| 勾选即写入、不提供撤销 | 无定时器无额外 UI | 误触代价是去 Reminders.app 深处取消，体验差 | 否 |
| 勾选即写入 + 实例设置「显示已完成」（删除线留在原位） | 无常驻定时器，撤销路径永久有效 | 列表变长；块内要区分两组条目；与「严格按截图」的行样式冲突 | 否 |
| 单轴尺寸断点（大中小） | 断点只有一个变量，推导与单测最简 | 左卡（高 328）比中卡（高 290）还高，竖长的左卡落不进最小心态 | 否 |
| 尺寸 × 数据源联合驱动版式 | 最「像截图」 | 同一尺寸下版式随数据源跳变，拖拽缩放时观感不连续，「切源」看着像「换块」 | 否 |
| 单版式 + 行区滚动（不做三态） | 探针 2 段、任何整数跨都不崩、实现面最小 | 保真度掉一档，截图三卡的头/底安排复刻不到（用户明确选择复刻） | 否 |
| 徽章纯白 alpha，不读清单颜色 | 完全守 DESIGN.md「不引入彩色主题」 | 多个清单块并排时无法互相分辨——清单元色是 Reminders 里最强的识别锚点 | 否 |
| 实例设置里让用户手选 SF Symbol | 用户自填，绕开「图标读不到」 | 多一份设置面与符号合法性校验；即便自选也无法与 Reminders.app 里那个图标一致 | 否 |
| 行做成两行行高（标题 + 到期日/清单名） | 信息最全 | 行高 26 → 40，窄态 150 高只剩约 2 行可见，「一瞥即知」的初衷消失 | 否 |
| 到期日升序 → 优先级降序 → 创建时间升序 | 顺序确定、可单测、无到期项不占前排 | 可能与你 Reminders.app 里看到的手动序不一致，而手动序恰恰是保真度最高的一种 | 否（保留为 D6 的兜底） |
| 排序键做成实例设置 | 最灵活 | 多一份设置面 + 一组本地化文案 + 设置变更的刷新链路，且默认值还得逆向再选一次 | 否 |
| 乐观更新（点击即本地移出，异步写库，失败回滚） | 零延迟手感 | 需要一条回滚路径 + 按 `calendarItemIdentifier` 定位插回 + 错误文案；与「以重拉结果为准」的单一真相源冲突 | 否 |
| 全靠 `EKEventStoreChanged` 触发重拉 | 只有一条重拉路径，实现最干净 | 通知到达时机未定义（可能合并延迟），勾选到消失的延迟不可控 | 否 |
| 撤销条从点击即起算 2.5s | 时序简单，不等回调 | 若重拉偏慢，撤销条会在条目还看得见时就消失，状态自相矛盾 | 否 |
| 启动期 / 装载期预热 EventKit | 抽屉展开即有数据 | 未点任何按钮就拉起系统授权窗，违反既有权限红线 | 否 |
| 给 Kit 加「提醒事项数据」公共 API | 插件零 EventKit 依赖 | Kit 只加公共 API 是克制原则；宿主目前也只用到权限查询，加数据面 API 是为单个插件扩面 | 否 |
| 选定清单被删后自动回退到第一个可用清单 | 永不空转 | 静默换源，用户以为数据丢了 | 否 |

## Consequences(影响)

- 新增 `Plugins/RemindersPlugin/`（`Plugin.plist` / `README.md` / `Sources/` / `Resources/{en,zh-Hans}.lproj`）。`Project.swift` 与 `scripts/build.sh` 从 `Plugins/` 自动发现，不改任何清单；`knownExtraDependencies` 无需登记（EventKit 是系统框架，不是本地 SPM 产品）。
- **无 Kit 改动、无宿主改动**：权限查询与引导通道已存在；`Resources/Info.plist` 的 `NSRemindersFullAccessUsageDescription` 已存在，用途文案无需改。
- 新增两个测试登记点（见 D13）；新增 `RemindersMetricsTests` / `RemindersSourceLogicTests` / `RemindersStoreTests`。
- **DESIGN.md §2.4 需补一条彩色豁免**（清单元色属用户数据），并同步 `NotchTokens` 说明——这是本 note 唯一触达文档规范的点。
- 新增本地化键集，en / zh-Hans 键位必须一致。
- 已知取舍与风险（写进 README 与代码注释，不重复到别处）：
  - EventKit 返回序未文档化，D6 已定收尾方式。
  - **中态与大态的探针在打包期永不被校验**（`BlockSizeVerifier` 只用 `minSize` 跑一次，`minSize` 恒落在窄态）。这两态的几何只能靠 `RemindersMetricsTests` 兜，属于门禁盲区，必须在测试里显式覆盖三态。
  - 三态常量与探针必须同源推导，改一处即同步另一处。
  - `EKEventStoreChanged` 粗粒度、不描述变更，重拉成本低但需节流避免无谓重拉。

## Changelog

- v1: 初版。经逐条拷问在实现前确认：单一块 id + 源可切、立即落盘 + 短撤销条、三态双轴断点、行信息集严格按截图、清单元色 + 语义符号、不排序用返回序（冒烟实测兜底）、`save` 成功即重拉 + 通知管外部、撤销条从条目移出起算。三态中的中/大态探针属门禁盲区，已落为测试义务。
- v1.1（实现落地）：
  - **纠错：智能视图的「旗标」改为「优先级」。** 初稿把旗标与优先级混为一谈（写的是「priority 映射为旗标」）。查证确认二者在 Reminders 里是独立字段，且**旗标只有私有 ReminderKit 能读**，公开 EventKit 完全不暴露。改为「优先级」（`priority != 0`），语义诚实且全在公开 API 面内。涉及 D2 的智能视图清单、D5 的符号（`flag` → `exclamationmark.circle`）、D7 的计数口径。
  - **实现期修掉一个真 bug（由单测发现）**：`Calendar.date(from:)` 对缺失字段填默认值（年 1 / 月 1 / 日 1），于是**只给了时分的 `DateComponents` 也会"解析成功"**，产出一个纪元附近的假到期日——那会让没有到期日的提醒凭空出现在「今天」里。现在要求年月日齐全才解析。
  - 版式常量在实现期修正了一处算术错误：区带高度原写成 `内边距 + 内容高`，漏了上下两侧，会让探针矩形与实际渲染错位；改为 `内容高 + 2 × 内边距`。
  - 落地清单：`Plugins/RemindersPlugin/`（`Plugin.plist` / `README.md` / `Sources/` 9 个文件 / `Resources/{en,zh-Hans}.lproj`）；测试 `RemindersMetricsTests` / `RemindersLogicTests` / `RemindersInstanceModelTests`；登记点 `BlockMinSizeVerificationTests.officialBlocks` 与 `LocalizationTests.modules`；DESIGN.md §2.4 补「数据语义色的豁免」判定线。
  - 验证：全量 120 项测试通过；`verify-sizes` 通过（`RemindersPlugin` 探针进校验）；doc 门禁 9/9；UI token 扫描本插件零命中；bundle 元数据与双语资源经实检正确。
  - **仍待人工冒烟**：块在真机上添加一次、点「权限设置」授权、核对「生活」清单的行序是否与 Reminders.app 一致（D6 的收尾条件）。
