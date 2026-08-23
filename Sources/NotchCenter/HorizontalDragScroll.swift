import AppKit
import SwiftUI

// MARK: - 横向拖动滚动容器

#if DEBUG
/// `NOTCHCENTER_DRAGSCROLL_LOG=1`：打印探针命中链路与拖动事件管线
/// （translation → 目标位置 → clipView 实际落点），用于诊断"拖不动"。
enum DragScrollProbeLog {
    static let isEnabled = ProcessInfo.processInfo.environment["NOTCHCENTER_DRAGSCROLL_LOG"] == "1"

    static func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("drag-scroll %@", message)
    }
}
#endif

/// macOS 的 SwiftUI 横向 ScrollView 只响应滚轮/触控板,不支持按住鼠标拖动。
/// 这里保留 ScrollView(滚轮路径零改动),在内容里埋零尺寸 NSView 探针沿
/// superview 链取到底层 NSScrollView,拖动手势直接平移 clipView 的滚动
/// 位置(`scroll(to:)` + `reflectScrolledClipView`,与 NotesPlugin 里
/// EditorInteractionState 的做法同模式,无动画、像素级跟手)。找不到
/// NSScrollView 时拖动优雅降级为无操作,滚轮不受影响。
struct HorizontalDragScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    /// 稳定持有探针找到的 NSScrollView(@State 持有引用类型,实例跨渲染不换)。
    @State private var scrollViewHolder = ScrollViewHolder()
    /// 拖动开始时的滚动位置(拖动期间持有,结束清空)。
    @State private var dragStartX: CGFloat?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .background(ScrollViewAccessor(holder: scrollViewHolder))
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard let scrollView = scrollViewHolder.scrollView else {
                        #if DEBUG
                        DragScrollProbeLog.log("changed: probe miss, translation=\(value.translation.width)")
                        #endif
                        return
                    }
                    let clipView = scrollView.contentView
                    let startX = dragStartX ?? clipView.bounds.origin.x
                    dragStartX = startX
                    let target = HorizontalDragScrollMath.clamped(
                        startX - value.translation.width,
                        max: clipView.documentRect.width - clipView.bounds.width
                    )
                    clipView.scroll(to: NSPoint(x: target, y: clipView.bounds.origin.y))
                    scrollView.reflectScrolledClipView(clipView)
                    #if DEBUG
                    DragScrollProbeLog.log(
                        "changed: start=\(startX) t=\(value.translation.width) target=\(target) origin=\(clipView.bounds.origin.x) doc=\(clipView.documentRect.width) viewport=\(clipView.bounds.width)"
                    )
                    #endif
                }
                .onEnded { value in
                    #if DEBUG
                    DragScrollProbeLog.log("ended: t=\(value.translation.width)")
                    #endif
                    dragStartX = nil
                }
        )
    }
}

/// 滚动位置钳制（独立于泛型视图,便于测试）：负值归 0,超出上限归上限;
/// 内容窄于视口时上限为负,一律固定为 0(不可滚动)。
enum HorizontalDragScrollMath {
    static func clamped(_ x: CGFloat, max upper: CGFloat) -> CGFloat {
        min(max(x, 0), max(0, upper))
    }
}

/// 沿 superview 链定位 NSScrollView 的引用载体(weak,不延长视图生命期)。
final class ScrollViewHolder {
    weak var scrollView: NSScrollView?
}

/// 埋在 ScrollView 内容里的零尺寸探针:挂到视图树后向上找最近的 NSScrollView。
/// 挂载可能早于祖先链就绪(viewDidMoveToSuperview 时上层容器未必已连接),
/// 故 window 挂载时再走一次;两次都未命中则保持 nil(拖动降级,滚轮不受影响)。
private struct ScrollViewAccessor: NSViewRepresentable {
    let holder: ScrollViewHolder

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(holder: holder)
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private let holder: ScrollViewHolder

        init(holder: ScrollViewHolder) {
            self.holder = holder
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            walkUp(reason: "superview")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            walkUp(reason: "window")
        }

        private func walkUp(reason: String) {
            var chain: [String] = []
            var current: NSView? = superview
            while let view = current {
                chain.append(String(describing: type(of: view)))
                if let scrollView = view as? NSScrollView {
                    holder.scrollView = scrollView
                    #if DEBUG
                    DragScrollProbeLog.log("probe[\(reason)] hit: \(chain.joined(separator: " > "))")
                    #endif
                    return
                }
                current = view.superview
            }
            #if DEBUG
            DragScrollProbeLog.log(
                "probe[\(reason)] miss window=\(window != nil): \(chain.joined(separator: " > "))"
            )
            #endif
        }
    }
}

