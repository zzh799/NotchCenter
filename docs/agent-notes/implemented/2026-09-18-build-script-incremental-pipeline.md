# Agent Note: 构建脚本按阶段门禁化，去掉无条件 tuist 重生成

status: implemented
date: 2026-09-18
deciders: 用户

## Context(背景与约束)

- 症状：改一个插件后 `build.sh dev/run` 实测约 13 s，观测上像是"所有插件都被重建"。
- 实测澄清：**编译层面本来就是增量的**。只改 `Plugins/PomodoroPlugin` 一个文件时，xcodebuild 只重编该 target，其余 10 个插件一个源文件都没重编。真正的浪费在脚本层的四个无条件动作：
  - `run_generate` 每次执行 `tuist clean manifests` + `tuist generate`。Tuist 每次重写 `Derived/Sources/TuistBundle+NotchCenter.swift` 与 `TuistStrings+NotchCenter.swift`，逼 xcodebuild 判全部 target 签名失效。实测对照：紧跟 generate 之后构建 6 s / 15 次 CodeSign；不跑 generate 直接构建 2 s / 0 次 CodeSign。
  - `assemble_app` 无条件 `rm -rf Contents/PlugIns`，11 个插件 bundle 全部重建 + 重签。
  - `build_inputs_hash` 把 `Vendor/**/.build`（4265 个 SPM 产物）与 12 个 `.DS_Store` 当构建输入哈希，占 1.43 s，且会被与源码无关的操作（Finder 浏览目录、SPM 重解析 `workspace-state.json`）误触发。
  - dev 构建实际在编**通用架构**：`-showBuildSettings` 带 destination 时报 `ARCHS = arm64 x86_64 / ONLY_ACTIVE_ARCH = NO`，产物 `lipo -archs` 确认为 fat 二进制。编译量翻倍。
- 不做（out of scope）：不改宿主的 target 依赖拓扑；不引入编译缓存工具（sccache/ccache）；不做插件热重载。
- 不可妥协：门禁必须保守失败——stamp 缺失、不匹配、工程目录缺失，任一条件成立就老老实实重新生成。宁可多花 3 s，不可漏生成或对着陈旧工程交付。

## Decision(决策)

- **D1 工程重生成门禁**：`manifests_fingerprint()` = `sha256(Project.swift + mise.toml + build.sh 的内容 + Sources/Plugins/Tests/Resources 下全部文件的路径集合)`，落盘 `.build/dev-state/manifests.sha`；一致且 `NotchCenter.xcworkspace`、`NotchCenter.xcodeproj` 均在位时跳过 `clean manifests` + `generate`。`--full/-f` 强制重生成。
- **D2 指纹取「路径集合」而非「目录名集合」**：Tuist 把 `sources: ["Plugins/X/Sources/**/*.swift"]` 在清单求值阶段展开成 pbxproj 里的显式文件列表，所以**新增/删除/改名任何源文件都必须重新生成**。只盯插件目录名会漏掉这条——实测踩到：删掉一个插件源文件后 pbxproj 仍指向它，构建直接报 `error: Build input file cannot be found`。取路径集合同时保证「只改源码内容不重生成」这个省 3 s 的前提。
- **D3 构建输入指纹降噪**：`find` 排除 `.DS_Store`、`.build`、`.swiftpm` 三类非输入；并把 `build.sh` 自身纳入指纹（`API_RANGE` 等常量直接决定 bundle 组装结果，不纳入会让改了常量后产物悄悄停在旧约定上）。未排除时 4640 个文件 → 排除后 363 个，耗时 1.43 s → 0.05 s。
- **D4 整体跳过必须同时满足三个条件**（`dev_can_skip`）：输入内容指纹匹配、工程结构不过期（`needs_generate` 为假）、产物完整（所有插件 bundle 在位且无残留 bundle）。缺第二条会出现「产物完整、输入指纹也匹配，但工程还停在另一套 target 集合上」的窗口——实测踩到：插件目录删过一次又恢复后，输入指纹回到旧值、工程仍是删除后的 pbxproj，于是整体跳过，交付了与源真相不符的产物。
- **D5 插件组装增量化**：`bundle_fingerprint()` = dylib 内容 + `Plugin.plist` + `Resources/**` + `README.md` + 全局 API 版本默认值；逐插件与 `.build/dev-state/assembled/<Name>.sha` 比对，只重建/重签变化的 bundle。配套三件事：孤儿 bundle 清理（`Contents/PlugIns` 下不在发现结果里的 `.bundle` 一律删除，同步清掉对应的组装指纹）、共享库 `cmp -s` 判等后再复制、宿主 `.app` 的 `codesign` 仅在确有内容变化时执行。
- **D6 dev/test 只编本机架构**：`run_xcodebuild` 显式传 `ARCHS=$(uname -m) ONLY_ACTIVE_ARCH=YES`。发布态的通用架构由 `cmd_package` 显式指定，不经过该函数。
- **D7 新增 `build.sh doctor`**：10 条语义边界的回归入口，全程只读真实工作区（把门禁的输入路径临时指向 `mktemp` 样本目录）。
- **D8 `usage()` 去硬编码**：由 `sed -n '6,41p' "$0"` 改为标记区间 `# >>> usage` / `# <<< usage`；并新增 `SCRIPT_PATH` 绝对路径变量（多个子命令会先 `cd`，用 `$0` 会失效）。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A 维持每次构建都 `tuist generate` | 实现简单，绝不会有陈旧工程 | 每次 3 s，并逼出 15 次重签共约 7 s 纯浪费 | 不采用，改 D1 门禁 |
| B 完全不跑 generate，交给开发者手动 | 最快 | 新增/删除文件后忘记生成，构建行为与源真相静默不一致，极难诊断 | 不采用 |
| C 稳定化派生源（生成后比对内容、无变化则不回写） | 治本，从根上消除重签 | 需后处理 Tuist 生成物，与 Tuist 版本强耦合，脆弱 | 不采用，D1 已绕开该路径 |
| D 指纹只取插件目录名集合 | 计算更省 | 漏掉"插件内增删源文件"，实测直接导致构建失败 | 不采用，改 D2 |
| E 指纹纳入 `Plugin.plist` 内容 | 保守 | 改版本号/DisplayName 就白白重生成 3 s；语义上也不需要（那是 D5 的职责） | 不采用 |
| F 保留通用架构构建 | 开发产物可直接给 Intel Mac 用 | 编译量翻倍；开发/测试都在本机跑，通用架构没有意义 | 不采用，改 D6 |
| G 新增 `build.sh dev --only <Name>` 单插件定向构建 | 语义上最贴合"只编一个插件" | 实测 xcodebuild 增量已只编改动 target，D1/D6 落地后收益基本被吃掉 | 暂不实现，需要时再评估 |

## Consequences(影响)

- 实测收益（同一台机器，连续可复现）：
  - 完全无改动：14.5 s → **1~2 s**（整体跳过）。
  - 只改一个插件源码：13 s → **5~6 s**；其中 `tuist generate` 跳过、只重建 1 个 bundle、CodeSign 从 15 次降到 1 次、编译架构从 fat 降到 arm64。
  - 新增/删除源文件与插件目录：仍走 3 s 重生成，这是正确性必需，不优化。
  - 新增共享 Kit 公开 API 导致 11 个插件全量重编：约 22 s，属真实依赖级联，脚本层无法消除。
- 新增状态文件：`.build/dev-state/manifests.sha` 与 `.build/dev-state/assembled/*.sha`，均在 `.build` 内，`clean` 一并清除。首次构建、`clean` 之后、`--full` 均走全量路径。
- 新增回归入口：`./scripts/build.sh doctor`（10 条边界）。
- 文档：`docs/agents/宿主开发约定.md` 的常用命令与工程地图段落同步更新——原表述"build.sh 会 touch 清单触发 Tuist 重扫"与实现不符（touch 只改 mtime、不改内容哈希，对 Tuist 清单缓存完全无效），一并更正。
- 不改变 `Project.swift` 的 target 拓扑、`Plugin.plist` 格式与插件打包布局（`Contents/PlugIns/<Name>.bundle`）。`package` 路径未改动，发布产物仍是通用架构。
