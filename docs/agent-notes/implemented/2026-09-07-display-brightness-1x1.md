# Agent Note: 显示器亮度滑杆支持 1×1 紧凑尺寸

status: implemented
date: 2026-09-07
deciders: 用户（两项拍板：多屏 1×1 全屏紧凑列出 / 大尺寸版式保持不动）

## Context(背景与约束)

亮度滑杆块原先只支持 2×1(medium)/2×2(large)/4×2(extraLarge)，版式为「每台屏一行横向 屏名 + 滑杆」（ScrollView 贴顶）；1×1（默认 150×120）宽度放不下名称与滑杆并排，需要上下两行（文本一行 + 进度条一行、整组垂直居中）。多屏怎么呈现、大尺寸行摆法是否联动改动是仅有的两个开放点，用户拍板：1×1 仍全屏紧凑列出（默认高度约两屏，放不下块内滚动）、medium 及以上行摆法保持历史横向行；随后追加要求：其他尺寸内容同样「随条目适应」——条目少时整组垂直居中、条目多超高时块内滚动。out of scope：DDC 枚举/写入链路、每实例设置、空态文案均不动。

## Decision(决策)

- `DisplayPlugin` 的 `brightness.sliders` 声明 `supportedSizes` 增补 `.small`，defaultSize 维持 `.medium`（存量布局与目录默认渲染不变，无需迁移）。
- 版式按块跨度判定（`BrightnessSliderArrangement.forSpan`，纯逻辑可测）：1×1 → compact 两行式，其余 → rows 历史式。宿主抽屉上下文只填 widthColumns/heightRows（size 恒 nil），故判定走 span；目录预览等无 span 上下文回退 `size == .small`。
- 两形态共用同一「随条目适应」容器 `adaptiveStack`（`ViewThatFits(in: .vertical)` 二选一）：条目总高 ≤ 块高时第一候选命中（整组垂直居中，单屏即居中一块），超高时 ScrollView 兜底（块内滚动），免手工预算行高与边界抖动。1×1 每台屏一个 `CompactBrightnessRowView`（屏名一行居中 + 滑杆一行）、屏间间距 8；其余尺寸沿用 `BrightnessRowView` 横向行、屏间间距 12——只有行的摆法不同，容器行为一致。
- 滑杆本体与其回读占位槽抽成 `BrightnessSliderControl`，compact/rows 两形态共用同一份交互（拖动→DDC 写入、回读占位、事务动画清零等语义不重复、不漂移）。实现落点：`Plugins/DisplayPlugin/Sources/DisplayPlugin.swift`、`Plugins/DisplayPlugin/Sources/DisplaySlidersBlockView.swift`、`Tests/NotchCenterTests/DisplayPluginTests.swift`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 手工预算行高决定居中或滚动 | 直白 | 行高依赖字体排版，预算误差会造成裁切或抖动 | 否决，ViewThatFits 按竖直适配自动二选一 |
| 1×1 只显示主显示器 | 单屏界面最简 | 其余屏不可调，违背多屏可见性一致 | 否决（用户拍板全屏列出） |
| 所有尺寸统一改两行式 | 风格一致 | 改动画面积大，现有大尺寸观感被破坏 | 否决（用户拍板大尺寸不动） |
| rows/compact 各写一份滑杆代码 | 改动局部 | 交互/样式双份维护，回读占位与动画规避易漂移 | 否决，抽 BrightnessSliderControl 共用 |

## Consequences(影响)

亮度块新增 1×1 档位，抽屉里可缩到一格；两形态条目少时内容垂直居中、条目多超高时块内滚动（其他尺寸由「贴顶滚动」改为「随条目适应」居中，仅容器语义变化，行摆法不变）。既有用户布局（layout.json 存的是 spans，不含 small）不受影响；`LocalizationTests` 键集校验继续生效（未新增/删除字符串）。真机验证项：1×1 拖动滑杆手感、probing→ready 占位槽到滑杆无动画跳变、多屏滚动与居中切换、目录预览形态与 defaultSize 一致。

## Changelog

- v1.1.0: 其他尺寸容器统一「随条目适应」垂直居中（2026-09-07）。
- v1.0.0: 尺寸增补与版式拍板定稿（2026-09-07）。

## 修订(2026-09-07,像素三档模型)

本记录中 "supportedSizes 增补 .small" / "defaultSize" 措辞属于已废弃的离散档位模型。同日决策见 `2026-09-07-block-size-pixel-three-tier`：`brightness.sliders` 现声明物理像素三档 `150×120 / 600×240 / 300×120`（= 旧跨度 × 默认格 150/120），1×1 紧凑形态语义不变（默认格下 150×120 = 1×1）。历史文字保留不改。
