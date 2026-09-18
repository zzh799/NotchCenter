import SwiftUI

// MARK: - 块卡片壳与交互触发器（框架级统一实现）
//
// 视觉与交互彻底分离，插件按需组合：
// - `BlockCard`：纯视觉表面——近白半透明填充 + 白色发丝描边（DESIGN.md §2.1/§2.3）、
//   可选悬停微亮，撑满宿主分配的网格区域；不含任何手势。
// - `blockPopoverTrigger(onTap:onLongPress:)`：按需叠加的交互层——长按弹浮窗 +
//   可选点击动作；不挂载则完全不参与。
//
// 所有外观常量集中在本文件。按压反馈由触发器的 overlay 叠加实现（卡片壳自身
// 不感知按压态），按底色分三档：`standard` 配平到单层绘制时的观感（描边
// 0.09 + 0.12 ≈ 0.20、填充 +0.03 ≈ 0.055）；`emphasized` 供按压落在整卡上的
// 「整卡即唯一按钮」卡片加强；`dimmed` 供自带浅底的卡片（白叠加在浅底上零对比）。

/// 卡片外观常量（DESIGN.md §2.1 近白半透明层级 / §2.3 发丝描边）。
/// 数值以 `NotchTokens` 为唯一事实源，此处仅做组件级别名。
enum BlockCardMetrics {
    /// 连续圆角半径（DESIGN.md §3 圆角统一偏好 `.continuous`）。
    static let cornerRadius: CGFloat = NotchTokens.Radius.card
    /// 悬停反馈时长（DESIGN.md §4：悬停态 easeOut 0.10–0.13s）。
    static let hoverAnimation = NotchTokens.Motion.hover
    /// `standard` 档叠加增量：与卡片常态合成后 ≈ 强调态（填充 0.055 / 描边 0.20）。
    static let standardPressFillOpacity: CGFloat = 0.03
    static let standardPressStrokeOpacity: CGFloat = 0.12
    /// `emphasized` 档叠加增量：合成后 0.085 / 0.29，明显强于强调态——
    /// 按压必须是白 alpha 阶梯里最强的一档（按下 > 强调 > 悬停 > 常态）。
    static let emphasizedPressFillOpacity: CGFloat = 0.06
    static let emphasizedPressStrokeOpacity: CGFloat = 0.20
    /// `dimmed` 档（浅底）：黑叠加压暗，不叠描边——描边在浅底上同样不可见。
    static let dimmedPressFillOpacity: CGFloat = 0.14
}

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
        if highlighted { return NotchTokens.Surface.fillHighlighted }
        if isHovering { return NotchTokens.Surface.fillHover }
        return NotchTokens.Surface.fill
    }

    private var strokeColor: Color {
        // 强调描边 0.16 是按压/拖入高亮的配平值（介于常态 0.09 与
        // chip 选中 0.20 之间），仅此组件使用，不单列 token。
        if highlighted { return Color.white.opacity(0.16) }
        return NotchTokens.Hairline.drawerEdge
    }
}

// MARK: - 长按浮窗触发器

/// 按压反馈档位（`blockPopoverTrigger` 的 `pressFeedback` 参数）。
/// 底色深浅决定叠加方向：深底提亮看得见，浅底（如开启态紧凑服务卡的白底）
/// 只有压暗看得见——白叠加在浅底上零对比。
public enum BlockPressFeedback: Sendable, Equatable {
    /// spec 配平档：叠加后 ≈ 强调态（填充 0.055 / 描边 0.20），与 `highlighted` 同值。
    case standard
    /// 加强档（深底）：叠加后 0.085 / 0.29，用于「整卡即唯一按钮」的卡片——
    /// 这类卡片没有开关等子控件，按压是唯一的即时反馈。
    case emphasized
    /// 浅底档：黑叠加压暗（无描边），用于卡片自身画了浅色底的场合。
    case dimmed
}

/// 触发器的按压分类参数（独立纯值，`BlockCardTriggerTests` 覆盖）。
public enum BlockTapClassifier {
    /// 长按浮窗的最短按压时长。
    public static let longPressDuration: TimeInterval = 0.2
    /// 超过该位移视为拖动（对齐 `LongPressGesture` 默认 maximumDistance 的容忍度），
    /// 既不算 tap 也不再弹浮窗（滚动意图）。
    public static let movementTolerance: CGFloat = 10

    /// 一次「按下 → 松开」应归类为点击吗？
    /// 快速、未移动、且长按尚未触发才成立；长按后的松手必须被抑制，
    /// 否则松手瞬间会误触 onTap（如误开网页）。
    public static func isTap(
        heldDuration: TimeInterval,
        translation: CGSize,
        longPressFired: Bool
    ) -> Bool {
        let moved = hypot(translation.width, translation.height) > movementTolerance
        return heldDuration < longPressDuration && !moved && !longPressFired
    }
}

public extension View {
    /// 块交互层（按需叠加）：按住满 0.2s 的瞬间即回调 `onLongPress`，
    /// **无需等鼠标释放**；两个回调都携带块在宿主窗口坐标系中的 frame
    /// （SwiftUI `.global` 空间），供 `BlockPopover.present(anchoredTo:)`
    /// 定位——点击即弹浮窗的块（如暂存区清空确认）与长按弹浮窗的块
    /// 走同一套锚点追踪。按压期间在内容上方叠加增亮覆盖，提示浮窗即将
    /// 弹出；提前松手/拖走（滚动意图）自动复位。
    ///
    /// `onTap` 为可选点击动作，长按期间自动抑制（保住“开关等子控件
    /// 自行消费点击”的语义）。挂在整卡上（含背景区）。
    ///
    /// `cornerRadius` 只影响按压增亮覆盖的形状，默认对齐 `BlockCard` 圆角
    /// （`BlockCardMetrics.cornerRadius` = 10；公开签名处只能用字面值）；
    /// 复用到非 BlockCard 的圆角子元素（如列表行圆角 7）时传入自身圆角。
    ///
    /// `pressFeedback` 选按压反馈档位（见 `BlockPressFeedback`）：默认 `standard`
    /// 与既有观感一致；卡片自带浅色底的场合必须传 `.dimmed`。
    ///
    /// 实现说明：整条交互由单个 `DragGesture(minimumDistance: 0)` 驱动，
    /// 不用 `TapGesture`——它与 simultaneous 失败长按并存时在真机上不触发
    /// （DSH/Calibre「点击开网页」失效的根因），而 DragGesture 管线与
    /// 缩放握把/滚动探针同路，行为可靠。分类阈值见 `BlockTapClassifier`。
    func blockPopoverTrigger(
        onTap: ((_ frameInWindow: CGRect) -> Void)? = nil,
        onLongPress: @escaping (_ frameInWindow: CGRect) -> Void,
        cornerRadius: CGFloat = 10,
        pressFeedback: BlockPressFeedback = .standard
    ) -> some View {
        modifier(BlockPopoverTriggerModifier(
            onTap: onTap,
            onLongPress: onLongPress,
            cornerRadius: cornerRadius,
            pressFeedback: pressFeedback
        ))
    }
}

private struct BlockPopoverTriggerModifier: ViewModifier {
    let onTap: ((CGRect) -> Void)?
    let onLongPress: (CGRect) -> Void
    /// 按压增亮覆盖的圆角（对齐挂载对象自身圆角；见 View 扩展文档）。
    let cornerRadius: CGFloat
    /// 按压反馈档位（叠加方向与强度；见 `BlockPressFeedback`）。
    let pressFeedback: BlockPressFeedback

    /// 块在宿主窗口坐标系中的 frame（GeometryReader 实时捕获），用于浮窗定位。
    @State private var frameInWindow: CGRect?
    /// 长按进行中：背景微亮提示浮窗即将弹出。普通 @State 手动维护；
    /// 若手势被系统静默接管（无 onEnded），残留的增亮会在下一次按压开始时复位。
    @State private var isPressing = false
    /// 本次按压的起点时刻；nil 表示当前没有按压。同时充当长按定时器的
    /// `.task(id:)` 身份——置回 nil 即自动取消待触发的浮窗。
    @State private var pressStartDate: Date?
    /// 本次按压是否已触发过长按浮窗（抑制其后的松手误判为 tap）。
    @State private var longPressFired = false

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
            // 按压反馈覆盖（有意叠层而非改写卡片壳常量，见文件头注释）。
            .overlay {
                if isPressing {
                    pressOverlay
                }
            }
            .animation(BlockCardMetrics.hoverAnimation, value: isPressing)
            // 长按定时器：按压开始（pressStartDate 变为非 nil）后等满 0.2s，
            // 仍在同一按压中 → 弹浮窗。松手/拖走把 pressStartDate 置回 nil，
            // 任务身份变化即自动取消，无需手管 DispatchWorkItem。
            .task(id: pressStartDate) {
                guard pressStartDate != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(BlockTapClassifier.longPressDuration))
                } catch {
                    return // 已被取消（松手/拖走/新按压）
                }
                guard pressStartDate != nil, !longPressFired else { return }
                longPressFired = true
                if let frameInWindow {
                    onLongPress(frameInWindow)
                }
            }
            // 开关等子控件自行消费点击的语义靠 simultaneous 保住：
            // 卡片层手势不独占事件流，子控件命中时 SwiftUI 优先派发给它们。
            .simultaneousGesture(pressGesture)
    }

    /// 按压覆盖：叠加在卡片壳之上，合成后即「按下态」的观感（各档取值见
    /// `BlockCardMetrics` 与 `BlockPressFeedback`）；不参与命中测试，避免
    /// 遮挡卡片内子控件的点击。
    private var pressOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fillColor.opacity(fillOpacity))
            if let strokeOpacity {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    /// 按压覆盖的填充色：深底档提亮，浅底档压暗。
    private var fillColor: Color {
        switch pressFeedback {
        case .standard, .emphasized: return .white
        case .dimmed: return .black
        }
    }

    private var fillOpacity: Double {
        switch pressFeedback {
        case .standard: return BlockCardMetrics.standardPressFillOpacity
        case .emphasized: return BlockCardMetrics.emphasizedPressFillOpacity
        case .dimmed: return BlockCardMetrics.dimmedPressFillOpacity
        }
    }

    /// 浅底档不叠描边（浅底上不可见，只会让边缘发白）。
    private var strokeOpacity: Double? {
        switch pressFeedback {
        case .standard: return BlockCardMetrics.standardPressStrokeOpacity
        case .emphasized: return BlockCardMetrics.emphasizedPressStrokeOpacity
        case .dimmed: return nil
        }
    }

    /// 单手势驱动整条交互：
    /// - 按下即点亮按压态并记录起点（同时启动上方 `.task` 定时器）；
    /// - 提前松手且未移动未触发过长按 → tap；
    /// - 位移超出容忍（滚动意图）→ 清空起点取消浮窗并熄灭按压态。
    /// 坐标空间用 .global：平移量在窗口坐标系度量，不受块自身动画位移干扰
    ///（同缩放握把的教训，见 AGENTS.md）。
    ///
    /// 已知边界：手势若被系统静默接管（无 onEnded 的极端场景），残留状态会
    /// 吞掉下一次点击后自愈（onEnded 兜底复位），仅此一次，无视觉副作用。
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pressStartDate == nil {
                    pressStartDate = Date()
                    isPressing = true
                    longPressFired = false
                } else if hypot(value.translation.width, value.translation.height)
                    > BlockTapClassifier.movementTolerance {
                    // 拖出容忍范围：滚动意图——清空起点取消待触发的浮窗并熄灭
                    // 按压态（与旧 LongPressGesture 超出 maximumDistance 即失败一致；
                    // 起点为空也天然排除了 tap 分类）。
                    pressStartDate = nil
                    isPressing = false
                }
            }
            .onEnded { value in
                defer { resetPressState() }
                guard let start = pressStartDate else { return }
                let held = Date().timeIntervalSince(start)
                if BlockTapClassifier.isTap(
                    heldDuration: held,
                    translation: value.translation,
                    longPressFired: longPressFired
                ) {
                    // frame 由背景 GeometryReader 持续追踪，点击时必然已就位；
                    // 兜底 .zero 只防理论竞态（浮窗会锚定到窗口原点而非误闭包崩溃）。
                    onTap?(frameInWindow ?? .zero)
                }
            }
    }

    private func resetPressState() {
        pressStartDate = nil
        isPressing = false
        longPressFired = false
    }
}
