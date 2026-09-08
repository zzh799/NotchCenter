import AppKit
import SwiftUI

// MARK: - 统一圆角按钮基体（DESIGN.md §9「统一按钮样式」）
//
// 所有圆角按钮共用 `RoundedHoverButtonBody`：常态/悬停/按下三态的「白底 alpha」
// 与「前景白 alpha」由各自 ButtonStyle 注入，圆角固定 NotchTokens.Radius.button、
// `.continuous`，按下与悬停走 NotchTokens.Motion.hover 极短 easeOut，并统一手型
// 光标（含禁用态释放）。原实现位于 NotesPlugin（NotesButtonStyles），迁移至 Kit
// 供宿主与插件复用；新增圆角按钮请复用本基体而非自绘。

/// 圆角按钮的三态视觉基体：白底/白前景的 alpha 由注入值决定，宿主与插件通过
/// 各自 `ButtonStyle` 包装调用（示例：NotesPlugin 的 MarkdownToolbarButtonStyle）。
public struct RoundedHoverButtonBody: View {
    public let configuration: ButtonStyle.Configuration
    public let font: Font?
    public let normalOpacity: CGFloat
    public let hoverOpacity: CGFloat
    public let pressedOpacity: CGFloat
    public let strokeOpacity: CGFloat
    public let foregroundOpacity: CGFloat
    public let hoverForegroundOpacity: CGFloat
    public let pressedForegroundOpacity: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    public init(
        configuration: ButtonStyle.Configuration,
        font: Font?,
        normalOpacity: CGFloat,
        hoverOpacity: CGFloat,
        pressedOpacity: CGFloat,
        strokeOpacity: CGFloat,
        foregroundOpacity: CGFloat,
        hoverForegroundOpacity: CGFloat? = nil,
        pressedForegroundOpacity: CGFloat
    ) {
        self.configuration = configuration
        self.font = font
        self.normalOpacity = normalOpacity
        self.hoverOpacity = hoverOpacity
        self.pressedOpacity = pressedOpacity
        self.strokeOpacity = strokeOpacity
        self.foregroundOpacity = foregroundOpacity
        self.hoverForegroundOpacity = hoverForegroundOpacity ?? foregroundOpacity
        self.pressedForegroundOpacity = pressedForegroundOpacity
    }

    public var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(currentForeground)
            .background(
                RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                    .fill(.white.opacity(currentBackgroundOpacity))
            )
            .overlay {
                RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                    .stroke(.white.opacity(strokeOpacity), lineWidth: 1)
            }
            .animation(NotchTokens.Motion.hover, value: isHovering)
            .animation(NotchTokens.Motion.hover, value: configuration.isPressed)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
            .pointingHandCursor(isEnabled: isEnabled)
    }

    /// 禁用态前景就近取 `Foreground.placeholder`（原 0.22 与 0.24 阶内无差，
    /// 避免为禁用图标单开取值）。
    private var currentForeground: Color {
        guard isEnabled else { return NotchTokens.Foreground.placeholder }
        if configuration.isPressed {
            return .white.opacity(pressedForegroundOpacity)
        }
        return .white.opacity(isHovering ? hoverForegroundOpacity : foregroundOpacity)
    }

    private var currentBackgroundOpacity: CGFloat {
        guard isEnabled else { return 0 }
        if configuration.isPressed {
            return pressedOpacity
        }
        return isHovering ? hoverOpacity : normalOpacity
    }
}

// MARK: - 手型光标（本文件私有实现，含禁用态释放）

private extension View {
    func pointingHandCursor(isEnabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(isEnabled: isEnabled))
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
