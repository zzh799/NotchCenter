import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（专注计时控制卡）
//
// 规范落点（决策见 docs/agent-notes 2026-09-09-pomodoro-ui-redesign 与
// 2026-09-09-pomodoro-system-accent-symmetric）：卡片壳走 Kit `BlockCard`，
// 圆形控制钮走 `IconCircleButton`，开始按钮走基于 `RoundedHoverButtonBody`
// 的主按钮样式；颜色/间距一律 `NotchTokens`，强调色跟随系统强调色；
// 空闲与运行中两态都是左右对称的垂直居中栈（无 `Spacer` 贴边）。

/// 版式常量：横向内边距对齐 `Space.cardPadding`，纵向内边距取 8
/// （对标 `DisplaySlidersBlockView` 紧凑 insets `8/10/8/10`：2×1 最小高
/// 120 纵向紧张）；打包期探针（`PomodoroPlugin.pomodoroLayoutProbes`）
/// 镜像本组数值。
private enum PomodoroBlockMetrics {
    /// 块内容留白：纵向 8 / 横向 10。
    static let insets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    /// 纵向区带之间的间距（`Space.blockGap`）。
    static let sectionSpacing: CGFloat = NotchTokens.Space.blockGap
    /// 状态单行内元素间距。
    static let statusSpacing: CGFloat = 4
    /// 进度条高度。
    static let progressHeight: CGFloat = 4
    /// 状态圆点直径。
    static let dotDiameter: CGFloat = 6
    /// 圆形控制钮直径。
    static let controlDiameter: CGFloat = 24
    /// 控制钮之间的间距。
    static let controlSpacing: CGFloat = 12
    /// 空闲态图标徽章直径。
    static let idleBadgeDiameter: CGFloat = 40
    /// 评分脸直径（抽屉块档；整页用 `PomodoroPageMetrics.moodDiameter`）。
    static let moodDiameter: CGFloat = 26
}

/// 开始专注主按钮：白色层级圆角按钮（Kit 基体，带悬停/按压/手型光标）。
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

/// 抽屉块：计时主视图（空闲引导开始；运行中显示阶段、倒计时、进度与控制；
/// 有待评分时整块换成评分版式）。
struct PomodoroDrawerBlockView: View {
    let context: BlockContext
    @ObservedObject private var store = PomodoroStore.shared

    /// 滑动切页过渡中的只读预览副本：只展示，不认领单例的启停副作用。
    private var isPreview: Bool { context.layoutInfo.isPreview }

    var body: some View {
        let size = context.layoutInfo.frame.size
        BlockCard(hoverEffect: false) { _ in
            Group {
                // 待评分优先于阶段：整个休息期间都能评（提示在专注完成那刻就
                // 创建），评分期间**不给**任何计时控制（Agent Note §9）。
                if let pending = store.display.pendingRating {
                    ratingContent(pending)
                } else if store.display.phase == .idle {
                    idleContent
                } else {
                    runningContent
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityLabel(L("a11y.pomodoro"))
    }

    // MARK: 待评分（整块替换）

    /// 复用空闲态同款骨架与内边距、**不新增第五行**——存量 300×120 的放置
    /// 在评分态下依然合法（决策见 Agent Note 2026-09-10-plugin-page-blocks §9）。
    private func ratingContent(_ pending: PomodoroPendingRating) -> some View {
        VStack(spacing: PomodoroBlockMetrics.sectionSpacing) {
            HStack(spacing: PomodoroBlockMetrics.statusSpacing) {
                Image(systemName: PomodoroTheme.symbol(for: .awaitingRating))
                    .font(NotchTokens.Text.system(12, weight: .medium))
                    .foregroundStyle(PomodoroTheme.activeAccent)
                Text(L("rating.prompt"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                    .lineLimit(1)
            }
            PomodoroRatingBar(
                pending: pending,
                diameter: PomodoroBlockMetrics.moodDiameter,
                showsDetail: false,
                isDisabled: isPreview,
                onRate: { store.ratePending($0) },
                onDiscard: { store.discardPending() }
            )
        }
        .padding(PomodoroBlockMetrics.insets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 空闲

    /// 垂直居中对称栈：徽章 → 开始按钮 → 时长副文案。
    private var idleContent: some View {
        VStack(spacing: PomodoroBlockMetrics.sectionSpacing) {
            Image(systemName: PomodoroTheme.symbol(for: .idle))
                .font(NotchTokens.Text.system(18, weight: .light))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .frame(
                    width: PomodoroBlockMetrics.idleBadgeDiameter,
                    height: PomodoroBlockMetrics.idleBadgeDiameter)
                .background(Circle().fill(NotchTokens.Surface.fillHighlighted))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PomodoroBlockMetrics.insets)
    }

    // MARK: 运行中

    /// 垂直居中对称栈：状态单行 → 倒计时 → 进度条 → 居中控制行。
    private var runningContent: some View {
        let display = store.display
        let accent = PomodoroTheme.accent(for: display.phase)
        return VStack(spacing: PomodoroBlockMetrics.sectionSpacing) {
            HStack(spacing: PomodoroBlockMetrics.statusSpacing) {
                Circle()
                    .fill(accent)
                    .frame(
                        width: PomodoroBlockMetrics.dotDiameter,
                        height: PomodoroBlockMetrics.dotDiameter)
                Text(PomodoroTheme.phaseTitle(for: display))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                // 中点分隔是纯标点（非词汇），两侧文案各自本地化，中英通用。
                Text("·")
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(LF("drawer.completed", display.completedToday))
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
            Text(pomodoroCountdownText(display.remainingSeconds))
                .font(NotchTokens.Text.system(28, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(NotchTokens.Foreground.body)
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
            }
        }
        .padding(PomodoroBlockMetrics.insets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
