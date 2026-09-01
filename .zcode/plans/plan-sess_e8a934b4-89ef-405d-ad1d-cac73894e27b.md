# 探针方案：宿主子树枚举判定"实际可横向滚动"（零插件改动）

## 核心洞察（与旧禁令的关系）

旧探针 = 事件时刻从 `hitTest` 命中叶子**向上** walk superview 找 NSScrollView。死因：SwiftUI 在 `NSHostingView` 层接管事件路由，AppKit 命中链不下行进入内部滚动机构 → 条件恒 false。**这是起点错了，不是内部滚动机构不存在**——拖拽滚动排查（macOS 15 实测）证明 SwiftUI ScrollView 内部是真实 NSView 链 `DocumentView > NSClipView > HostingScrollView`（NSScrollView 私有子类）。

新探针换起点：从抽屉窗口的 `contentView`（宿主拥有）**向下 DFS 子树枚举**，收集所有 `NSScrollView`/`NSClipView`，判定"光标落在其可见区内 ∧ documentView 横向溢出视口"。不经过 hitTest，与 SwiftUI 事件接管无关。让路判据变为 **AppKit 实测真值**，`BlockScrollUsage` 静态声明保留为门控与逃生舱，无任何插件上报、无任何插件改动。

## 改动清单

### 1. 新文件 `Sources/NotchCenter/DrawerScrollProbe.swift`

```swift
@MainActor enum DrawerScrollProbe {
    /// "没找到 → 不让路"这条反向推断只在实测过内部结构的系统（macOS 15+）启用；
    /// 更早系统探针可能全盲，只信任正向结果（找到 → 让路）。
    static let refinesNegativeResult = ProcessInfo.processInfo
        .isOperatingSystemAtLeast(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    /// 光标下是否存在实际可横向滚动的 NSScrollView/NSClipView（子树枚举，不依赖命中链）。
    static func hasHorizontalOverflowUnderCursor(in window: NSWindow, cursorWindowPoint: NSPoint) -> Bool
}
```

- DFS `window.contentView` 子树；候选 = `NSScrollView`（主）+ 带 `documentView` 的 `NSClipView`（次，兜更早系统结构）。
- 命中条件：`candidate.convert(candidate.bounds, to: nil).contains(cursorWindowPoint)` ∧ 溢出（`NSScrollView`: `documentView.frame.width > documentVisibleRect.width + 1`；`NSClipView`: `documentView.frame.width > bounds.width + 1`）。ε=1pt 防取整误报（误报会让未满货架重新吞切页，宁可偏严）。
- 每次滚动事件现查（无缓存→无失效 bug）：子树仅数百节点、且只在光标下元素为 `.horizontal` 时才走，微秒级。
- 诊断日志：`NOTCHCENTER_SCROLL_PROBE_LOG=1` 时打印候选数/类名/frame/判定（沿 NOTCHCENTER_* 诊断惯例）。

### 2. 让路判据重写（`NotchPanelContent.swift:486-491`）

```swift
if let window = event.window,
   let element = drawerElement(at: window.convertPoint(toScreen: event.locationInWindow)) {
    switch element.scrollUsage {
    case .none:
        break                       // 静态卡片：不消费横向增量，照常切页（不探针）
    case .always:
        yieldToBlock()              // 无条件让路：探针看不见的非 ScrollView 横向手势
    case .horizontal:
        let scrollable = DrawerScrollProbe.hasHorizontalOverflowUnderCursor(
            in: window, cursorWindowPoint: event.locationInWindow)
        if scrollable || !DrawerScrollProbe.refinesNegativeResult {
            yieldToBlock()          // 探针盲区系统回落旧静态行为（兼容）
        }
    }
}
```
（`yieldToBlock()` = 现有 `drawerScrollTracker.reset()` + `endDrawerSwipe(commit: false, offset: 0)` + return；会话期漂移到可滚块上取消会话的语义不变。）

### 3. Kit：`BlockScrollUsage` 加 `case always`（`NotchBlock.swift:64-70`）

- `.horizontal` 语义改为"探针核实后让路"（官方 Scratchpad 声明**不变**，空/未满自动放行）；新增 `.always` = 无条件让路，给探针看不见的第三方自定义横向手势块当逃生舱。
- 更新枚举 doc 注释（旧"文档视图宽于视口"探针句替换为子树枚举方案）。已核实全部消费点只有 `== .horizontal` 比较（无穷举 switch），加 case 安全；实现时再 grep 复核一遍。

### 4. 测试：新 `Tests/NotchCenterTests/DrawerScrollProbeTests.swift`

用真实 AppKit 视图树构造（先例 `TransparentHitHostingViewTests`，标 `@MainActor`）：宽文档溢出→true；未溢出→false；光标在 frame 外→false；`NSClipView` 路径；`documentView == nil`→false；纵向-only 溢出（高窄文档）→false；ε 边界（+0.5 → false、+2 → true）；嵌套 scroll view。SwiftUI 内部结构无法单测，靠真机日志验证。

### 5. AGENTS.md 同步（必须，否则未来协作者会把方案"修"回去）

- 滑动切页 bullet 中"勿改回探针方案"改写为新不变量：让路判据 = 声明 ∧ **子树枚举探针**（`window.contentView` 向下 DFS，光标在内 + 横向溢出）；**命中链 walk 仍然禁**（hitTest 到不了内部滚动机构，恒 false）；反向推断仅 macOS 15+；`NOTCHCENTER_SCROLL_PROBE_LOG` 诊断；`.always` 逃生舱。
- 工程结构清单加 `DrawerScrollProbe.swift`；测试清单加 `DrawerScrollProbeTests`。

## 验证

`swift build` → `swift test --filter DrawerScrollProbe` → 全量 `swift test`。真机（**先杀旧实例**）：`NOTCHCENTER_SCROLL_PROBE_LOG=1 ./Scripts/build.sh run`，依次复现：空/未满货架轻扫 → 日志"无候选/无溢出"、切页正常；塞满溢出后轻扫 → 滚动文件架不切页；笔记等 `.none` 块行为不变；日志同时验证子树里确实能枚举到内部滚动机构（核心假设在 macOS 15.6 上落地）。

## 已接受的风险（明确列出）

- 依赖 SwiftUI 私有内部结构，未来 macOS 更新可能无声改变 → 探针日志快速定位、`.always` 逃生舱、未验证系统只信任正向结果。
- 单测覆盖不到 SwiftUI 内部，真机日志是最后防线。

## 出界项

边缘回链切页；紧凑区托盘图标默认声明问题；`onScrollGeometryChange`（macOS 15+ API）。