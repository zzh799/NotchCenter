import NotchCenterKit
import SwiftUI

// MARK: - 块视图（紧凑快捷开关 + 抽屉控制卡）

/// 紧凑块：点击在空闲 → 开始会话、运行中 → 停止会话之间切换（.custom 交互，
/// 不展开抽屉）。运行期间图标点亮并带阶段色底衬。
struct PomodoroCompactView: View {
    let context: BlockContext
    @ObservedObject private var store = PomodoroStore.shared

    private var isRunning: Bool { store.display.phase != .idle }

    var body: some View {
        let slot = context.layoutInfo.frame.size
        Button {
            if isRunning {
                store.stop()
            } else {
                store.start()
            }
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isRunning ? 0.95 : 0.72))
                .frame(width: slot.width, height: slot.height)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isRunning
                                ? PomodoroIslandLayout.accent(for: store.display.phase).opacity(0.38)
                                : .clear
                        )
                )
        }
        .buttonStyle(.plain)
        // 紧凑面板是 canBecomeKey 的 NSPanel，点击后按钮成为 first responder 会画系统蓝色焦点环。
        // （`.focusEffect(_:)` 是 iOS 专属；macOS 用 focusEffectDisabled。）
        .focusable(false)
        .focusEffectDisabled(true)
        .help(isRunning ? L("compact.help.stop") : L("compact.help.start"))
        .accessibilityLabel(L("a11y.pomodoro"))
        .accessibilityValue(isRunning ? L("compact.help.stop") : L("compact.help.start"))
    }
}

/// 抽屉块：计时主视图（空闲引导开始；运行中显示阶段、倒计时、进度与控制）。
struct PomodoroDrawerBlockView: View {
    let context: BlockContext
    @ObservedObject private var store = PomodoroStore.shared

    var body: some View {
        let size = context.layoutInfo.frame.size
        Group {
            if store.display.phase == .idle {
                idleContent
            } else {
                runningContent
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: 空闲

    private var idleContent: some View {
        VStack(spacing: 9) {
            Button {
                store.start()
            } label: {
                Label(L("drawer.startFocus"), systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(PomodoroIslandLayout.focusAccent.opacity(0.85)))
            }
            .buttonStyle(.plain)
            Text(LF("drawer.focusFor", store.config.focusMinutes))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 运行中

    private var runningContent: some View {
        let display = store.display
        let accent = PomodoroIslandLayout.accent(for: display.phase)
        return VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                        Text(PomodoroIslandLayout.phaseTitle(for: display))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    Text(LF("drawer.completed", display.completedToday))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text(pomodoroCountdownText(display.remainingSeconds))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.94))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    Capsule()
                        .fill(accent.opacity(0.9))
                        .frame(width: max(3, proxy.size.width * display.progress))
                }
            }
            .frame(height: 4)
            HStack(spacing: 12) {
                roundButton(
                    display.isPaused ? "play.fill" : "pause.fill",
                    help: display.isPaused ? L("help.resume") : L("help.pause")
                ) {
                    store.togglePause()
                }
                roundButton("forward.fill", help: L("help.skip")) {
                    store.skip()
                }
                roundButton("stop.fill", help: L("help.stop")) {
                    store.stop()
                }
                Spacer()
            }
        }
        .padding(14)
    }

    private func roundButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
