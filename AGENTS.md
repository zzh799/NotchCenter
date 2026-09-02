<!-- managed:doc-driven-dev v3 -->
# AGENTS.md — NotchCenter 常驻指令集

给 AI 编程助手 / 协作者阅读;长文与示例一律放 `docs/`,本文件只放常驻指令与索引。

## 项目是什么

**NotchCenter** 是 macOS 刘海交互插件宿主(NotchNotes 重构版):刘海区展开抽屉、网格布局插件"块";核心仅承担基础设施,业务功能皆以官方插件提供(可同等替换)。架构基线见 [`docs/NotchCenter 架构设计文档.md`](docs/NotchCenter 架构设计文档.md),UI 遵循 [`docs/DESIGN.md`](docs/DESIGN.md)。macOS 14+ / Swift 6 严格并发 / AppKit + SwiftUI / SPM;`.app` accessory 策略,无 Dock 图标。

## 改前必读 `docs/agents/`

各领域红线、机制、历史事故与回归测试均拆在此;**改到某领域前先读对应子文档**:

- [宿主开发约定](docs/agents/宿主开发约定.md) — 代码地图 / 命令 / 宿主通用红线
- [插件开发约定](docs/agents/插件开发约定.md)
- [面板与抽屉](docs/agents/面板与抽屉.md)
- [抽屉分页与滑动切页](docs/agents/抽屉分页与滑动切页.md)
- [布局引擎与网格](docs/agents/布局引擎与网格.md)
- [紧凑区与活动岛](docs/agents/紧凑区与活动岛.md)
- [系统集成与多语言](docs/agents/系统集成与多语言.md)
- [测试指南](docs/agents/测试指南.md)

## 常用命令

```bash
./scripts/build.sh dev|run [debug|release]  # 组装插件 bundle / 启动
swift build && swift test [--filter <Name>] # 编译与测试
./scripts/build.sh package [-i|-g]          # 发布 .app + zip(可选安装 / GitHub Release)
./scripts/build.sh clean                     # 清理 .build 与 dist.noindex
```

## 仓库布局

| 路径 | 内容 |
|------|------|
| `docs/TERMINOLOGY.md` | 术语纪律(banned→preferred,机器校验,出现禁用词即报错) |
| `docs/agent-notes/{proposed,implemented,rejected,archive}/` | 设计决策与归档 |
| `docs/postmortem/` | 事故复盘 |
| `docs/templates/` | 文档模板(agent-note / postmortem / api-changelog / security-advisory / benchmarks-result) |
| `scripts/run-doc-checks.sh` | 一键文档门禁(链接/换行/格式/预算/术语) |
| `doc-budgets.manifest.json` | 字数预算 + 代码块语言白名单(swift/bash/text/xml);超限冻结,改需 PR |
| `.doc-driven-dev/manifest.json` | 治理落地记录(机器可校验) |

## 字数预算

本文件上限 1900 字符(`wc -m`);超限拆解:搬走非本层内容 → 压缩本层 → PR 提高预算。

## Changelog

- v3.0.0:doc-driven-dev 3.0 初始化——入口由 13K 收敛为常驻指令;代码地图/命令/宿主红线外置至 [`宿主开发约定`](docs/agents/宿主开发约定.md);git 跟踪名统一为 `AGENTS.md`。
