<!-- managed:doc-driven-dev v3 -->
---
# 机器可读术语表。行格式约束(勿改动结构,脚本只解析 frontmatter 内的 banned 行):
#   每词占一行、双引号包裹,格式为:
#     banned: "被禁词"
#     preferred: "推荐写法"
# 完整示例见 docs/templates/TERMINOLOGY.md.tpl。
terms:
---
# NotchCenter 术语纪律

> AGENTS.md 只引用本文件;术语增改在此完成,无需改动指令入口文件。

## 规则

1. 出现于 `docs/` 与各指令入口的 banned 词即违规(`docs/TERMINOLOGY.md` 自身、`docs/templates/`、归档目录与代码围栏除外)。
2. 新增术语:在 frontmatter 增加一行 `banned`/`preferred`,并在下方"备注"记录取舍原因。
3. 增删术语走 PR,与预算变更同权;术语生效后由 `scripts/verify-terminology.sh` 机器校验。

## 备注

- 初始化(2026-09-02):frontmatter `terms` 为空列表。中文代码注释与正文可能出现英文专有名词(如 SwiftUI `Shape`),示例禁用词需经团队讨论后按需增补,勿直接套用模板示例词。

## Changelog

- v3.0.0:术语纪律自 AGENTS.md 外置为独立文档(doc-driven-dev 3.0 初始化)。
