# 修复：触控板轻扫切页途中被横向滚动组件打断

## 根因

`NotchPanelContent.handleDrawerScroll`（Sources/NotchPanelContent.swift:664-671）在**每个滚动事件**上都重跑让路探针——包括切页会话已建立之后。会话进行中页带滑行 + 面板尺寸插值会让探针的实时 NSView 几何漂移，暂存区（横向溢出的 ScrollView）一旦滑到静止光标下，`yieldDrawerSwipeToBlock()` 就把进行中的会话弹回，切页被打断。

而拖拽通路 `drawerSwipeDrag`（同文件 :701）已是 `uiState.drawerSwipe == nil` 时才探针——会话建立后锁定。两条通路不对称，触控板通路缺的正是这个守卫。

## 改动

1. **`Sources/NotchCenter/NotchPanelContent.swift` — `handleDrawerScroll`**：让路探针加 `uiState.drawerSwipe == nil` 前置条件，与拖拽通路 :701 对齐；同步改写 657-663 行注释，写明「让路只在会话建立前判定，会话期锁定（页带滑行与尺寸插值会让实时几何漂移，会话中重探针会把已开始的切页中途弹回）」。
2. **领域文档 `docs/agents/抽屉分页与滑动切页.md`**：铁律 3 / 让路探针段补「会话期锁定」约定，并把「穿越横向溢出 ScrollView 时块内可能跟随滚一点」记为已知双响应取舍（与既有"非 ScrollView 手势块双响应"同类）；跑 `./scripts/run-doc-checks.sh` 过门禁。

## 不改动

- 滑动起点直接落在暂存区上 → 让路给暂存区（既有设计共识，用户依赖它滚动暂存区）。
- 拖拽通路（已锁定）、`DrawerScrollProbe` 本体、提交两拍与冷却逻辑。
- 不新增块级让路声明（scrollUsage 体系已删，红线）。

## 验证

- `swift build && swift test`（回归锚点 DrawerPageSwipeTests / DrawerScrollProbeTests 全量通过）。
- 真机确认：`NOTCHCENTER_SCROLL_PROBE_LOG=1` + `./scripts/build.sh run`，你触控板从中间组件轻扫复现——切页应一次完成不再弹回；顺手确认暂存区滚动（起点压在它上面）仍正常。提交待真机确认后再发。