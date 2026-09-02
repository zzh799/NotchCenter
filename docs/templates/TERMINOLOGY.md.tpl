---
# 机器可读术语表。行格式约束(勿改动结构,脚本只解析 frontmatter 内的 banned 行):
#   - banned: "被禁词"
#     preferred: "推荐写法"
terms:
  - banned: "shape"
    preferred: "具体类型(TypedDict / interface)"
  - banned: "contract"
    preferred: "request / response fields"
---
# {{PROJECT_NAME}} 术语纪律

> AGENTS.md 只引用本文件;术语增改在此完成,无需改动指令入口文件。

## 规则
1. 出现于 `docs/` 与各指令入口的 banned 词即违规(`docs/TERMINOLOGY.md` 自身、`docs/templates/`、归档目录与代码围栏除外)。
2. 新增术语:在 frontmatter 增加一行 `banned`/`preferred`,并在下方"备注"记录取舍原因。
3. 增删术语走 PR,与预算变更同权;术语生效后由 `scripts/verify-terminology.sh` 机器校验。

## 备注
- shape:指代不精确,必须落到具体类型定义。

## Changelog
- v3.0.0:术语纪律从 AGENTS.md 外置为独立文档(doc-driven-dev 3.0)。
