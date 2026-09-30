// NotchCenter 开发文档站的 VitePress 配置。
//
// 项目根就是这个目录的上一级（docs/），所以本文件的相对路径都以 docs/ 为基准：
// outDir 用 '../web/docs' 落到仓库的 web/docs，随产品主页一起上传到 GitHub Pages。
// 发布哪些页面由 docs-manifest.mts 决定，这里不重复维护第二份清单。
//
// 维护口径见 docs/agent-notes/implemented/2026-09-30-vitepress-docs-site.md。

import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitepress';
import { publishedFiles, sections } from './docs-manifest.mts';
import { createRepoLinkRewriter } from './rewrite-repo-links.mts';

const docsRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const repoRoot = path.dirname(docsRoot);

const REPO_URL = 'https://github.com/zzh799/NotchCenter';
// 与主页同源：favicon 与触摸图标都复用 web/assets（同一个 Pages 站点，路径按站点根写）。
const SITE_ROOT = '/NotchCenter';

// 站点首页由架构设计文档充当，不再单独写一篇 index.md。
// 原因：它是最自然的「总览」入口，而它的文件名带空格，CommonMark 不允许链接目标含空格，
// 仓库门禁 verify-md-links.sh 也校验不了这种目标，所以任何地方都写不出一个指向它的链接。
// 让它直接占住站点根，既绕开了这个约束，又省掉一篇会与侧边栏重复的导航页。
const HOME_SOURCE = 'NotchCenter 架构设计文档.md';
const rewrites: Record<string, string> = { [HOME_SOURCE]: 'index.md' };

/**
 * 侧边栏标题直接取文档的一级标题，避免在清单里再维护一份标题。
 * 两处归一化：领域子文档的 h1 形如「宿主开发约定 — 领域约定」，取破折号前；
 * API 变更日志的 h1 形如「API 变更日志:NotchBlock(块声明与尺寸)」，去掉分区前缀。
 */
function sidebarTitle(file: string): string {
  const markdown = readFileSync(path.join(docsRoot, file), 'utf8');
  const heading = markdown.match(/^#\s+(.+)$/m)?.[1] ?? file;
  return heading
    .split(' — ')[0]
    .replace(/^API 变更日志[:：]\s*/, '')
    .trim();
}

/** 文件名 → 站内路由；被 rewrite 成 index.md 的那篇就是站点根 */
function routeOf(file: string): string {
  const rewritten = rewrites[file];
  if (rewritten !== undefined) return rewritten === 'index.md' ? '/' : routeOf(rewritten);
  return `/${file.replace(/\.md$/, '')}`;
}

/** docs/ 下所有 markdown 的相对路径（跳过 .vitepress 与其他隐藏目录） */
function collectMarkdown(relativeDir = ''): string[] {
  const dir = path.join(docsRoot, relativeDir);
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name.startsWith('.')) return [];
    const child = relativeDir === '' ? entry.name : `${relativeDir}/${entry.name}`;
    if (entry.isDirectory()) return collectMarkdown(child);
    return entry.isFile() && entry.name.endsWith('.md') ? [child] : [];
  });
}

/**
 * 发布集合的补集：没登进 docs-manifest.mts 的 markdown 一律不构建。
 * 白名单的意义就在这里：新增内部文档（agent-notes、postmortem、调研）默认不会被发布。
 */
const excludedMarkdown = collectMarkdown().filter((file) => !publishedFiles.has(file));

/**
 * GitHub 的标题锚点规则：小写、空格转连字符、去掉标点（保留文字/数字/下划线/连字符）。
 * 必须与文档里既有的锚点写法一致：源文档里 `插件开发指南.md#4-新增插件步骤` 指向
 * `## 4. 新增插件：步骤`，而 VitePress 默认 slugify 会产出 `_4-新增插件-步骤`
 * （数字前缀加下划线、全角冒号折成连字符），点击跳不到目标。
 */
function githubSlugify(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replace(/\s+/gu, '-')
    .replace(/[^\p{L}\p{M}\p{N}\p{Pc}-]/gu, '');
}

export default defineConfig({
  title: 'NotchCenter 开发文档',
  description:
    'NotchCenter 的插件开发与接口文档：架构设计、插件开发指南、领域约定与 API 变更日志。',
  lang: 'zh-CN',
  base: '/NotchCenter/docs/',
  outDir: '../web/docs',
  cleanUrls: true,
  // 深色是唯一配色（与产品一致），因此不提供亮色切换。
  appearance: 'force-dark',
  head: [
    ['link', { rel: 'icon', type: 'image/png', sizes: '32x32', href: `${SITE_ROOT}/assets/favicon-32.png` }],
    ['link', { rel: 'apple-touch-icon', href: `${SITE_ROOT}/assets/apple-touch-icon-180.png` }],
    ['meta', { name: 'theme-color', content: '#050506' }],
  ],
  srcExclude: excludedMarkdown,
  rewrites,
  markdown: {
    anchor: { slugify: githubSlugify },
    config: createRepoLinkRewriter({ repoRoot }),
  },
  themeConfig: {
    nav: [
      { text: '开发指南', link: '/插件开发指南' },
      { text: 'API 变更日志', link: '/api-changelog/NotchBlock' },
      { text: '产品主页', link: `${SITE_ROOT}/` },
    ],
    sidebar: sections.map((section) => ({
      text: section.text,
      items: section.files.map((file) => ({
        text: sidebarTitle(file),
        link: routeOf(file),
      })),
    })),
    outline: { level: [2, 3], label: '本页目录' },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '没有找到匹配内容',
            resetButtonTitle: '清除查询条件',
            footer: { selectText: '选择', navigateText: '切换', closeText: '关闭' },
          },
        },
      },
    },
    editLink: {
      pattern: `${REPO_URL}/edit/main/docs/:path`,
      text: '在 GitHub 上编辑此页',
    },
    socialLinks: [{ icon: 'github', link: REPO_URL }],
    docFooter: { prev: '上一篇', next: '下一篇' },
    sidebarMenuLabel: '目录',
    returnToTopLabel: '回到顶部',
  },
});
