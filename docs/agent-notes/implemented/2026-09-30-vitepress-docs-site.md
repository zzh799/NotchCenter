# Agent Note: 用 VitePress 生成开发文档站，并入现有 Pages 站点

status: implemented
date: 2026-09-30
deciders: 用户

## Context(背景与约束)

- 现状：插件开发者的可读材料全在 `docs/` 里，入口是 GitHub 的目录树；产品主页的页脚「开发者文档」也直接指向 `tree/main/docs`。用户要求做一个文档网站，供人查看 API 与开发文档。
- 关键约束一：文档源真相是 `docs/*.md`，不能为了建站复制或改写一份。任何「把文档搬进站点目录」的做法都会立刻与 `scripts/verify-md-links.sh` 等门禁以及后续维护形成双份内容。
- 关键约束二：`docs/` 里既有对外材料（架构设计、插件开发指南、DESIGN、Tuist 指南、`agents/` 领域约定、`api-changelog/` 接口变更），也有对内材料（`agent-notes/`、`postmortem/`、`产品路线图`、`TERMINOLOGY`、`开发者工作流与门禁`、两篇调研与审计）。站点必须只发布前者，且新增对内文档时不能静默泄漏到公网。
- 关键约束三：文档里有大量指向仓库其他文件的相对链接（`../../AGENTS.md` 12 条、`../Sources/NotchCenterKit/DesignTokens.swift`、`../scripts/run-doc-checks.sh`、`../.github/workflows/*`、指向未发布 `agent-notes/` 的链接等）。这些链接在站内必然是死链，但源 Markdown 不能改（改了会破坏仓库门禁与仓库内阅读体验）。
- 关键约束四：与既有决策的关系。[2026-09-29-product-homepage](../implemented/2026-09-29-product-homepage.md) 的备选方案 B/C 明确以「与仓库轻依赖纪律冲突」否掉了 Astro 与 Vite 方案，并在「影响」里写下「`web/` 下不得出现 `node_modules` 或 npm 清单」。本决策必须显式划界，不能假装那份决策不存在。
- 不做（out of scope）：多语言、文档版本化、sitemap 与 robots、评论、把产品主页迁到 VitePress、发布 agent-notes 与产品路线图。

## Decision(决策)

- **D1 复用 VitePress 官方布局**：仓库根新增 [package.json](../../../package.json)，以 `docs/` 作为 VitePress 项目根（`docs/.vitepress/` 放配置与主题），构建命令 `vitepress build docs`。这正是官方部署指南的默认结构，不必发明 `srcDir` 指到项目根之外的变体。VitePress 固定 `^1.6.4`（当前 latest；`2.x` 仍是 alpha）。
- **D2 发布集合用白名单，单源同时驱动 sidebar 与排除**：`docs/.vitepress/docs-manifest.mts` 是有序 sections 数组（每项 `{ text, file }`，file 相对 `docs/`），扫描 `docs/**/*.md` 后把**差集**写进 `srcExclude`，sidebar 由同一数组生成。黑名单的失败模式是「新增内部文档被静默发布」（泄漏），白名单的失败模式是「新增目标文档忘了登记」（显式、在 sidebar 里看得见），后者可接受。
- **D3 链接在构建期重写，源文档零改动**：`docs/.vitepress/rewrite-repo-links.mts` 注册一个 markdown-it core rule，遍历 `link_open`，用 `state.env.relativePath` 还原出仓库路径后分两类处理：
  - 目标在发布集合内 → 原样放行，交给 VitePress 完成 `.md → 路由` 重写、`base` 拼接与锚点归一；
  - 其他（未发布文档、`AGENTS.md`、`Sources/**`、`scripts/**`、`.github/**`、目录）→ 重写成 `https://github.com/zzh799/NotchCenter/blob/main/<path>`（目录用 `tree/main/<path>`）。
  落在 core rule 而非 renderer rule 是关键：重写后的绝对 URL 在 VitePress 的 renderer 阶段被外部链接判定直接跳过，不会被二次拼 `base`，也不进 dead-link 检查。锚点原样保留。
- **D4 锚点改用 GitHub 兼容 slugify**：VitePress 默认 slugify 会给数字开头的标题加 `_` 前缀、把全角 `：` 折成 `-`，于是 `服务控制类插件开发指南.md` 里既有的 `#4-新增插件步骤` 与 `## 4. 新增插件：步骤` 生成的 id 对不上，链接点过去不会滚动。这类错**不会**被构建拦下（死链检查在比对前就把 `#` 之后整段剥掉了），所以只能把规则对齐：在 `config.mts` 设 `markdown.anchor.slugify` 为 GitHub 风格函数，该函数同时喂给 heading id、链接 fragment 归一与 outline 三处，一处生效三处一致。不用 `ignoreDeadLinks` 兜底，那只是掩盖。
- **D5 构建产物不入库**：`web/docs/` 进 `.gitignore`，CI 里 `npm ci && npm run docs:build` 输出到 `web/docs`，再沿用现有 `upload-pages-artifact`（`path: web`）与主页一次性上传。`outDir` 相对项目根，因此配置写 `../web/docs`。
- **D6 视觉微调默认主题**：`docs/.vitepress/theme/` 扩展 DefaultTheme 并覆盖配色，镜像 [DESIGN.md](../../DESIGN.md) 与 `Sources/NotchCenterKit/DesignTokens.swift` 的近黑背景、白 alpha 阶梯与系统蓝，`appearance: 'force-dark'`（深色唯一且不显示切换器）；中文单语（`lang: 'zh-CN'`），搜索用默认主题自带实现。
- **D7 CI 加一道 PR 级门禁**：[docs.yml](../../../.github/workflows/docs.yml) 增加「文档站可构建」检查（ubuntu runner，产物丢弃）。理由：Pages 部署只在 push main 跑，死链、锚点与 `srcExclude` 误配若等到合入后才暴露，会把 main 变红或让线上停在旧站。
- **D8 与全仓库零依赖纪律的边界**：产品主页 `web/` 继续是零依赖、零构建、`file://` 可开的静态页，npm 工具链**只**服务于文档站，且只落在 `docs/.vitepress/` 与仓库根的 `package.json`。上一份决策「`web/` 下不得出现 `node_modules` 或 npm 清单」仍然成立。
- **D9 顺带修正入口**：[web/index.html](../../../web/index.html) 顶部导航与页脚的「开发者文档」都改指文档站地址，与本决策同时生效。
- **D10 站点首页由架构设计文档充当，不新增 `docs/index.md`**：用 `rewrites` 把 `NotchCenter 架构设计文档.md` 映射到 `index.md`，于是站点根就是它。这不是取巧，而是被两个既有约束逼出来的唯一顺解：该文件名带空格，而 CommonMark 的链接目标**不允许含空格**（要用尖括号包住目标才行），仓库的 `verify-md-links.sh` 又只按「不带尖括号的相对路径」检查、认不出尖括号写法，因此**在任何地方都写不出一个指向它的 Markdown 链接**，除非让别的页面完全绕开它。让它占住站点根，顺带也省掉一篇会与侧边栏重复的首页。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 自写零依赖 Node Markdown 转 HTML 生成器 | 与 `web/` 的 `gen-plugins.mjs` 同构，无 npm 依赖，产物可入库 | 要自己实现标题、表格、围栏、引用块、行内嵌套与锚点 slug，是纯 bug 面；没有搜索与侧边栏 | 不采用，改 B |
| B VitePress | 官方布局恰好就是「仓库根 package.json 加 docs/ 作项目根」；自带侧边栏、本地搜索、深色主题与锚点归一，Markdown 支持完整 | 引入 npm 依赖与 CI 构建步骤，与 D8 划界后仍背离「仓库零 npm」的默认姿态 | **采用** |
| C Docusaurus | 生态与插件最丰富 | React 体系，依赖与产物体积远大于本需求，中文文档站收益不成比例 | 不采用 |
| D 黑名单式 `srcExclude`（手写要排除的目录） | 配置短 | 新增内部文档会被静默发布到公网 | 不采用，改 D2 |
| E 把选中文档复制或软链到独立站点目录再构建 | 站点工程与 `docs/` 隔离 | 复制即双份内容（与门禁、与后续维护两头漂移）；软链在 Vite 下的行为不可靠 | 不采用，改 D1 |
| F 在 renderer rule 或产物 HTML 阶段重写链接 | 不用理解 core 与 renderer 的分工 | renderer 阶段要复刻 VitePress 的路由与 `base` 逻辑（版本脆弱）；产物阶段 dead-link 检查已经跑完 | 不采用，改 D3 |
| G `ignoreDeadLinks: true` 放行外链与锚点 | 一行配置解决 | 死链与锚点问题被掩盖：构建绿了但用户点在 404 与跳不到标题 | 不采用，改 D3 与 D4 |
| H 构建产物入库（照抄主页做法） | 仓库自包含、可离线看站点 | 每次改文档要提交上百个 hash 名产物并加 `--check` 门禁；diff 噪音远大于收益 | 不采用，改 D5 |
| I 新增 `docs/index.md` 当首页，架构文档留在自己的路由 | 首页可以自由写导语与入口 | 首页只能列出一部分入口，架构文档的链接写不出来（见 D10）；且这份入口列表会与侧边栏重复维护 | 不采用，改 D10 |

## Consequences(影响)

- 新增 `docs/.vitepress/`（配置、发布清单、链接重写、主题），仓库根新增 `package.json` 与 `package-lock.json`；不新增任何文档页，也不触碰 `Sources/`、`Plugins/`、`Project.swift`、`scripts/build.sh`。
- `.gitignore` 追加 `node_modules/`、`web/docs/`、`docs/.vitepress/cache/`、`docs/.vitepress/dist/`。`docs/.vitepress/` 本身必须入库。
- 此后任何 `docs/**` 改动都会触发一次 Pages 部署（在既有 `concurrency: pages` 串行队列内，不会与主页部署互相覆盖），且会多跑一次 macOS runner 上的 `npm ci`；PR 侧另有一道 `vitepress build docs`（见 D7）。
- 文档站不适用 `file://` 直开（依赖 `base` 与客户端路由），本地预览改走 `npm run docs:preview`。
- 顺带修掉一处存量缺陷：`docs/agents/宿主开发约定.md` 里指向 `docs/Tuist 使用指南.md` 的链接因目标含空格，一直没有被解析成链接（在 GitHub 上同样是裸文本），已改成按路径引用并注明原因；没有动 `verify-md-links.sh`（它是 doc-driven-dev 下发的门禁，扩它的语法要单独决策）。
- 源 Markdown 的仓库内链接语义不变：仓库里点仍是相对路径，站上点跳到 GitHub；新增指向仓库文件的链接无需任何登记。
- 维护口径写在 [web/README.md](../../../web/README.md) 的「文档站」一节与本文，`AGENTS.md` 不动（其 2400 字符预算已接近上限）。

## Changelog

- 2026-09-30：首版。文档站落地，含白名单发布集合、构建期链接重写、GitHub 兼容锚点与并入 Pages 站点。
