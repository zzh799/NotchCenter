# Agent Note: 剪贴板条目交互重构与确认浮窗化

status: implemented
date: 2026-09-06
deciders: 用户（四项拍板：长按浮窗预览全文 / 移除时间戳 / 宿主确认一并浮窗化 / 覆盖卡片确认层）

## Context(背景与约束)

部分推翻 2026-09-05 剪贴板共识 Q8/Q9（条目主体点击 = 展开 / 收起全文，「复制」按钮写回）：条目改为单行截断、点击即写回，展开态与复制按钮双热区随之取消。同时确认类 UI 整体弃用模态弹窗：confirmationDialog / NSAlert 是独立 key 窗口，鼠标移过去的瞬间宿主判定指针已离开而收回抽屉 / 条带，确认根本完不成（DESIGN.md §1 不抢焦点）。out of scope：记录 / 去重 / 暂停 / 持久化逻辑不动；状态栏菜单清空路径不动（不在抽屉内，无收回问题）；QuickAction `requiresConfirmation` 契约不变，只换确认形态。

## Decision(决策)

条目行：主体点击 = copyBack（单行 lineLimit(1)），长按 0.2s = BlockPopover 全文预览浮窗（280×200，内嵌滚动、可选中复制）；「置顶 / 删除」图标按钮横排同行放行尾；contextMenu 保留；✓ 高亮沿用 justCopiedID 链路。行交互挂 Kit `blockPopoverTrigger`（新增 cornerRadius 参数对齐行圆角 7）——单手势管线，规避 TapGesture + 长按真机失效红线。时间戳整体移除：行内不显示，`ClipboardInstanceConfig` 删 showTimestamps 字段（旧持久化多余键被 JSONDecoder 忽略，无迁移），设置视图删开关，time.relative.* 与 drawer.button.copy 字符串删除。确认浮窗化：Kit 新增 `InlineConfirmPanel`（面板本体）/ `InlineConfirmOverlay`（遮罩 + 面板），遮罩形态监听 `notchCenterDrawerDidCollapse` 自动取消（块视图收起后仍存活，不自动复位会留幽灵确认层）；三个调用点——剪贴板抽屉清空 = 覆盖卡片确认层，快捷按钮盒重动作 = 覆盖盒卡片确认层（确认态上提到卡级），快速区 `QuickActionStripCell` = BlockPopover(.below) 贴图标下方垂出（与齿轮设置浮窗同一管线）。实现落点：`Plugins/ClipboardHistoryPlugin/Sources/`（ClipboardHistoryViews.swift、ClipboardInstanceConfig.swift）、`Plugins/QuickButtonBoxPlugin/Sources/QuickButtonBoxViews.swift`、`Sources/NotchCenter/CompactPanelView.swift`、`Sources/NotchCenterKit/BlockCard.swift` 与 InlineConfirmOverlay.swift。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 保留 confirmationDialog 只改剪贴板 | 零改动 | 独立 key 窗口抢焦点，鼠标移过去抽屉收回，确认无法完成 | 否决，浮窗化 |
| 清空确认用锚定按钮的小气泡 | 列表仍可见 | 用户拍板覆盖卡片确认层（遮罩挡住内容，隐私上更稳） | 否决 |
| 全文查看用右键菜单「展开」项 | 实现最简 | 用户拍板长按浮窗预览（所见即所得，不占菜单） | 否决 |
| 行内 Button + onLongPressGesture 组合 | 写法直觉 | 与触发器红线同源：TapGesture 与长按并存真机不触发 | 否决，复用 blockPopoverTrigger |
| 确认态残留用 Store 可见性标志复位 | 显式可控 | 需给 Store 加发布字段；宿主已有 drawerDidCollapse 通知，浮层直接订阅即可 | 否决，通知复位 |
| 快速区确认用条带内横条 | 不引入新窗口 | 临时盖掉全部图标、面板布局手术大；BlockPopover .below 本就是紧凑图标准备管线 | 否决 |

## Consequences(影响)

Kit 公开 API 新增 InlineConfirmPanel / InlineConfirmOverlay，`blockPopoverTrigger` 增加 cornerRadius 参数（默认 10，既有调用零变化）；快速区 / 快捷按钮盒 / 剪贴板三处确认 UI 行为一致且不再抢焦点；时间戳设置为不可恢复移除（配置字段 + 字符串），README 交互与设置描述同步；`ClipboardHistoryTests` 补旧配置 JSON 解码兼容用例；LocalizationTests 键集校验继续生效。真机验证项：长按预览弹出与消失、确认层在抽屉收起后不留残影、快速区确认浮窗不引起条带收起。

## Changelog

- v1.0.0: 四项拍板定稿（2026-09-06）。
