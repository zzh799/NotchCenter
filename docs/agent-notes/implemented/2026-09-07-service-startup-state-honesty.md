# 服务启动期状态诚实化(.starting) + Calibre wrapper 不等缺失卷

status: implemented
date: 2026-09-07
deciders: zhouzihang / 维护者

## Context(背景与约束)

事故:Calibre 插件启动服务后,网页无法访问。

排查事实(macOS 本机):

1. `com.user.calibre-server` 的 wrapper(`~/.calibre-launchd/calibre-server-wrapper.sh`)会等**全部**外置库卷挂载,最多 120s;`/Volumes/Zeaven` 常未挂载 → 每次启动都白等满 120s,`calibre-server` 迟迟不 exec。
2. 等待期内 `nginx`(IPv4 `:8080` 反代到 `[::1]:8080`,nginx.conf 有意为之的双栈并存)上游无响应 → 浏览器打开 `localhost:8080` 得到 **502 Bad Gateway** ——即"网页无法访问"。
3. 插件侧 `LaunchdProbe.resolveState` 把「已加载 + 有 PID + 无监听」判为 `.managed`(绿 Running)——launchd 任务在跑(wrapper 进程),但 web 尚未就绪。用户看到绿灯、点开即 502,毫无提示。

结论:页面不可达的直接根因是 wrapper 等卷 + nginx 502;但插件"绿灯 Running"掩盖了启动期,是体验层的真实缺陷,须一并修复。

## Decision(决策)

1. **wrapper 不等缺失卷**(用户主目录脚本,非仓库内容):`GRACE_SECONDS`(默认 20s)宽限期内等全部库出现;到点后只要有任一库挂载即启动,缺失卷跳过并记日志;若一个卷都没挂载,按 30s 节奏继续等(最多 `MAX_EXTRA_SECONDS` 120s)再启动。默认值可用环境变量 `CALIBRE_GRACE_SECONDS` / `CALIBRE_MAX_EXTRA_SECONDS` 覆盖。
2. **启动期不冒充 Running**(仓库):`LaunchdServiceStatus.State` 新增 `.starting`(已加载 + 有 PID + 无监听:wrapper 等卷 / worker 启动中),`resolveState` 原「有 PID 未监听 → `.managed`」改为「→ `.starting`」;`isServiceOn` 含 `.starting`(开关启动期不回弹);两块/两浮窗黄点 + "Starting…";语义落点:`LaunchdProbe.resolveState` / 两个 `ServiceMonitor.isServiceOn` / 两块视图 / 两浮窗 / 两插件 lproj(en、zh-Hans 键集同步)。
3. 回归:`LaunchdControlKitTests.testResolveStateTable` 更新该行为断言;文档状态表(指南 §3)与决策记录同步。五态表 → 六态表。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 只修 wrapper,不动状态机 | 改动最小,直接消除 120s 502 窗口 | 启动瞬间仍可能绿 Running 片刻;启动期 UI 依旧撒谎,其他慢启动服务(如未来插件)会重蹈覆辙 | 否,半修复 |
| 把「有 PID 未监听」并入 `.loadedNotRunning`(黄) | 无新枚举态 | 开关会从开回弹到关(启动中误显"未开"),且无法区分"等卷中"与"真挂了";要额外改 isServiceOn 语义也更绕 | 否,语义混淆 |
| 插件局部覆盖(仅 Calibre 显示层按 port==nil 变黄) | 不动共享 Kit、不影响 Dsh | 状态真源与显示脱节,违反「Kit 是唯一状态源」;Dsh 同样场景不修;难单测 | 否,治标不治本 |
| 新增 `.starting` 六态(本方案) | 状态机诚实:绿=真在服务、黄=启动中、黄=已退;开关不回弹;Kit 一处改,两插件统一受益;纯函数可单测 | 新增枚举态 → 两插件 4 处 switch + l10n + 文档同步 | 选此 |

## Consequences(影响)

- 共享 Kit `LaunchdControlKit` 新增 public 枚举成员 `.starting`:服务控制类插件若自行 switch 状态需补 case(Xcode 对穷举 switch 会强制报错,无静默回归);`LaunchdProbe.State` 文档注释更新。
- DshPlugin 同步获得启动期黄点(其 pnpm 启动通常亚秒级,仅瞬间黄色,无感)。
- wrapper 行为变化记录在脚本注释;日志行 `Skipping unavailable library:` 保留(缺失卷可审计)。
- 需求方手动 `restart` 或 `toggle` 后,等待窗口显著缩短(常见场景从 120s → ~0s)。

## Changelog

- v1.0.0:初始提案,同日实现并落地(2026-09-07)。