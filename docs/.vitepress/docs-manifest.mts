// 文档站的发布清单（唯一事实源）：哪些文档进站点、以什么顺序出现在侧边栏。
//
// 为什么是白名单而不是黑名单：docs/ 里同时躺着对外文档（架构、指南、领域约定、API 变更）
// 与内部材料（agent-notes、postmortem、产品路线图、调研与审计）。黑名单的失败模式是
// 「新增内部文档被静默发布到公网」，没人会发现；白名单的失败模式是「新增对外文档忘了
// 登记」，侧边栏当场少一项。后者可以被审查看见，前者不能，所以选白名单。
//
// 同一份清单同时驱动 sidebar（config.mts 里读每个文件的 h1 作标题）与 srcExclude
// （扫描 docs/ 取补集），因此不存在第二份会漂移的导航或排除清单。
//
// file 一律相对 docs/（VitePress 项目根），用 POSIX 分隔符，不要带 ./ 前缀。

export interface DocsSection {
  /** 侧边栏分区名 */
  readonly text: string;
  /** 分区内页面，顺序即侧边栏顺序 */
  readonly files: readonly string[];
}

export const sections: readonly DocsSection[] = [
  {
    text: '总览',
    files: ['NotchCenter 架构设计文档.md', 'DESIGN.md'],
  },
  {
    text: '开发指南',
    files: ['插件开发指南.md', '服务控制类插件开发指南.md', 'Tuist 使用指南.md'],
  },
  {
    text: '领域约定',
    files: [
      'agents/宿主开发约定.md',
      'agents/插件开发约定.md',
      'agents/面板与抽屉.md',
      'agents/抽屉分页与滑动切页.md',
      'agents/布局引擎与网格.md',
      'agents/紧凑区与活动摘要.md',
      'agents/系统集成与多语言.md',
      'agents/测试指南.md',
    ],
  },
  {
    text: 'API 变更日志',
    files: [
      'api-changelog/NotchBlock.md',
      'api-changelog/HostController.md',
      'api-changelog/BlockPopover.md',
      'api-changelog/SystemPermission.md',
      'api-changelog/SystemFilePanelPresenter.md',
      'api-changelog/HostWindowLevel.md',
    ],
  },
];

/** 站点收录的全部页面（相对 docs/） */
export const publishedFiles: ReadonlySet<string> = new Set(
  sections.flatMap((section) => section.files),
);
