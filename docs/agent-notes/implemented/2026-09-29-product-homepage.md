# Agent Note: 新增产品主页（web/）与 GitHub Pages 发布通道

status: implemented
date: 2026-09-29
deciders: 用户

## Context(背景与约束)

- 现状：产品只有 README 与 Releases 两个面向用户的入口，README 第 99 行自称「目前没有独立官网页面」。用户要求新建 `web/` 并产出可公网访问的产品主页。
- 关键约束一：插件清单不得手工维护。`Plugins/` 下实际有 18 个官方插件，而 README 第 40 行写 16 个并漏掉 `Album`、`MediaControls`——这正是手工清单漂移的现成证据。主页若再手写一份，等于新增第三条会漂移的清单。
- 关键约束二：视觉必须与产品同源。`docs/DESIGN.md` 与 `Sources/NotchCenterKit/DesignTokens.swift` 是配色的唯一事实源（近黑背景、白色 alpha 层级、连续圆角、克制动效），主页不得自造一套。
- 关键约束三：仓库面向 Swift/Tuist，不引入远程依赖、不引入 npm 工具链；主页要能离线打开（`file://`）也能托管。
- 不做（out of scope）：插件市场/索引站（路线图 M2-4 的独立议题）；多页文档站；404 / sitemap / robots；购买页或统计埋点。

## Decision(决策)

- **D1 纯静态单页，零依赖零构建**：`web/index.html` + `web/styles.css` + `web/main.js`，无框架、无 CDN、无外链字体（只用系统字体栈），`file://` 直开可用。已确认取舍见「备选方案」A。
- **D2 插件数据由生成器产出，页面数字不写死**：`web/tools/gen-plugins.mjs` 扫 `Plugins/*/Plugin.plist`（经 `plutil -convert json -o -` 转 JSON，不自写 plist 解析器），取出 `PluginID` / `DisplayName` / `Description` / `DisplayNameLocales["zh-Hans"]` / `DescriptionLocales["zh-Hans"]`，按英文名排序写出 `web/data/plugins.gen.js`（`window.NOTCH_PLUGINS = [...]`，普通 `<script src>` 加载，规避 `file://` 下 `fetch` 的 CORS 限制）。页面上「18 个官方插件」的数量取自数组长度，结构上不可能与 `Plugins/` 脱节。`--check` 模式只比对不写入，供 CI 做防漂移门禁。
- **D3 双语在运行时切换，HTML 以中文为基准**：需要翻译的节点标 `data-i18n` / `data-i18n-html` / `data-i18n-attr`；语言解析顺序为 `?lang=` → `localStorage` → `navigator.language`（非 `zh*` 落到 en）。无 JS 时中文文案仍在 HTML 里，插件区降级为一条提示。
- **D4 视觉镜像 DesignTokens**：`styles.css` 以 CSS 自定义属性复刻 §2 配色 / §3 圆角 / §7 动效（`--fg-body: 0.92` 等白 alpha 阶梯、radius 7/8/10/12/18、`systemBlue` 与 `accentGreen`）。Hero 的「菜单栏 + 刘海缺口 + 抽屉」用纯 CSS 造型，不叠位图，任何缩放下都不糊。深色为唯一配色，不跟随 `prefers-color-scheme`。
- **D5 派生资源入库，脚本保证可复现**：`web/tools/build-assets.sh` 用 `sips` / `ffmpeg` / `cwebp` 从 `docs/assets/` 与 `Resources/AppIcon.png` 派生 webp、mp4 与 favicon/og 图，产物提交进仓库。`Common.gif`(862KB) 与 `Setting.gif`(2.5MB) 必须转码为 mp4，否则落地页首屏不可接受。
- **D6 发布走 GitHub Pages Actions**：`[pages.yml](../../../.github/workflows/pages.yml)` 在 push `main`（限定 `web/**`）时先跑 `gen-plugins.mjs --check`，再 `upload-pages-artifact`（`path: web`）+ `deploy-pages`。构建 job 用 macOS runner——`plutil` 是 macOS 专有，这是 D2 选择它换来的代价（无解析器 bug 面，代价是仅在 `web/**` 变更时触发的高频度很低的一次 macOS runner 用量）。仓库 Settings → Pages 的 Source 需人工设为 `GitHub Actions`。
- **D7 不做插件分类分组**：`Plugins/` 与插件管理窗口都没有分类概念，README 的四类是散文描述且未覆盖 Album/MediaControls。分组会引入 D2 极力避免的第二份手工清单，改为 18 张卡平铺。
- **D8 顺带修正 README**：插件数 16 → 18 并补两个漏项，「目前没有独立官网页面」改为指向主页地址。理由见「影响」——用户可见的声明必须与现状一致。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 纯静态 HTML/CSS/JS | 零依赖、无构建步骤、`file://` 可开、审查门槛低 | 将来做插件市场/文档站需重新选型 | **采用** |
| B Astro 静态站点 | 多页与内容集合能力强 | 引入 npm 依赖与 CI 构建链，与仓库轻依赖纪律冲突，单页场景收益为零 | 不采用 |
| C Vite + React + Tailwind | 组件化开发体验好 | 依赖最重、构建产物需另建发布流程，单页不值得 | 不采用 |
| D 手写插件清单 JSON | 一次写完最省事 | 就是 README 漂移的复现，违反「插件列表不得手工维护」 | 不采用，改 D2 |
| E 生成器自写 plist 解析器（纯 Node） | CI 可用 ubuntu runner，省 macOS 额度 | 自写 XML 解析器是纯 bug 面（实体转义、CDATA、嵌套 dict），收益仅是 runner 选择 | 不采用，改 D2 + D6 |
| F 生成器输出 HTML 片段而非数据 | 无 JS 也能看到插件列表 | 生成器要写 HTML 就是第二份模板，且与 i18n 双份文案纠缠 | 不采用，降级提示即可 |
| G 资源改为 CI 现场派生，不入库 | 仓库不含派生二进制 | GitHub runner 不保证有 ffmpeg，部署会随时红 | 不采用，改 D5 |
| H 中英各出一份静态页（`/` 与 `/en/`） | 无 JS 也能切换、SEO 更直白 | 双份 HTML 双份内容维护，正是 D2/D3 要消灭的重复 | 不采用，改 D3 |

## Consequences(影响)

- 新增目录 `web/`（页面、生成器、派生资源）与 `.github/workflows/pages.yml`；不触碰 `Sources/`、`Plugins/`、`Project.swift`、`build.sh`，不影响任何构建或发布产物。
- 生成物 `web/data/plugins.gen.js` 与 `web/assets/**` 入库：新增约 1MB 二进制，换来离线可部署与可复现；改 `Plugin.plist` 的 DisplayName/Description 后必须重跑 `gen-plugins.mjs`，CI 的 `--check` 会在漏跑时红。
- `web/` 下不得出现 `node_modules` 或 npm 清单：生成器只用 Node 内置模块 + `plutil`。
- 仓库治理未覆盖 Web 域：本任务不新增 `docs/agents/` 子文档，维护说明就近放在 `[web/README.md](../../../web/README.md)`；后续若 Web 域膨胀，再按领域拆分红线。
- 文档一致性：`[README.md](../../../README.md)` 的插件清单与官网表述同步修正（D8）。`docs/产品路线图.md` 的里程碑体系与本任务无关，本次不改，其 M2-4「插件索引站点」仍是独立议题。
- 站点地址为 `https://zzh799.github.io/NotchCenter/`；生效前提是人工把仓库 Pages 的 Source 设为 `GitHub Actions`（代码无法完成该步）。

## Changelog

- 2026-09-29：首版。主页落地，含生成式插件清单、双语运行时切换、派生资源管线与 Pages 发布。
