import SwiftUI

// MARK: - 块卡片壳与交互触发器（框架级统一实现）
//
// 视觉与交互彻底分离，插件按需组合：
// - `BlockCard`：纯视觉表面——近白半透明填充 + 白色发丝描边（DESIGN.md §2.1/§2.3）、
//   可选悬停微亮，撑满宿主分配的网格区域；不含任何手势。
// - `blockPopoverTrigger(onTap:onLongPress:)`：按需叠加的交互层——长按弹浮窗 +
//   可选点击动作；不挂载则完全不参与。
//
// 所有外观常量集中在本文件。按压增亮由触发器的 overlay 叠加实现（卡片壳自身
// 不感知按压态）：叠加值已配平到单层绘制时的观感——描边 0.09 + 0.12 ≈ 0.20、
// 填充 +0.03 ≈ 0.055。

/// 卡片外观常量（DESIGN.md §2.1 近白半透明层级 / §2.3 发丝描边）。
enum BlockCardMetrics {
    /// 连续圆角半径（DESIGN.md §3 圆角统一偏好 `.continuous`）。
    static let cornerRadius: CGFloat = 10
    /// 悬停反馈时长（DESIGN.md §4：悬停态 easeOut 0.10–0.13s）。
    static let hoverAnimation = Animation.easeOut(duration: 0.12)
}

/// 长按触发浮窗的最短按压时长。
private let popoverLongPressDuration: TimeInterval = 0.2

// MARK: - 卡片壳

/// 抽屉块标准表面：圆角 10 连续，撑满外层容器提案的全部空间
/// （DrawerBlockContainer 已按跨度定尺寸）。纯视觉组件、零手势；
/// `highlighted` 为拖放高亮等强调态；`hoverEffect` 控制悬停微亮
/// （默认关，交互型卡片显式开启）。
public struct BlockCard<Content: View>: View {
    private let highlighted: Bool
    private let hoverEffectEnabled: Bool
    private let content: (Bool) -> Content

    @State private var isHovering = false

    public init(
        highlighted: Bool = false,
        hoverEffect: Bool = false,
        @ViewBuilder content: @escaping (_ isHovering: Bool) -> Content
    ) {
        self.highlighted = highlighted
        self.hoverEffectEnabled = hoverEffect
        self.content = content
    }

    public var body: some View {
        content(isHovering)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: BlockCardMetrics.cornerRadius, style: .continuous)
                    .fill(fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: BlockCardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: BlockCardMetrics.cornerRadius, style: .continuous))
            .onHover { hovering in
                guard hoverEffectEnabled else { return }
                isHovering = hovering
            }
            .animation(hoverEffectEnabled ? BlockCardMetrics.hoverAnimation : nil, value: isHovering)
    }

    /// 白色 alpha 层级（DESIGN.md §2.2）：强调态 > 悬停 > 常态。
    private var fillColor: Color {
        if highlighted { return Color.white.opacity(0.055) }
        if isHovering { return Color.white.opacity(0.04) }
        return Color.white.opacity(0.025)
    }

    private var strokeColor: Color {
        if highlighted { return Color.white.opacity(0.16) }
        return Color.white.opacity(0.09)
    }
}

// MARK: - 长按浮窗触发器

public extension View {
    /// 块交互层（按需叠加）：按住满 0.2s 的瞬间即回调 `onLongPress`，
    /// **无需等鼠标释放**；回调携带块在宿主窗口坐标系中的 frame
    /// （SwiftUI `.global` 空间），供 `BlockPopover.present(anchoredTo:)` 定位。
    /// 按压期间在内容上方叠加增亮覆盖，提示浮窗即将弹出；手势失败
    /// （提前松手/滚动）自动复位。
    ///
    /// `onTap` 为可选点击动作，长按期间自动抑制（保住“开关等子控件
    /// 自行消费点击”的语义）。挂在整卡上（含背景区）。
    func blockPopoverTrigger(
        onTap: (() -> Void)? = nil,
        onLongPress: @escaping (_ frameInWindow: CGRect) -> Void
    ) -> some View {
        modifier(BlockPopoverTriggerModifier(onTap: onTap, onLongPress: onLongPress))
    }
}

private struct BlockPopoverTriggerModifier: ViewModifier {
    let onTap: (() -> Void)?
    let onLongPress: (CGRect) -> Void

    /// 块在宿主窗口坐标系中的 frame（GeometryReader 实时捕获），用于浮窗定位。
    @State private var frameInWindow: CGRect?
    /// 长按进行中：背景微亮提示浮窗即将弹出（GestureState，手势中断自动复位）。
    @GestureState private var isPressing = false

    func body(content: Content) -> some View {
        content
            .background(
                // NSHostingView 里 SwiftUI 的 .global 空间即宿主窗口坐标。
                // 块随抽屉动画/缩放移动时持续更新，长按弹出的锚点始终准确。
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frameInWindow = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            frameInWindow = newFrame
                        }
                }
            )
            // 按压增亮覆盖（有意叠层而非改写卡片壳常量，见文件头注释）。
            .overlay {
                if isPressing {
                    pressOverlay
                }
            }
            .animation(BlockCardMetrics.hoverAnimation, value: isPressing)
            // 手势顺序与既有块一致：长按优先于点击；开关自身消费点击不触发 onTap。
            .simultaneousGesture(longPressGesture)
            .onTapGesture {
                guard !isPressing else { return }
                onTap?()
            }
    }

    /// 配平后的按压覆盖：填充 0.025+0.03≈0.055、描边 0.09+0.12≈0.20；
    /// 不参与命中测试，避免遮挡卡片内子控件的点击。
    private var pressOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BlockCardMetrics.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.03))
            RoundedRectangle(cornerRadius: BlockCardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// 纯 LongPressGesture：不能用 sequenced(before: DragGesture)——onEnded 会
    /// 推迟到第二阶段（拖拽）结束，浮窗变成松手后才弹出。
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: popoverLongPressDuration)
            .onEnded { _ in
                guard let frameInWindow else { return }
                onLongPress(frameInWindow)
            }
            // 按下即点亮按压态；手势失败（提前松手/滚动）自动复位。
            .updating($isPressing) { _, state, _ in state = true }
    }
}
