<!-- managed:doc-driven-dev -->
# {{PACKAGE_NAME}} 子包常驻指令(覆盖根规则)

- 全局治理:`{{ROOT_REL}}AGENTS.md` 与 `{{ROOT_REL}}doc-budgets.manifest.json`(本子包未独立配置预算时继承根)。
- 本包专属指令:`{{PACKAGE_LINT}}`
- 术语/决策/事故规则与根一致:`{{ROOT_REL}}docs/TERMINOLOGY.md`、`{{ROOT_REL}}docs/agent-notes/`、`{{ROOT_REL}}docs/postmortem/`。
- 校验入口:`{{ROOT_REL}}scripts/run-doc-checks.sh`(文档统一存放于仓库根,不在本包另建)。
