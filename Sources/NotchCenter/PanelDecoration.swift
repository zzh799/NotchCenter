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

// MARK: - 编辑模式圆形按钮（组件默认圆形按钮样式）

// 设置 / 移除 / 缩放握把等圆形角标的唯一外观实现在 Kit 的
// `IconCircleButton` / `IconCircleBadge`（组件默认圆形按钮，样式基准是抽屉块
// 右下角的缩放握把）——迁移自本文件原 EditCircleButton / EditCircleBadge；
// 宿主调用点见 DrawerBlockContainer / DrawerPageCapsule，这里不再放实现。

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