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