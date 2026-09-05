# Agent Note: 剪贴板历史插件

status: proposed
date: 2026-09-05
deciders: 用户（grilling 两轮共识 Q1–Q10）

## Context(背景与约束)

NotchCenter 尚无剪贴板能力（仅编辑器粘贴时刻的一次性读写，无 `changeCount` 常驻监听）。本插件提供纯文本剪贴板历史：后台轮询记录、抽屉列表回查、点击写回。图片 / 文件引用 / 模拟粘贴（Cmd+V）/ 落盘加密明确 out of scope。隐私红线：跳过 transient 内容、全局暂停、一键清空（仅未置顶）、明文落盘但不明示加密承诺（见 README）。

## Decision(决策)

两轮 grilling 共识定稿：纯文本起步；点击写回无模拟粘贴，附搜索 / 置顶（封顶 5 条，计入 50 条总额）/ 单条删除；50 条重启恢复、连续重复去重、单条超 100KB 不记；drawer `large 2x2` 起步可放大 `extraLarge`，compact 图标块默认点击展开抽屉；历史全局共享、显示偏好按 placement 独立；1.0s 常驻轮询 + 有屏 / 无屏双档（开 1.0s / 收起 2.5s，occlusion 探针）；单文件有序数组持久化；写回记 changeCount 快照跳过自循环；暂停全局不补记。实现落点见 `Plugins/ClipboardHistoryPlugin/`（入口、轮询引擎、纯逻辑、实例配置、视图）与单测 `Tests/NotchCenterTests/ClipboardHistoryTests.swift`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 首版含图片 / 文件引用 | 一步到位 | resourceDirectory、二进制清理、悬空路径三套分支，体积爆炸 | 砍掉，后续独立分支 |
| 直接粘贴到前台 App（模拟 Cmd+V） | 少一次按键 | 焦点抢占、辅助功能权限、前台 App 兼容三连坑，违反 accessory 不抢焦点策略 | 砍掉，只写回剪贴板 |
| 落盘加密（Keychain / 加密存储） | 密码级安心 | 独立大分支，恢复体验差 | 不做，用不记什么 + 随时停 + 随时清覆盖 80% 焦虑 |
| 拼音 / 模糊搜索 | 检索更强 | 独立大分支 | substring 大小写不敏感起步 |

## Consequences(影响)

新增 `Plugins/ClipboardHistoryPlugin/`（plist 唯一登记，Package.swift 自动发现）；`LocalizationTests` 两处硬编码数组补 `ClipboardHistoryPlugin`；单测只覆盖纯逻辑与假 pasteboard 驱动，禁碰真实 `NSPasteboard`；transient 判定为尽力而为的启发式（类型名含 transient / concealed），README 如实声明局限。

## Changelog

- v1.0.0: grilling 共识定稿（2026-09-05）。
