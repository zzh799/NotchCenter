<!-- managed:doc-driven-dev v3 -->
# AGENTS.md — NotchCenter 常驻指令集

长文与示例一律放 `docs/`,本文件只放常驻指令与索引。

## 项目是什么

**NotchCenter** 是 macOS 刘海交互插件宿主:刘海区展开抽屉、网格布局插件"块";核心仅承担基础设施,业务功能皆以官方插件提供。架构基线见 [架构设计文档](docs/NotchCenter 架构设计文档.md),UI 遵循 [DESIGN.md](docs/DESIGN.md)。macOS 15+ / Swift 6 严格并发 / AppKit + SwiftUI / Tuist;accessory 策略,无 Dock 图标。

## 改前必读

`docs/agents/` 按领域拆分红线、机制、历史事故与回归测试,**改到某领域前先读对应子文档**——分域索引与领域速查见 [开发者工作流与门禁](docs/开发者工作流与门禁.md);宿主通用约定(代码地图 / 命令 / 通用红线)见 [宿主开发约定](docs/agents/宿主开发约定.md)。

## 常用命令

构建源真相是 Project.swift,插件按 Plugin.plist 自动发现,工程与产物皆再生制品。

```bash
./scripts/build.sh dev|run [debug|release]  # 构建 + 组装插件 bundle / 启动
./scripts/build.sh test                     # 全量测试
./scripts/build.sh package [-i|-g]          # 发布 .app + zip + dmg(可选安装 / GitHub Release)
./scripts/build.sh clean                    # 清理 .build 与 dist.noindex
```

## 仓库布局

- `docs/TERMINOLOGY.md` — 术语纪律(banned→preferred,机器校验)
- `docs/agent-notes/{proposed,implemented,rejected,archive}/` — 设计决策与归档;`docs/postmortem/` 事故复盘;`docs/templates/` 文档模板
- `scripts/run-doc-checks.sh` — 一键文档门禁(链接/换行/格式等)
- `doc-budgets.manifest.json` — 字数预算 + 代码块语言白名单;超限冻结,改需 PR

## 字数预算

本文件上限 1900 字符(`wc -m`);超限:搬走非本层内容 → 压缩本层 → PR 提额。
