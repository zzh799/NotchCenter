import AppKit

// MARK: - 滑动切页让路探针

/// 滚动事件时刻核实"光标下是否真有可横向滚动的滚动视图"。
///
/// 让路判据（`NotchPanelContent.handleDrawerScroll`）的动态部分：块经
/// `BlockScrollUsage` 声明会消费横向滑动后，宿主再用 AppKit 实测核实内容
/// 确实横向溢出——空/未满的横向 `ScrollView`（如暂存区文件架）放行切页。
///
/// 探测方式是**子树枚举**：从抽屉窗口的 `contentView` 向下 DFS 收集
/// `NSScrollView`（及不在任何 `NSScrollView` 内、带 documentView 的
/// `NSClipView`，兜更早系统的内部结构），逐个判定"光标落在可见区内 ∧
/// documentView 横向溢出视口"。起点必须 contentView 而非命中链——SwiftUI
/// 在 `NSHostingView` 层接管事件路由，`hitTest` 永远到不了内部滚动机构，
/// 旧的"沿 superview 向上找 NSScrollView"实测恒 false（勿改回）。SwiftUI
/// `ScrollView` 内部是真实 NSView 链 `DocumentView > NSClipView >
/// HostingScrollView`（私有 NSScrollView 子类，macOS 15 实测），子树枚举
/// 必然访问到，与事件路由无关。
///
/// 每次滚动事件现查、无缓存：抽屉窗口子树仅数百节点，且只在光标下元素
/// 声明 `.horizontal` 时才走，微秒级；不缓存就永远不会拿着过期视图树判定。
@MainActor
enum DrawerScrollProbe {
    /// documentView 相对视口的横向溢出余量下限（pt）。取 1 防 1px 取整
    /// 误报——误报会让未满的文件架重新吞掉切页，宁可偏严。
    private static let overflowEpsilon: CGFloat = 1

    /// "没找到 → 不让路"这条反向推断只在实测过 SwiftUI 内部结构的系统
    /// （macOS 15+）启用；更早系统探针可能全盲（内部没有可枚举的
    /// NSScrollView/NSClipView），此时只信任正向结果（找到 → 让路），
    /// "没找到"回落旧的静态让路行为。
    static let refinesNegativeResult = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))

    /// 诊断日志开关（`NOTCHCENTER_SCROLL_PROBE_LOG=1`）：打印候选视图、
    /// 溢出判定与最终结论，用于真机核实子树里能否枚举到内部滚动机构。
    private static let loggingEnabled =
        ProcessInfo.processInfo.environment["NOTCHCENTER_SCROLL_PROBE_LOG"] == "1"

    static func hasHorizontalOverflowUnderCursor(in window: NSWindow, cursorWindowPoint: NSPoint) -> Bool {
        guard let root = window.contentView else { return false }
        return hasHorizontalOverflowUnderCursor(root: root, cursorWindowPoint: cursorWindowPoint)
    }

    /// 以 `root` 为根子树枚举滚动容器，判定光标下是否存在横向溢出者。
    /// `cursorWindowPoint` 是窗口基础坐标（`NSEvent.locationInWindow`）。
    static func hasHorizontalOverflowUnderCursor(root: NSView, cursorWindowPoint: NSPoint) -> Bool {
        var candidates: [NSView] = []
        enumerateScrollContainers(from: root, insideScrollView: false, into: &candidates)
        let verdict = candidates.contains { candidate in
            isUnderCursor(candidate, cursorWindowPoint) && hasHorizontalOverflow(candidate)
        }
        if loggingEnabled {
            logVerdict(root: root, cursorWindowPoint: cursorWindowPoint, candidates: candidates, verdict: verdict)
        }
        return verdict
    }

    // MARK: 子树枚举

    /// DFS 收集滚动容器：`NSScrollView` 全收；`NSClipView` 只在**不在**任何
    /// `NSScrollView` 内时收（有 ScrollView 包着时重复判定同一份文档，且
    /// 兜底场景针对的正是"clip view 存在而外层 ScrollView 缺席"的结构）。
    private static func enumerateScrollContainers(
        from view: NSView,
        insideScrollView: Bool,
        into candidates: inout [NSView]
    ) {
        guard !view.isHiddenOrHasHiddenAncestor else { return }
        let nowInside = insideScrollView || view is NSScrollView
        if view is NSScrollView {
            candidates.append(view)
        } else if let clipView = view as? NSClipView, !insideScrollView, clipView.documentView != nil {
            candidates.append(view)
        }
        for child in view.subviews {
            enumerateScrollContainers(from: child, insideScrollView: nowInside, into: &candidates)
        }
    }

    private static func isUnderCursor(_ candidate: NSView, _ cursorWindowPoint: NSPoint) -> Bool {
        candidate.bounds.contains(candidate.convert(cursorWindowPoint, from: nil))
    }

    // MARK: 溢出判定

    private static func hasHorizontalOverflow(_ candidate: NSView) -> Bool {
        if let scrollView = candidate as? NSScrollView {
            return documentWidth(scrollView.documentView) > scrollView.documentVisibleRect.width + overflowEpsilon
        }
        if let clipView = candidate as? NSClipView {
            return documentWidth(clipView.documentView) > clipView.bounds.width + overflowEpsilon
        }
        return false
    }

    /// documentView 宽度按 frame 计（滚动只改原点不改尺寸），缺省按不可滚处理。
    private static func documentWidth(_ documentView: NSView?) -> CGFloat {
        documentView?.frame.width ?? 0
    }

    // MARK: 诊断日志

    private static func logVerdict(
        root: NSView,
        cursorWindowPoint: NSPoint,
        candidates: [NSView],
        verdict: Bool
    ) {
        let lines = candidates.map { candidate -> String in
            let under = isUnderCursor(candidate, cursorWindowPoint)
            let overflow = hasHorizontalOverflow(candidate)
            let frame = candidate.convert(candidate.bounds, to: root)
            return String(
                format: "    %@ frame(in-root)=%.0f,%.0f %.0fx%.0f under=%d overflow=%d",
                NSStringFromClass(type(of: candidate)),
                frame.minX, frame.minY, frame.width, frame.height,
                under ? 1 : 0, overflow ? 1 : 0
            )
        }
        NSLog(
            "[ScrollProbe] cursor=%.0f,%.0f candidates=%d verdict=%d%@",
            cursorWindowPoint.x, cursorWindowPoint.y,
            candidates.count, verdict ? 1 : 0,
            lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
        )
    }
}
