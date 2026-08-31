import SwiftUI

/// 顶部圆角遮罩形状（贴近刘海观感）。
struct TopAttachedRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isCursorActive = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, isEnabled, !isCursorActive {
                    NSCursor.pointingHand.push()
                    isCursorActive = true
                } else if (!hovering || !isEnabled), isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onDisappear {
                if isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
    }
}

extension View {
    func pointingHandCursor(isEnabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

// MARK: - 编辑模式圆形按钮（组件默认圆形按钮）

/// 编辑模式圆形控件的外观基元：白色符号置于半透明圆形底衬上，发丝描边，
/// 高亮时整体提亮。样式基准是抽屉块右下角的缩放握把——设置 / 移除按钮
/// （`EditCircleButton`）与握把手势层各自复用同一份外观。
struct EditCircleBadge: View {
    let systemImage: String
    var isHighlighted = false
    /// 圆形直径；紧凑区编辑角标用小号适配 28pt 槽位。
    var diameter: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: diameter * 0.41, weight: .bold))
            .foregroundStyle(.white.opacity(isHighlighted ? 0.95 : 0.7))
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(.white.opacity(isHighlighted ? 0.28 : 0.14))
                    .overlay {
                        Circle()
                            .stroke(
                                .white.opacity(isHighlighted ? 0.55 : 0.25),
                                lineWidth: 1
                            )
                    }
            }
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }
}

/// 编辑模式统一圆形按钮：设置 / 移除等点击入口的组件默认样式，
/// 悬停增亮并切换手型光标。
struct EditCircleButton: View {
    let systemImage: String
    let helpText: String
    var diameter: CGFloat = 22
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            EditCircleBadge(systemImage: systemImage, isHighlighted: isHovering, diameter: diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
        .help(helpText)
    }
}

// MARK: - 编辑模式符号按钮（小目标角标的组件默认样式）

/// 贴在 22–28pt 小目标上的编辑角标：SF Symbols 实心白色符号（`gearshape.fill`
/// / `xmark.circle.fill`），无圆形底衬，靠黑色投影与内容分离，悬停提亮。
///
/// 紧凑区图标与分页胶囊的角标共用这一份外观（两者样式必须一致，不要在调用方
/// 各自重画）。`side` 是按钮边长（也是命中框），符号按 `fontSize` 居中。
struct EditGlyphButton: View {
    let systemImage: String
    let helpText: String
    var fontSize: CGFloat = 11
    var side: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBrighten()
        .shadow(color: .black.opacity(0.55), radius: 2)
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

// MARK: - 无底衬按钮悬停提亮

/// 无底衬按钮（图标裸露，如紧凑区编辑角标）的悬停提亮：内容 brightness
/// 提升一档。与激活态高亮（如 TopBarButton 的底衬增亮）相比刻意更暗，
/// 保持「悬停 < 激活」的层级惯例；动画沿用项目统一的 easeOut 0.12。
private struct HoverBrightenModifier: ViewModifier {
    @State private var isHovering = false
    let amount: Double

    func body(content: Content) -> some View {
        content
            .brightness(isHovering ? amount : 0)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// 悬停时内容提亮 `amount`（默认 0.12，比激活态高亮暗一档）。
    func hoverBrighten(amount: Double = 0.12) -> some View {
        modifier(HoverBrightenModifier(amount: amount))
    }
}