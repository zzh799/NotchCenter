# Agent Note: 打包期最小尺寸遮挡校验(像素三档的收尾件)

status: implemented
date: 2026-09-07
deciders: 用户对齐方向 + 本会话实现
replaces: (无,承接 HANDOFF §6 Task A)
superseded-by: <无>

## Context(背景与约束)

像素三档模型已落地(见 HANDOFF:Kit API / 引擎 / 12 官方插件 / 546 测试全绿),原始需求的最后一句尚未实现:"插件打包时,校验插件组件在最小尺寸下是否会发生遮挡"。

要校验的失败类别(在 minSize 物理像素下):
1. **越界溢出**——块内容伸出自身内容区。BlockCard 不裁切,伸出的内容会画到邻居块上,是块间遮挡的真源;
2. **块内自叠**——块内两个关键 UI 元素互相覆盖(布局挤不下);
3. **内容坍缩/被裁**——关键元素在 minSize 下被裁断(如 fixed 高度文字)。

约束:
- 只对**官方内置插件**(`Plugins/`,源码在本仓)跑;第三方打包无声明即跳过;
- 门禁必须**确定性、零渲染依赖**——本仓测试在并行负载下已有超时脆性先例,渲染实测(NSHostingView + 读 a11y 树)在无窗口测试进程中不可靠;
- 官方插件全员采纳,与上一阶段"12 插件全迁移"的完成标准一致。

## Decision(决策)

**声明式几何探针 + 纯几何校验,接入测试门禁。**

1. **Kit API**(`NotchCenterKit`):
   - `BlockProbe { id, rect }`——rect 为块本地坐标(原点=内容区左上)的"关键 UI 区必需可见矩形"。
   - `NotchBlock.probes: (@MainActor (BlockLayoutInfo) -> [BlockProbe])?`——可选回调,按给定布局(校验时 frame.size = minSize 物理像素)返回探针。compact 块与第三方未声明即跳过。
2. **校验器**(Kit,纯函数):`BlockSizeVerifier.violations(probes:contentSize:)`,两类:
   - 探针 rect 越出内容盒(容差 0.5pt)→ `probeOutsideContent`;
   - 两探针 rect 相交(交集宽高均 > 容差)→ `probesOverlap`;
   - (第 3 类"内容被裁"的几何可判部分并入前两类:**作者须用与视图同一套布局常量推导探针**,min 布局放不下/放不下就交叠时,声明 rect 必然越界或自叠,几何校验必然拦截;字形级截断(矩形内文字少显示几像素)不属于遮挡,超出几何校验范围,作者选 minSize 时自担——见 Consequences)。
3. **官方插件采纳**:每个官方 drawer 块声明 probes。探针推导尽量复用视图已存在的布局常量/辅助(如 DisplayPlugin 的 BlockLayoutArrangement 直接产出各形态元素 frame),无现成辅助的用语义分区(header / content / controls 的需求矩形)表达"必须完整可见"。
4. **门禁**:新增 `BlockMinSizeVerificationTests`(`@testable import` 全部官方插件),对每个官方 drawer 块:
   - **必须声明 probes**(缺失即失败,报"该块未声明探针,打包期无法校验");
   - 以 minSize 构造验证用 `BlockLayoutInfo`(frame = CGRect(origin:.zero,size:minSize),size/widthColumns/heightRows 为 nil——探针一律基于 frame.size 像素推导,不做格子换算),取探针跑校验器,断言零违规,失败信息含 插件名/块 id/探针 id/违规类别与像素数据;
   - 接入 `build.sh test`(全量天然覆盖)+ 独立 `build.sh verify-sizes`(定向快速反馈)+ `cmd_package` 预检(默认开启,`--skip-size-check` 逃生门)。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 声明式几何探针 + 纯几何校验(采纳) | 确定性、零渲染、无抖动;与"纯算法剥出来单测"的仓文化一致;探针由同一套布局常量推导时与真实布局同源 | 依赖作者诚实声明;若作者改视图常量忘了改探针会漏报;探针无法捕获 SwiftUI 栈式布局的内部真实坐标差异 | 采纳 |
| B accessibilityIdentifier 打标 + 渲染读回真实 frame | 校验真实渲染结果,最强信号 | 12 插件视图逐一打标同样侵入;读 a11y 树需真窗口/客户端激活,无窗口测试进程不可靠、易抖动;三类检查中的"溢出邻居"依赖渲染 frame 与内容盒比对,精度受字体/系统影响 | 不采纳(留作后续增强方向) |
| C 无声明,自动遍历 NSView 子树当探针 | 插件零改动 | SwiftUI 视图不产生逐元素 NSView(纯 SwiftUI 内容下 NSHostingView 子树几乎为空),漏检严重 | 不采纳 |
| D SwiftUI ImageRenderer / 离屏渲染 + overlay 探针回读 | 接近 B 且 API 统一 | 同 B 的可靠性问题;ImageRenderer 只出位图,回读"带 id 的 frame"需要额外镜像机制,复杂度高 | 不采纳 |

## Consequences(影响)

- Kit 新增公开类型/成员:`BlockProbe`、`NotchBlock.probes`、`BlockSizeVerifier`(纯几何);登记 api-changelog。
- 12 个官方插件(11 个含 drawer 块)各新增 probes 声明;只读元数据,不改运行路径——探针在打包校验时由宿主合成布局调用,插件 UI/引擎零行为变化。
- 边界(明确不做):a) 第三方插件未声明探针 → 跳过(文档写明);b) 字形级截断/矩形内部的细节丢失 → 几何范围外;c) 真实渲染读回(B 方案)留作后续增强。
- 门禁:verify-sizes 进常规 test 与 package 预检;文档同步见 HANDOFF §6 Task B。

## 实现收口(2026-09-07,本会话)

- Kit:`BlockProbe`(id + 块本地 rect)、`NotchBlock.probes`(可选,compact/第三方省略)、`BlockSizeVerifier.violations(probes:contentSize:)` 纯几何判定(tolerance 0.5;越界 probeOutsideContent / 自叠 probesOverlap;退化输入跳过)。
- 官方采纳(15 个 drawer 块全员声明):固定堆叠区带类(MediaControls / Notes / Pomodoro)用自然行高镜像视图常量的区带探针(最末区带并入底部内边距,minSize 矮于总需求即越界);自适应/内部滚动类(Scratchpad / Display / ClipboardHistory / QuickButtonBox / OpenCodeUsage / Calibre / Dsh / SystemMonitor)声明内容区探针(内边距缩进)。
- 门禁:`BlockSizeVerifierTests`(几何判定 10 例)+ `BlockMinSizeVerificationTests`(官方 drawer 块必须声明探针且 minSize 下零违规;缺失/空探针/违规均带像素明细失败)。
- 接线:`./scripts/build.sh verify-sizes`(几何 + 门禁两套件定向跑);`package` 默认预检 BlockMinSizeVerificationTests(`--skip-size-check` 逃生)。

## Changelog

- v2:implemented 收口(2026-09-07,本会话)。
- v1:提案。
