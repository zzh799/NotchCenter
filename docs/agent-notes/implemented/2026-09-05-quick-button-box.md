# 快捷按钮盒 QuickButtonBox + 快捷动作 QuickAction

> 状态:已实现(2026-09-05)。文档 §4.11;API 变更见
> [HostController](../../api-changelog/HostController.md) 顶部条目与
> [插件开发指南](../../插件开发指南.md) §3。
> 关键字:插件 API 扩展 / 宿主注册表 / 容器块 / 跨窗口拖拽装填。

## 背景

紧凑区(快捷按钮区)带宽有限,用户希望把不同插件的一键入口收集到一个「盒子」里统一管理——不是把紧凑块搬走(原件保留在各自插件),而是收纳**可编程执行的快捷动作的副本/快捷方式**,双入口共享同一份动作状态。

## 决策

1. **QuickAction 抽象(Kit)**:想被收纳的插件自报动作(图标 + 名称 + toggle/action 类别 + 可选 `requiresConfirmation` + `execute` + 开关态 `isActive`)。`QuickAction` 是 `@MainActor ObservableObject` 类,插件缓存同一实例(identity 稳定);宿主只存引用,不持久化动作本身。
2. **协议纪律**:`quickActions` 挂在 `NotchCenterPlugin`、宿主读取挂在 `HostController`(`quickActions()` / `quickAction(id:)`)——都必须声明为协议**要求** + extension 默认实现,否则存在类型分发被静态遮蔽(settingsView 同族坑)。
3. **注册表生命周期**:宿主在插件 enable/attach 后注册、disable/uninstall 前注销(`PluginManager` + `NotchCenter/QuickActionStore.swift`);动作 ID 全局唯一、先到先得。盒引用已失效动作 → 置灰保留,由管理面板移除。
4. **宿主不硬编码盒块 ID**:拖拽落位经新协议 `NotchCenterQuickActionSink`(`acceptQuickAction(_:placementID:span:)`),由目标放置实例所属插件自判容量并持久化;非容器插件不遵守即默认拒绝,第三方可自建容器。
5. **跨窗拖拽路线**:设置窗口与抽屉(穿透 NSPanel)非同窗,盒内 `.onDrop` 不可行 → 复用 `BlockDragCoordinator` 会话(payload 携带 `actionID`,落点仍用 `.drawer` 格,虚线占位框恰好框住盒实例),提交按 payload 类型分派到 `performQuickActionDrop`;对盒所在布局无任何改动。
6. **v1 形态**:盒 = 普通抽屉块(`quickbuttonbox.grid`,.large/.extraLarge,默认 .extraLarge),块内纯图标宫格 + 悬停显名(系统 `.help`);无块内滚动/分页,容量按跨度保守估算(大 10 / 特大 16),装填放不下即拒绝(提示音)。每放置实例的动作集(有序 ID)存 `placementStore`(键 `quickActions`),多实例互不干扰。
7. **装填**:主路径 = 设置 → 组件页把动作拖到抽屉中的盒上(目录结构与合一规则见文末「修订 2026-09-05 晚」);辅路径 = 盒块齿轮面板(instanceSettingsView)移除/排序。盒自身不注册动作。
8. **现网适配**:Caffeinate(toggle)、Calibre/Dsh(服务 toggle + `requiresConfirmation`)、MediaControls(播放暂停/上下曲)、Pomodoro(开始/暂停/停止)、ClipboardHistory(清空未置顶 + confirm)、OpenCodeUsage(刷新)。Display/SystemMonitor 纯展示、Notes/Scratchpad 只有「展开抽屉」型入口——**不硬造动作**。

## Alternatives considered

- **直接引用其他插件的 compact 块(pluginID+blockID)渲染并模拟点击**:宿主无法编程执行另一插件块内部的 `.custom` 点击逻辑,expandDrawer 类按钮进盒语义不自洽 → 排除,改走 QuickAction 注册制。
- **盒做成紧凑条上的容器图标(点开弹宫格)**:需要给紧凑区引入弹层交互,几何/带宽/点击语义都要动,收纳价值与改动不成比例 → v1 排除,盒先做抽屉块。
- **盒内 onDrop 接设置目录行**:两窗口非同一 SwiftUI 层级且抽屉为穿透 NSPanel,`.onDrop` 无法稳定命中 → 复用既有 `BlockDragCoordinator` 自建拖拽会话。
- **容量策略做块内分页/滚动**:与抽屉水平切页手势冲突、复杂度高 → v1 用静态保守容量 + 装填拒绝;后续如需更多动作再引入分页(`scrollUsage` 声明同步)。
- **把 registry 注入 `BlockContext`**:需改其 init 与全部构造点,且注册表本质是宿主能力 → 走 `HostController` 协议要求(与活动摘要同族)。

## 风险与取舍

- 开关态同步依赖插件把 `isActive` 与自身 store 状态联动(订阅其 @Published);只对真实布尔开关建模(Caffeinate/服务启停),其余按一次性动作。
- 重动作(服务启停)在盒内点击先确认;来源插件被禁用后按钮置灰、面板可清理,不自动删除配置(避免误删用户编排)。

## 修订 2026-09-05 晚:目录合一(需求对齐)

冒烟反馈:用户在组件页拖「快捷按钮」(紧凑块卡片)到盒上不装填、反而快速区出现插入指示——盒只认顶部「快捷动作」区,而块卡被旧逻辑宽松塞进快速区;两套目录把同一入口拆成两份、语义错位。修正为「一张卡,拖哪都能用」,即**把块卡与同义动作合一**。

修订决策:

1. **`sourceBlockID`(Kit,向后兼容可选字段)**:动作标注「与本插件某块点击完全同义」的块 ID;宿主组件目录据此把块卡与动作合并为一张双身份卡。语义从严:只在动作点击 ≡ 块点击时标注,不标「代表操作」近似。现网仅 Caffeinate 标注(`caffeinate.toggle` 块与动作同 id 同义);Pomodoro compact 块是「空闲开始 / 运行停止」条件切换,与任一单动作不等价不标;Calibre/Dsh 服务卡点击非 toggle 不标。
2. **目录合一(宿主)**:组件页顶部独立「快捷动作」区取消;命中 `sourceBlockID` 的动作并入块卡(卡带 `square.grid.3x3` 角标,help 说明可入盒),未命中块的动作作为该插件分区内「盒用快捷动作」小网格单列(媒体上下曲、Pomodoro 起停、Clipboard 清空、OpenCode 刷新等),避免同入口两份。
3. **拖拽按落点分流(宿主)**:`Payload` 可同持块 + 动作双身份;dropZone 先判是否命中可收纳容器(盒)——命中且有动作身份 → 装填动作,命中但纯块卡 → 无效红叉(**不再宽松追加快速区**,消除「拖到盒却进快速区」的误导);未命中容器再按块身份走常规区域(快速区 / 抽屉摆格 / 紧凑块拖到抽屉空白仍宽松追加)。提交按「落点是否容器 + 是否有动作身份」分派,不再以单一动作身份标志分派。
4. **纯动作卡**:无块身份的独立动作卡只接受盒容器落点,拖到快速区 / 空白格一律无效。

实现载体:`ComponentCatalogMerger`(块↔动作合一纯逻辑,`Tests/ComponentCatalogMergeTests` 覆盖)、`ComponentCatalogItem.quickActionID`、`BlockDragCoordinator.Payload` 双身份 init、`BlockDropTargeting.zoneIsQuickActionContainer(_:)` + `sinkContainer(at:)`。

取舍:合一块卡(如 Caffeinate)拖到快速区 = 摆 compact 块(旧行为保留,块身份在);拖到盒 = 装动作;拖到抽屉空白仍宽松进快速区。块卡拖到盒上不再有任何「摆到快速区」副作用。

## 修订 2026-09-05 深夜:统一快捷按钮(需求对齐二轮)

冒烟反馈:目录合一仍不够——用户心智里「能放快速区的快捷按钮」与「盒里按钮」本就是**同一批东西**,应全部双可放,且显示样式完全统一;上一轮只合并了 Caffeinate 一张卡,其余动作仍只能进盒、样式也两套。方向修正为**彻底统一**。

修订决策:

1. **官方一键入口全部动作化**:5 个官方紧凑块(Caffeinate `caffeinate.toggle`、Pomodoro `pomodoro.toggle`、Notes `notes.compact`、Scratchpad `scratchpad.compact`、Clipboard `clipboard.tray`)取消自带视图的紧凑块注册,转为 `quickActions`;动作 id **沿用旧块 id**(旧布局槽位零迁移,宿主槽位解析「先块、缺块回退同名动作」)。点击语义忠实复刻:开关/智能启停(空闲开始/运行停止)、新建笔记+展开+聚焦、清空暂存(确认)、展开剪贴板抽屉。
2. **宿主标准统一渲染**:Kit 新增 `QuickActionTile`(圆角方块+SF Symbol,三层状态:开关点亮 / 静态 / 失效置灰);快速区动作槽位(新 `QuickActionStripCell`,执行+重动作确认)与快捷按钮盒格、目录卡片共用同一基元——同一按钮在任何落位长相一致。
3. **目录与拖拽**:每插件分区内动作卡统一为「快捷按钮」卡(图标磁贴+名称+去向),单击 = 加入快速区末尾,按住拖 = 快速区插入 / 盒装填(落点按「容器盒 / 快速区 / 其余无效」分流,`Payload` 纯动作卡带来源 pluginID)。官方不再产出块卡,目录无重复入口。
4. **默认布局**:`QuickAction.defaultInStrip` 标记前身默认进带的动作,宿主首启种子(seedDefaultLayout)据此把它们补进快速区,保持「首次启动刘海带即有常用按钮」。
5. **第三方兼容**:Kit 仍支持插件注册自带视图的紧凑块(按块渲染、目录以块卡展示);`sourceBlockID` 合一机制保留给第三方「块卡+动作」用例,官方不再使用。

取舍:旧紧凑块的状态性小视觉(剪贴板暂停变灰、番茄钟阶段色底衬、暂存角标)收敛为统一的「开关点亮 / 置灰」语义;剪贴板暂停状态仍可见于状态栏菜单。第三方的自带紧凑块不受影响。

实现载体:`QuickAction.defaultInStrip`(Kit)、`QuickActionTile`(Kit)、`LayoutEngine.insertQuickActionSlot(_:_:atScreenPosition:)` / `addQuickActionSlot(_:_:)`、`buildCompactElements` 块→动作回退、`BlockDropTargeting`(dropZone 纯动作卡可入快速区、`performBlockDrop` 动作槽位分支、`addQuickAction`)、`QuickActionStripCell`、设置页 `QuickActionCard`(pluginID+onAdd+磁贴);官方插件 5 家去紧凑块、补/改动作并同步双语资源;测试新增 `LayoutEngineTests` 快捷动作槽位用例 2 项(全部 511 项通过)。
