{
  "schema_version": 2,
  "inherits": null,
  "self_budget_chars": 4096,
  "exclude_paths": [
    "docs/agent-notes/archive/**",
    ".doc-driven-dev/**"
  ],
  "code_block_langs": [],
  "budgets": {
    "AGENTS.md": { "target": 1500, "max": 1900 },
    "docs/TERMINOLOGY.md": { "target": 900, "max": 1600 },
    "docs/architecture/overview.md": { "target": 2400, "max": 2800 },
    "docs/api/readme.md": { "target": 1200, "max": 1500 }
  },
  "rules": [
    "超上限冻结:需 PR 说明并人工复核",
    "target 以下保留 5% 余量",
    "超限拆解顺序:搬走非本层内容 > 压缩本层 > 提上限"
  ]
}
