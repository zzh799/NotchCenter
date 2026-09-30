# web/ 产品主页

NotchCenter 的对外落地页：纯静态单页，零依赖、零构建步骤，由 [pages.yml](../.github/workflows/pages.yml) 发布到 GitHub Pages，地址 <https://zzh799.github.io/NotchCenter/>。设计决策见 [2026-09-29-product-homepage](../docs/agent-notes/implemented/2026-09-29-product-homepage.md)。

同一个 Pages 站点还托管开发文档站（`/docs/`，源真相是仓库的 `docs/` 目录），那部分由 VitePress 构建，见下方「文档站」。本目录仍是零依赖静态页，不要为它引入任何构建步骤。

## 文件

- [index.html](index.html)：页面结构。中文文案直接写在这里，它也是无 JS 时的基准语言。
- [styles.css](styles.css)：全部样式。`:root` 里的 CSS 变量镜像了 [DESIGN.md](../docs/DESIGN.md) 与 `NotchTokens`（近黑背景、白 alpha 阶梯、发丝描边、圆角与动效时长），两侧改动必须同步。
- [main.js](main.js)：语言切换、插件网格渲染、演示视频播放控制。英文文案全部在这里的 `STRINGS.en`。
- [tools/gen-plugins.mjs](tools/gen-plugins.mjs)：从 `Plugins` 目录下每个插件的 Plugin.plist 生成插件清单。
- [tools/build-assets.sh](tools/build-assets.sh)：从 `docs/assets` 与 `Resources/AppIcon.png` 派生 `assets/` 下的压缩资源。
- `data/plugins.gen.js` 与 `assets/*` 是生成物，提交进仓库，请勿手改。

## 约定（改之前先读）

- 插件清单不许手写：页面上的插件数量、名称、双语描述全部来自 Plugin.plist。改了 `Plugins/*/Plugin.plist` 后必须重跑生成器并提交 `data/plugins.gen.js`，CI 的 `--check` 会拦截漏跑的情况。
- 中文文案只有一份：中文写在 index.html 里，切换语言时由 main.js 从 DOM 现场快照恢复原文；英文只有 `STRINGS.en` 一份。新加文案时两边都要加，漏加英文会在控制台告警并回退中文。
- 图标集中在 index.html 顶部的 SVG sprite 里，正文与 JS 都通过 `<use href="#id">` 引用；新插件想要专属图标就在 sprite 加一个 symbol 并登记进 main.js 的 `ICON_BY_DIR`，不登记则回退通用图标。
- assets 是派生物：源素材（`docs/assets`、`Resources/AppIcon.png`)变更后重跑脚本并提交结果，不要在仓库里出现手工编辑过的派生图。
- 深色是唯一配色，不跟随 `prefers-color-scheme`；唯一的彩色是链接的系统蓝与提示语义的橙，均为 DESIGN.md 认可的语义色。

## 常用命令

```bash
node web/tools/gen-plugins.mjs          # 从 Plugin.plist 重新生成插件清单
node web/tools/gen-plugins.mjs --check  # 只比对不写入，不一致退出码 1（CI 同款门禁）
bash web/tools/build-assets.sh          # 重新派生 web/assets（需要 sips、ffmpeg、cwebp）
```

## 本地预览

直接打开 `index.html` 即可（`file://` 下完整可用，页面不依赖任何网络资源）；需要 HTTP 时：

```bash
cd web && python3 -m http.server 8000
```

## 部署

push 到 main 且改动涉及 `web/**` 时自动发布。首次启用需要在仓库 Settings → Pages 把 Source 选成 `GitHub Actions`，这一步无法由代码完成。

## 文档站

开发文档站（`/docs/`）由 VitePress 从仓库的 `docs/` 目录生成，产物落在 `web/docs/`，与主页在同一个 Pages 产物里一次发布。设计决策见 [2026-09-30-vitepress-docs-site](../docs/agent-notes/implemented/2026-09-30-vitepress-docs-site.md)。

- 项目根是 `docs/`，VitePress 配置与主题在 `docs/.vitepress/`；仓库根的 [package.json](../package.json) 只提供 `docs:dev` / `docs:build` / `docs:preview` 三个脚本。
- 发布哪些页面由 [`docs/.vitepress/docs-manifest.mts`](../docs/.vitepress/docs-manifest.mts) 决定：新文档要进站点必须在清单里登记，否则构建时被 `srcExclude` 排除（白名单，防内部文档泄漏到公网）。
- 指向仓库其他文件的相对链接（如 `../../AGENTS.md`、`../Sources/**`）由 [`rewrite-repo-links.mts`](../docs/.vitepress/rewrite-repo-links.mts) 在构建期改写成 GitHub 源码地址，源 Markdown 不改。
- `web/docs/` 是构建产物，不入库（.gitignore），本地不要手工改。
- `npm audit` 会报 esbuild 与 vite 的开发服务器告警（经 VitePress 1.x 传递依赖，1.x 线官方标记为无补丁）：只在本机跑 `docs:dev` 时有影响，构建产物与线上站点不受影响；等 VitePress 2.x 转正再升级。

```bash
npm ci                      # 安装 VitePress（需要 Node 18+）
npm run docs:build          # 构建到 web/docs，死链会让构建直接失败
npm run docs:preview        # 本地预览构建产物
npm run docs:dev            # 带热更新的开发服务器
```

## 已知事项

- 两段演示 GIF 录制于插件重构之前，第二段里出现的 OpenCode Usage 插件现已删除；素材重录后只需重跑 `build-assets.sh` 并替换 `docs/assets` 下的源文件。
