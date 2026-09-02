# Agent Note:接入 doc-driven-dev 文档治理门禁

status: implemented
date: 2026-09-02
deciders: zhouzihang
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- 项目已有成熟的 docs/ 体系(架构文档、DESIGN、插件指南、docs/agents/ 领域子文档),但无机器校验:入口文件体积失控(AGENTS.md 13093 字符)、无决策记录/事故复盘目录、无术语纪律与预算约束。
- 目标:将治理体系落地为"机器可校验的工程宪法",存量文档按新标准收敛,不丢失既有信息。

## Decision(决策)

- 采用 doc-driven-dev 3.0 工作流落地:标准化目录 + `doc-budgets.manifest.json`(schema_version=2)预算 + 8 个校验脚本 + pre-commit/CI 门禁。
- 入口瘦身:AGENTS.md 由 13093 字符收敛至 ~1780 字符(≤1900 预算);代码地图/命令/宿主通用红线外置至 [`docs/agents/宿主开发约定.md`](../../../docs/agents/宿主开发约定.md),领域红线由各 docs/agents/ 子文档承载(均已含完整机制与历史)。
- 命名统一:git 跟踪名 `Agents.md` → `AGENTS.md`;构建脚本目录 `Scripts/` → `scripts/`(避免 Linux CI 大小写敏感冲突,引用同步更新)。
- 术语纪律外置 `docs/TERMINOLOGY.md`(frontmatter terms 暂空,团队按需增补,防误伤 SwiftUI `Shape` 等专有名词)。
- 门禁排除第三方与私有内容:`Vendor/**`、`.zcode/**`、`docs/agent-notes/archive/`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 仅追加门禁引用块、AGENTS.md 现状冻结 | 零改写风险 | 入口预算需放宽至 13K+,门禁对核心入口无约束力 | 否,用户选瘦身 |
| 全文保留并绕开预算 | 不动文档 | 与"防膨胀"目标相悖 | 否 |
| 瘦身 + 领域知识外置(docs/agents/ 承载) | 信息零丢失、入口可控 | 需核对子文档覆盖度(已验证齐全) | 采用 |

## Consequences(影响)

- AGENTS.md 不再承载完整红线速览,协作方须先读对应领域子文档(入口已用索引表引导)。
- 代码/文档新增或修改须通过 `scripts/run-doc-checks.sh`;超预算需走拆解或 PR 提额。
- 后续决策/事故分别记入 `docs/agent-notes/`、`docs/postmortem/`,过期决策 git mv 至 `archive/` 而非删除。

## Changelog

- v3.0.0:本记录为 doc-driven-dev 3.0 初始化落地快照(模板提供)。
