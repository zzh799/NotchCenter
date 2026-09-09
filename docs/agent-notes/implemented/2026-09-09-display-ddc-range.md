# Agent Note:亮度插件 DDC 写入值区间映射

status: implemented
date: 2026-09-09
deciders: zeaven

## Context(背景与约束)

- 部分外接屏 DDC 全量程两端不可用:0 附近直接黑屏、顶端刺眼或触发屏内限流,用户希望把 UI 百分比 0...100 映射到更小的 DDC 写入区间(如 20...80),再下发给屏幕。
- 现有映射是全量程:`BrightnessController.ddcValue(percent:upperBound:)` 按 0...maxLuminance 线性换算,回读亦按全量程反算百分比,无自定义区间概念。
- 约束:两块(`brightness.sliders` 与 `brightness.single`)共用同一 `BrightnessController` 单例与同一 `BrightnessDisplayModel.percent`,区间必须是按屏全局属性,不可是按放置实例属性,否则同屏两实例对同一硬件值算出不同百分比;宿主与 Kit 零改动,存量配置无迁移(无区间即全量程,行为不变)。

## Decision(决策)

- 新增 `Plugins/DisplayPlugin/Sources/DDCLuminanceRange.swift`:值对象 `DDCLuminanceRange(min:max:)` 表用户设置的 DDC 原始值区间,纯逻辑 `DDCLuminanceRangeLogic` 管插件级持久化(单键 `ddc.ranges`,键为 String(displayID))与按屏最大量程的净化(`sanitize(min:max:maxLuminance:)` 钳 0...max 且 min<=max,非法量程回全量程)。
- `BrightnessController` 持有按屏自定义区间(`customRanges`,插件级 `StateStore` 经 `configure(store:)` 注入,`DisplayPlugin.attachServices` 调用):有效区间为无自定义时 0...maxLuminance,有自定义时净化后区间;映射新增下界重载 `ddcValue(percent:lowerBound:upperBound:)` 与 `percent(value:lowerBound:upperBound:)`,旧单界签名保留为 lower=0 的薄包装(存量单测不动);`probe` 回读按有效区间反算百分比,`requestWrite` 按有效区间正算 DDC 值;`setRange/clearRange` 改区间时按旧区间反推硬件原始值再按新区间重算百分比,滑杆视觉不跳变。
- 设置 UI 两处共用同一全局区间:`SingleDisplaySettingsView` 在选屏 Picker 下加绑定屏的最小/最大 Stepper 与恢复完整区间按钮,`brightness.sliders` 新增 `DisplaySlidersSettingsView` 按屏逐行给同套编辑器;两处编辑的都是全局区间(注释写明共享原因),`sliders` 无区间 UI 时亦自动尊重经 `single` 设好的区间。
- 字符串新增 `range.section/min/max/reset` 中英两套,键集一致;插件 README 补区间语义与边界。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 区间存按放置实例(`SingleDisplayInstanceConfig` 加 min/max) | 实现最少,不碰控制器存储 | 同屏两实例对同一硬件值算出不同百分比,共享 percent 自相矛盾;sliders 块无实例设置,够不着 | ❌ 否决 |
| B. 区间按屏全局(采用) | 同屏所见一致,两块自动对齐,存量无区间即全量程零迁移 | 控制器需注入插件级 store,设置 UI 编辑的是全局值(需注释说明) | ✅ 采用 |
| C. UI 百分比直接限幅(如只允许拖 20...80)而不重映射 | 最简 | 滑杆两头留死区,0% 仍下发 0(黑屏风险未除),与需求"映射到区间再下发"不符 | ❌ 否决 |
| D. 区间用百分比表达(如 20%...80% 全量程) | 与屏无关,换屏不用重设 | 用户要的是 DDC 原始值区间(跨屏 max 100/255 不可比),百分比套百分比语义绕 | ❌ 否决,存 DDC 原始值 |

## Consequences(影响)

- 新增 `DDCLuminanceRange.swift`,改动 `BrightnessController.swift`、`SingleBrightnessBlockView.swift`(设置视图)、`DisplayPlugin.swift`(sliders 设罝入口与 attach 注入)、中英 strings、README、`DisplayPluginTests.swift`(区间映射/净化/保持硬件连续/假后端收敛)。
- 已知边界:同物理屏以新 `CGDirectDisplayID` 重连时区间按 id 键控匹配不到,回全量程(与既有亮度缓存同边界,README 明示);min==max 的退化区间净化为全量程,不支持单点锁定。
- 真机验证:设 20...80 后 0% 下发 20、100% 下发 80,回读 50 按区间显示,改区间时滑杆不跳,重启后区间仍在,sliders 与 single 所见一致。

## Changelog

- v1.0.0:proposed(2026-09-09,区间按屏全局 + 上下界重载映射)。
