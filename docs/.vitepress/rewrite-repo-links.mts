// 构建期把「指向仓库内其他文件」的 Markdown 链接重写成 GitHub 源码地址。
//
// 为什么需要：文档里的相对链接有两种目标，站内页面（发布集合里的 .md）与仓库里的其他
// 文件（AGENTS.md、Sources/**、scripts/**、.github/**，以及刻意不发布的 agent-notes/**）。
// 后一类在站上必然是死链，而源 Markdown 不能改（改了会破坏 scripts/verify-md-links.sh
// 的仓库内语义与本地阅读）。所以只能在渲染前把 href 换掉。
//
// 为什么落在 core rule 而不是 renderer rule：VitePress 的 .md→路由重写、base 拼接、
// 锚点归一、死链收集全在它自己的 link_open renderer rule 里。core rule 跑在渲染之前，
// 我们改完的绝对 URL 在那一层被「外部链接」判定直接放行，不会被二次拼 base，也不会被
// 当成死链，两者天然不打架。反过来在 renderer 阶段改写就要复刻 VitePress 的路由逻辑。
//
// 站内页面（发布集合内）一律不碰：交给 VitePress 完成 .md→路由与 base 拼接，我们只负责
// 那些它处理不了的目标。

import { statSync } from 'node:fs';
import path from 'node:path';
import type { MarkdownRenderer } from 'vitepress';
import { publishedFiles } from './docs-manifest.mts';

const REPO_URL = 'https://github.com/zzh799/NotchCenter';
const BRANCH = 'main';
/** 文档树在仓库里的目录名，用于把 srcDir 相对路径还原成仓库相对路径 */
const DOCS_DIR = 'docs';

// 协议、协议相对、纯锚点、站内绝对路径：都不是「仓库内相对路径」，一律不碰。
const SKIP_HREF = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#|\/)/i;

export interface RepoLinkRewriterOptions {
  /** 绝对路径：<仓库> */
  repoRoot: string;
}

/** markdown-it core rule，供 config.mts 挂到 `markdown.config` */
export function createRepoLinkRewriter({ repoRoot }: RepoLinkRewriterOptions) {
  return function repoLinkRewriter(md: MarkdownRenderer): void {
    md.core.ruler.push('repo-links', (state) => {
      // VitePress 为每个页面注入 srcDir 相对路径（如 'agents/测试指南.md'）
      const relativePath: unknown = state.env?.relativePath;
      if (typeof relativePath !== 'string' || relativePath === '') return;

      const sourceDir = path.posix.dirname(path.posix.join(DOCS_DIR, relativePath));

      for (const token of state.tokens) {
        if (token.type !== 'inline' || !Array.isArray(token.children)) continue;
        for (const child of token.children) {
          if (child.type !== 'link_open') continue;
          const href = child.attrGet('href');
          if (href === null || SKIP_HREF.test(href)) continue;
          const rewritten = toRepoLink(href, sourceDir, repoRoot);
          if (rewritten !== null) child.attrSet('href', rewritten);
        }
      }
    });
  };
}

/**
 * 返回重写后的绝对 URL；站内页面或不该处理的目标返回 null（保持原样）。
 */
function toRepoLink(href: string, sourceDir: string, repoRoot: string): string | null {
  const hashIndex = href.indexOf('#');
  const rawTarget = hashIndex === -1 ? href : href.slice(0, hashIndex);
  const anchor = hashIndex === -1 ? '' : href.slice(hashIndex);
  if (rawTarget === '') return null;

  // markdown-it 已把 href 百分号编码（中文、空格），先还原成磁盘上的真实路径
  const repoRel = path.posix.normalize(
    path.posix.join(sourceDir, decodeSafely(rawTarget)),
  );
  if (repoRel === '' || repoRel.startsWith('..')) return null;

  const docsPrefix = `${DOCS_DIR}/`;
  if (repoRel.startsWith(docsPrefix)) {
    const docsRel = repoRel.slice(docsPrefix.length);
    // 发布集合内的页面交给 VitePress；不在集合内的（agent-notes 等）落到 GitHub
    if (publishedFiles.has(docsRel)) return null;
  }

  const kind = isDirectory(repoRoot, repoRel) ? 'tree' : 'blob';
  const encoded = repoRel.split('/').map(encodeURIComponent).join('/');
  return `${REPO_URL}/${kind}/${BRANCH}/${encoded}${anchor}`;
}

function isDirectory(repoRoot: string, repoRel: string): boolean {
  try {
    return statSync(path.join(repoRoot, repoRel)).isDirectory();
  } catch {
    // 路径不存在（或权限异常）时按文件处理：GitHub 的 blob 页对二者都能给出可读结果
    return false;
  }
}

function decodeSafely(value: string): string {
  try {
    return decodeURI(value);
  } catch {
    // href 里出现孤立的 % 时 decodeURI 会抛错，此时按原样使用
    return value;
  }
}
