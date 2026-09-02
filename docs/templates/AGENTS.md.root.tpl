<!-- managed:doc-driven-dev -->
# {{PROJECT_NAME}} 常驻指令集

## 核心原则
- 一事一处:事实只在一处,其余用链接指向,禁止内联重复。
- 本文件仅放常驻命令(每条 1-3 行);示例/故事/长文一律放 docs/ 对应文档。
- 决策放 `docs/agent-notes/`,事故复盘放 `docs/postmortem/`。

## 仓库布局
| 路径 | 内容 |
|------|------|
| `AGENTS.md` | 全局常驻指令(本文件) |
| `docs/TERMINOLOGY.md` | 术语纪律(banned→preferred,机器校验) |
| `docs/agent-notes/{proposed,implemented,rejected,archive}/` | 设计决策与归档 |
| `docs/postmortem/` | 事故复盘 |
| `docs/templates/` | 文档模板(含 api-changelog / security-advisory / benchmarks-result) |
| `scripts/run-doc-checks.sh` | 一键文档门禁(链接/换行/格式/预算/术语) |
| `doc-budgets.manifest.json` | 字数预算(超限冻结,改需 PR) |
| `.doc-driven-dev/manifest.json` | 治理落地记录(机器可校验) |

## 技术栈
`{{TECH_STACK}}`。文档内代码块语言必须属于 `doc-budgets.manifest.json` 的 `code_block_langs`(由 `scripts/verify-code-blocks.sh` 校验)。

## 术语纪律
全部术语与禁用词映射见 `docs/TERMINOLOGY.md`;`docs/` 与各指令入口内出现禁用词即报错(`scripts/verify-terminology.sh`)。

## Slop Checklist(反模式)
- [ ] 出现"目前/当前/将来"等时效词 -> 报错
- [ ] 同一信息重复出现 -> 报错
- [ ] Markdown 链接使用裸文件名 -> 报错
- [ ] 段落手动换行(列表/表格/代码除外) -> 报错
- [ ] Agent Note 缺少 `## Alternatives considered`(归档除外) -> 报错
- [ ] 字数超过 `doc-budgets.manifest.json` 上限 -> 报错

## 字数预算
本文件上限 1900 字符(`wc -m`);超限拆解顺序:搬走非本层内容 -> 压缩本层 -> PR 提高预算。
