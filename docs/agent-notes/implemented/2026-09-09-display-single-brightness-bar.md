# Agent Note: 亮度单屏条块 brightness.single

status: implemented
date: 2026-09-09
deciders: 用户(4 项拍板:默认跟随第一台屏 / 1x1 做启动器 / 块上 B 风格只留图标 / 横条按住即调轻扫即切页;追加确认:松手后浮窗关闭 / 浮窗内带百分比;2026-09-09 晚:撤回面积规则与最小格禁 1x1)

## Context(背景与约束)

现有 `brightness.sliders` 是多屏列表块(每屏一行滑杆,见 2026-09-07-display-brightness-1x1),放不进 75x60 小格下的单屏竖条/横条心智。需求:新增单屏组件,在格子 75x60 下可设 1x2 与 2x1,整块当进度条、高亮填充表达百分比,参考 iOS 控制中心亮度条。1x1 做点击/长按启动器,弹浮窗调光且支持不放开连续拖,松手即关。out of scope:DDC 枚举/写入链路不动,老 sliders 块不动,宿主与 Kit 零改动,存量布局不迁移。

## Decision(决策)

- UI 双套(单元口径,见下):当前格子单元 `cellW = frame.width / 列数`,`cellH = frame.height / 行数`(view 本地由 layoutInfo 推导,不读宿主单例),`cellW > 100 或 cellH > 100` 走大 UI(本轮截图),否则走小 UI(整块 fill)。75x60 格下 1x2/2x1 落小 UI,符合首轮需求;默认 150x120 格下走大 UI。

- 新增块 `brightness.single`(drawer,与 sliders 同插件共存):一实例绑定一台屏,`placementStore` 存 `displayID`,默认跟随 `orderedIDs.first`,经 `instanceSettingsView` 提供选屏 Picker;存的屏消失时跟随第一台显示,不改写存储;无屏时复用现有 emptyState。
- 尺寸:三档 `min 75x60 / max 300x240 / recommended 150x240`(竖长,默认拖出即竖条),常规矩形盒语义,不另加约束(面积规则已按用户要求撤回,见 Changelog v3)。
- 小 UI(B 风格,块上只留图标):`列<行` 走竖条(fill 自底按 percent 铺满),`列>=行` 走横条(fill 自左铺满);track `white.opacity(0.15)`,fill 白系半透明以上,圆角与卡片同半径边缘顶满;图标 `sun.max` 居中压盖加阴影保证两区可读;整块 `DragGesture` scrub(竖条 y 反转,横条 x),`isDragging` 语义与终值补写复用 `requestWrite` 同一通道;`probing` 态静态占位,不做假动画。
- 大 UI(截图风格,单元任一轴 >100 时):标题行左对齐显示屏名(右侧按 B 决策配百分比数字),下方药丸滑杆整宽铺满:左端太阳图标,已填充段亮色,未填充段深色,圆形 thumb 落在填充末端;横条块(列>=行)用横向滑杆,竖条块(列<行)用纵向等价(标题置顶 + 竖向药丸);拖 thumb、点轨道跳转、沿轨道拖拽都走同一 `requestWrite` 通道,复用 `BrightnessSliderControl` 的写入/占位/无动画语义,仅换大尺寸样式与 thumb 渲染。
- 1x1 启动器:点击(<0.2s 且 <10pt)或长按(满 0.2s)都经 `BlockPopover` 同心覆盖弹浮窗,浮窗内容即大 UI(标题 + 药丸滑杆 + 百分比,卡片改为横向、如 250x130,贴近截图比例);长按不放开继续拖直接调光(读全局鼠标位移);松手即关(用户拍板 A);提前拖走视为翻页/滚动意图不弹;编辑态与预览副本禁用触发器。
- 探针:单个 `single.content` 内容探针 = frame 内缩 6pt(大小 UI 的关键区都落在此盒内),frame-only,满足官方 drawer 必声明门禁;实现落点:插件新增 `SingleBrightnessBlockView` + `SingleDisplayInstanceConfig`,复用 `BrightnessController`,宿主与 Kit 零改动。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 物理面积规则 minArea(曾采纳后撤回) | 小格禁 1x1、大格放行一次写清 | 用户不要最小格禁 1x1,连带整套 Kit 扩展一并撤回,回到零架构改动 | 撤回(v3) |
| 1x1 点击切换开关式动作 | 少一次弹窗 | 亮度无开关语义,误触代价高 | 否决,点击即弹浮窗 |
| 按块 frame 任一轴 >100 切大 UI | view 本地最简 | 75x60 格下 1x2/2x1 全落大 UI,小 UI 永不可达,与首轮需求矛盾 | 否决,改按单元口径 |
| 松手后浮窗保持打开 | 便于微调 | 多一步关闭,与用户手感预期相悖 | 否决(用户拍板松手即关) |
| fill 用强调色(A 贴图高还原) | 对比度实现简单 | 与参考图白系观感有色差 | 否决首版,按 B 白系只留图标 |

## Consequences(影响)

- 宿主与 Kit 零改动;测试补形态映射(启动器 / 小 fill / 大药丸切档)、单元反推与实例绑定回退。
- 新老块共存,目录多一项,无 layout.json 迁移;存量超盒/过小跨度照显,下次拖拽即夹。
- 打包 `verify-sizes` 以 min 作盒,满铺 fill 天然通过;真机验证:小格竖拖/横拖、1x1 点按弹窗与按住连拖、插拔回退、占位无跳变、明暗 fill 可读性。

## Changelog

- v3:撤回面积规则与最小格禁 1x1(用户要求):`minArea`、Kit/手势/元素透传与相关单测全部回退,1x1 全格尺寸做启动器(2026-09-09)。
- v2:增 UI 双套(单元 >100 走截图大 UI,浮窗内容同步换大 UI 横向卡片)(2026-09-09)。
- v1:proposed(2026-09-09,方案确认版)。
