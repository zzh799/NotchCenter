# Agent Note: 收敛服务调度、网格指标与截图转发

status: implemented
date: 2026-09-17
deciders: 用户

## Context(背景与约束)
- 本次为保持行为的内部重构，不调整服务启停、600ms 等待、权限或截图任务合并语义。

## Decision(决策)
- Dsh / Calibre 的 runAction 由主 actor 任务顺序编排；同步控制操作仍在 detached 任务执行，随后等待、发布状态并直接 await refreshOnce，去掉 MainActor.run 内的新任务。
- GridMetrics.current 直接读取 GridMetricsStore 的加锁值快照，固定顶栏高度归属 GridMetrics；NotchGridMetrics 保留单向兼容入口。LayoutEngine 的单次内容/窗口尺寸计算复用一份快照。
- ScreenSnapshotter 的预热入口直接调用 startCapture，删除无职责的 capture 包装。

## Alternatives considered(备选方案)
- 全部内联：会破坏后台阻塞隔离、截图 in-flight 合并和几何可测性，不采用。
- 抽取公共服务监视器：超出两实例的现行约定，不采用。

## Consequences(影响)
- 不改变公共 Kit API 或持久化格式。
- 基线 DrawerGridGeometryTests 14 项通过；新增快照值语义测试，全量验证 672 项 XCTest 与 14 项 Swift Testing 通过（日志：`/tmp/notch-call-layers-test.log`）。
- 服务实机启停和屏幕截图不作为自动化验证手段，避免改变用户服务状态或触发隐私访问。
