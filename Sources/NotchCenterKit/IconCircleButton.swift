import AppKit
import SwiftUI

// MARK: - 组件默认圆形按钮（Kit 统一外观基元）
//
// 圆形角标式按钮的唯一外观实现：白色符号置于半透明圆形底衬上、发丝描边，
// 悬停增亮并切换手型光标。样式基准是抽屉块右下角的缩放握把——编辑模式角标
// （设置 / 移除 / 缩放握把）与插件块内的圆形动作按钮（如用量卡右上角刷新）
// 共用同一份外观，任何落位不得各自重画（迁移自宿主 PanelDecoration.swift 的
// EditCircleBadge / EditCircleButton，调用点见 DrawerBlockContainer /
// DrawerPageCapsule / OpenCodeUsageBlockView）。
//
// `IconCircleBadge` 纯视觉（不处理点击/悬停，状态由调用方注入）；
// `IconCircleButton` 是完整按钮（悬停增亮 + 手型光标 + 帮助/可访问性标签）。

/// 组件默认圆形按钮的视觉基元。
public struct IconCircleBadge: View {
    let systemImage: String
    var isHighlighted = false
    /// 圆形直径；小目标（如紧凑区 28pt 槽位）可用小直径适配。
    var diameter: CGFloat = 22

    public init(
        systemImage: String,
        isHighlighted: Bool = false,
        diameter: CGFloat = 22
    ) {
        self.systemImage = systemImage
        self.isHighlighted = isHighlighted
        self.diameter = diameter
    }

    public var body: some View {
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

/// 组件默认圆形按钮：设置 / 移除等圆形角标式点击入口，悬停增亮并切换手型光标。
public struct IconCircleButton: View {
    let systemImage: String
    let helpText: String
    var diameter: CGFloat = 22
    let action: () -> Void

    @State private var isHovering = false

    public init(
        systemImage: String,
        helpText: String,
        diameter: CGFloat = 22,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.helpText = helpText
        self.diameter = diameter
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconCircleBadge(systemImage: systemImage, isHighlighted: isHovering, diameter: diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursorWhileHovering()
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

// MARK: - 手型光标（Kit 内部实现）

/// 悬停切换手型光标的私有实现。宿主同名修饰器（`pointingHandCursor`）仍服务
/// 宿主其余调用点；圆形按钮在 Kit 内自带一份，功能与观感保持一致。
private struct PointingHandCursorModifier: ViewModifier {
    @State private var isCursorActive = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !isCursorActive {
                    NSCursor.pointingHand.push()
                    isCursorActive = true
                } else if !hovering, isCursorActive {
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

private extension View {
    func pointingHandCursorWhileHovering() -> some View {
        modifier(PointingHandCursorModifier())
    }
}