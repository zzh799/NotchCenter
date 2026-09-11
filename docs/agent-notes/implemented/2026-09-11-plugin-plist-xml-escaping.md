# Agent Note:插件 Info.plist 元数据必须 XML 转义

status: implemented
date: 2026-09-11
deciders: 实现代理（门禁/产物校验中发现）
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

- `scripts/build.sh` 的 `assemble_bundle()` 用 **heredoc 手写 XML 模板**拼出各插件 bundle 的 `Info.plist`，`DisplayName` / `Description` 直接来自 `Plugins/<Name>/Plugin.plist` 的自由文本。
- 模板只对 API 版本区间做了转义（`..<` → `..&lt;`），**没有对这两段自由文本做任何转义**。
- 本批新增的插件里，`Calendar & Tasks`、`Mirror & Privacy`、`Capture & OCR`、`Services & Brew`、`Eye Care & Wellness` 都含 `&`。
- 后果：`&` 在 XML 里是实体起始符，生成的 plist 不合法。实测 `plutil -lint` 报 `Encountered unknown ampersand-escape sequence`。
- **这类缺陷的隐蔽性是本 note 的重点**：源码 `Plugin.plist` 完全合法（`&amp;`）、插件单测全绿、`build.sh test` 也全绿——只有真正组装出的 `.app` 产物里的那个 plist 是坏的，而坏掉的 bundle 在运行时直接加载失败。
- 不做（out of scope）：不改用 `plutil`/`PlistBuddy` 程序化生成 plist（改动面大，且现有模板还有注释需要保留）；不做产物级 plist 校验门禁（本次用一次性核对覆盖，见 Consequences）。

## Decision(决策)

`build.sh` 新增 `xml_escape()`，在**发现阶段**就为两个字段生成转义后的数组，模板只引用转义版本：

- 转义顺序固定 `&` → `<` → `>`：`&` 必须最先替换，否则会把刚生成的 `&lt;` 再转义成 `&amp;lt;`。
- 新增 `PLUGIN_DISPLAYS_XML` / `PLUGIN_DESCRIPTIONS_XML` 两个并行数组，模板从 `PLUGIN_DISPLAYS[$i]` 改为 `PLUGIN_DISPLAYS_XML[$i]`。
- 原始数组保留不动：`InfoPlist.strings`（zh-Hans 元数据）走的是 openstep 格式的 `.strings`，那里的转义规则不同（只需转义 `"` 与 `\`），不能套用 XML 转义。

配套回归（`Tests/NotchCenterTests/LocalizationTests.swift`）：

1. `pluginMetadataIsXMLSafe` — 锁住 `build.sh` 里转义函数的存在、`&` 早于 `<` 的替换顺序、以及模板引用的是转义后数组。
2. `pluginMetadataProducesParseableXML` — 对每个官方插件的真实元数据跑一遍同样的转义，断言拼出的 XML 能被 `PropertyListSerialization` 解析且**原文可原样还原**。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 只改这 5 个插件的 DisplayName（去掉 `&`） | 改动最小 | 治标：下一个插件写 `&` 或 `<` 时同样炸，且 `&` 在英文产品名里很常见 | 否 |
| 在模板里对每个字段就地转义 | 单点改动 | heredoc 模板里逐字段套函数可读性差、容易漏 | 否 |
| 发现阶段生成转义数组（采纳） | 一处转换、模板保持干净、原始值仍可用 | 多两个并行数组 | 是 |
| 改用 `plutil`/`PlistBuddy` 程序化生成 plist | 结构上不可能写出非法 XML | 改动面大；模板里的说明注释会丢 | 否 |
| 加产物级 plist 校验门禁 | 能拦住所有此类问题 | 需要新增一个门禁脚本与预算，超出本次范围 | 否（记为后续项） |

## Consequences(影响)

- **修复面**：`scripts/build.sh` 新增 `xml_escape()` + 两个 XML 数组 + 模板两行改用转义版本。
- **验证**：24 个插件 bundle 的 `Info.plist` 全部通过 `plutil -lint`；含 `&` 的显示名在产物里正确还原为 `Calendar & Tasks` 等原文；无 `&` 的（如 `Weather`）不受影响。
- **测试**：`LocalizationTests` 新增 2 个 swift-testing 用例（其中一个对全部官方插件参数化）。全量 948 XCTest + 14 swift-testing 用例全绿。
- **保留意见（记录在案）**：根因是"手写 XML 模板拼 plist"这一做法本身。本次只补了转义，没有消除这个结构。若日后有第三个字段加入模板，应当重新评估改成程序化生成。
- 落地后本 note 移入 `docs/agent-notes/implemented/`。

## Changelog

- v1.0.0:初稿（含 `&` 的插件显示名导致 bundle Info.plist 非法；补 xml_escape 与回归）。
