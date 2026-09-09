import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（专注计时控制卡）
//
// 规范落点（决策见 docs/agent-notes 2026-09-09-pomodoro-ui-redesign）：卡片壳
// 走 Kit `BlockCard`，圆形控制钮走 `IconCircleButton`，开始按钮走基于
// `RoundedHoverButtonBody` 的主按钮样式；颜色/间距一律 `NotchTokens`，
// 不散写内联透明度。阶段色只出现在状态圆点与进度条（豁免调色板见 PomodoroTheme）。

/// 版式常量：内边距/间距对齐 `Space`，打包期探针
/// （`PomodoroPlugin.pomodoroLayoutProbes`）镜像本组数值。
private enum PomodoroBlockMetrics {
    /// 块内容四周留白（`Space.cardPadding`）。
    static let insets: CGFloat = NotchTokens.Space.cardPadding
    /// 纵向三区带（头部 / 进度条 / 控制行）之间的间距（`Space.blockGap`）。
    static let sectionSpacing: CGFloat = NotchTokens.Space.blockGap
    /// 头部内「状态行 ↔ 完成数行」的间距。
    static let headerInnerSpacing: CGFloat = 3
    /// 头部内「圆点 ↔ 阶段名」的间距。
    static let titleSpacing: CGFloat = 5
    /// 进度条高度。
    static let progressHeight: CGFloat = 4
    /// 状态圆点直径。
    static let dotDiameter: CGFloat = 6
    /// 圆形控制钮直径（120 高卡内的触击目标）。
    static let controlDiameter: CGFloat = 28
    /// 控制钮之间的间距。
    static let controlSpacing: CGFloat = 12
    /// 空闲态图标徽章直径。
    static let idleBadgeDiameter: CGFloat = 44
}

/// 开始专注主按钮：白色层级圆角按钮（Kit 基体，带悬停/按压/手型光标），
/// 阶段红不铺底——专注工具的常态保持沉稳。
struct PomodoroPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: NotchTokens.Text.system(13, weight: .semibold),
            normalOpacity: 0.07,
            hoverOpacity: 0.11,
            pressedOpacity: 0.15,
            strokeOpacity: 0.10,
            foregroundOpacity: 0.92,
            pressedForegroundOpacity: 0.60
        )
    }
}

/// 抽屉块：计时主视图（空闲引导开始；运行中显示阶段、倒计时、进度与控制）。
struct PomodoroDrawerBlockView: View {
    let context: BlockContext
    @ObservedObject private var store = PomodoroStore.shared

    /// 滑动切页过渡中的只读预览副本：只展示，不认领单例的启停副作用。
    private var isPreview: Bool { context.layoutInfo.isPreview }

    var body: some View {
        let size = context.layoutInfo.frame.size
        BlockCard(hoverEffect: false) { _ in
            Group {
                if store.display.phase == .idle {
                    idleContent
                } else {
                    runningContent
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityLabel(L("a11y.pomodoro"))
    }

    // MARK: 空闲

    /// 横向引导行（徽章 + 开始按钮 + 时长副文案）：2×1 宽卡里比重直堆叠
    /// 更省纵向空间，节奏与运行中头部横向排布一致。
    private var idleContent: some View {
        HStack(spacing: 10) {
            Image(systemName: PomodoroTheme.symbol(for: .idle))
                .font(NotchTokens.Text.system(20, weight: .light))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .frame(width: PomodoroBlockMetrics.idleBadgeDiameter, height: PomodoroBlockMetrics.idleBadgeDiameter)
                .background(Circle().fill(NotchTokens.Surface.fillHighlighted))
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    store.start()
                } label: {
                    Label(L("drawer.startFocus"), systemImage: "play.fill")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                }
                .buttonStyle(PomodoroPrimaryButtonStyle())
                .disabled(isPreview)
                Text(LF("drawer.focusFor", store.config.focusMinutes))
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PomodoroBlockMetrics.insets)
    }

    // MARK: 运行中

    private var runningContent: some View {
        let display = store.display
        let accent = PomodoroTheme.accent(for: display.phase)
        return VStack(spacing: PomodoroBlockMetrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: PomodoroBlockMetrics.headerInnerSpacing) {
                    HStack(spacing: PomodoroBlockMetrics.titleSpacing) {
                        Circle()
                            .fill(accent)
                            .frame(
                                width: PomodoroBlockMetrics.dotDiameter,
                                height: PomodoroBlockMetrics.dotDiameter)
                        Text(PomodoroTheme.phaseTitle(for: display))
                            .font(NotchTokens.Text.system(12, weight: .semibold))
                            .foregroundStyle(NotchTokens.Foreground.secondary)
                    }
                    Text(LF("drawer.completed", display.completedToday))
                        .font(NotchTokens.Text.system(10))
                        .foregroundStyle(NotchTokens.Foreground.muted)
                }
                Spacer()
                Text(pomodoroCountdownText(display.remainingSeconds))
                    .font(NotchTokens.Text.system(28, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(NotchTokens.Foreground.body)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchTokens.Surface.track)
                    Capsule()
                        .fill(accent.opacity(0.9))
                        .frame(width: max(3, proxy.size.width * display.progress))
                }
            }
            .frame(height: PomodoroBlockMetrics.progressHeight)
            HStack(spacing: PomodoroBlockMetrics.controlSpacing) {
                IconCircleButton(
                    systemImage: display.isPaused ? "play.fill" : "pause.fill",
                    helpText: display.isPaused ? L("help.resume") : L("help.pause"),
                    diameter: PomodoroBlockMetrics.controlDiameter
                ) {
                    store.togglePause()
                }
                .disabled(isPreview)
                IconCircleButton(
                    systemImage: "forward.fill",
                    helpText: L("help.skip"),
                    diameter: PomodoroBlockMetrics.controlDiameter
                ) {
                    store.skip()
                }
                .disabled(isPreview)
                IconCircleButton(
                    systemImage: "stop.fill",
                    helpText: L("help.stop"),
                    diameter: PomodoroBlockMetrics.controlDiameter
                ) {
                    store.stop()
                }
                .disabled(isPreview)
                Spacer()
            }
        }
        .padding(PomodoroBlockMetrics.insets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
