import Combine
import SwiftUI

// MARK: - 抽屉内浮层确认（卡片覆盖式）

// 替代 confirmationDialog / NSAlert 做重动作确认：模态弹窗是独立 key 窗口，
// 鼠标移过去的瞬间宿主判定「指针已离开抽屉/条带」而收回，确认根本完不成。
// 浮层直接叠在原内容上方，鼠标全程不出宿主窗口、无焦点变更（DESIGN.md §1
// 「不抢焦点」）。两个形态：
// - `InlineConfirmOverlay`：半透明遮罩盖住整卡 + 居中面板——抽屉块卡内确认。
// - `InlineConfirmPanel`：仅面板本体——放进 `BlockPopover` 浮窗卡片用（快速区
//   图标下方垂出的确认浮窗）。
//
// 面板只收文案与回调、不做本地化（调用方传 L(...) 结果）。遮罩形态监听宿主
// 「抽屉开始收起」通知自动取消：块视图 orderOut 后仍存活（onDisappear 不可靠），
// 不自动复位会留下一次幽灵确认层。

/// 确认面板本体：标题 + 说明 + 「取消 / 确认」按钮行。
public struct InlineConfirmPanel: View {
    private let title: String
    private let message: String?
    private let confirmTitle: String
    private let cancelTitle: String
    private let onConfirm: () -> Void
    private let onCancel: () -> Void

    public init(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        cancelTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                InlineConfirmButton(
                    title: cancelTitle,
                    baseFill: .white.opacity(0.06),
                    hoverFill: .white.opacity(0.1),
                    foreground: .white.opacity(0.75),
                    action: onCancel
                )
                InlineConfirmButton(
                    title: confirmTitle,
                    baseFill: Color.red.opacity(0.18),
                    hoverFill: Color.red.opacity(0.28),
                    foreground: Color.red.opacity(0.95),
                    action: onConfirm
                )
            }
        }
        .padding(12)
    }
}

/// 确认面板里的圆角按钮（DESIGN.md §3 圆角 7 / §4 悬停极短 easeOut）。
private struct InlineConfirmButton: View {
    let title: String
    let baseFill: Color
    let hoverFill: Color
    let foreground: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? hoverFill : baseFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled(true)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// 卡片覆盖式确认层：遮罩挡住整卡内容（点击即取消）+ 居中面板 spring 弹入。
/// 圆角默认对齐 `BlockCard`（10），调用方整卡 overlay 挂载。
public struct InlineConfirmOverlay: View {
    private let title: String
    private let message: String?
    private let confirmTitle: String
    private let cancelTitle: String
    private let cornerRadius: CGFloat
    private let onConfirm: () -> Void
    private let onCancel: () -> Void

    /// false → 缩小且全透明（首帧上屏态）；置 true 触发放大弹入。
    @State private var popped = false

    public init(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        cancelTitle: String,
        cornerRadius: CGFloat = 10,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.cornerRadius = cornerRadius
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            InlineConfirmPanel(
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                cancelTitle: cancelTitle,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
            .frame(maxWidth: 240)
            .scaleEffect(popped ? 1 : 0.94)
            .opacity(popped ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .transition(.opacity)
        .onAppear {
            // 下一帧起跳：确保缩小态先真正上屏，弹入动画可见。
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    popped = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCenterDrawerDidCollapse)) { _ in
            onCancel()
        }
    }
}
