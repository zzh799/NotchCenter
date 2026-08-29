import NotchCenterKit
import SwiftUI

// MARK: - 活动岛视图（宿主 ActivityIsland 的插件侧内容）

/// 活动岛尺寸常量。宿主在内容四周绘制统一底衬（padding 10，需与宿主
/// `ActivityIslandLayout.islandPadding` 一致）；这里声明的是内容尺寸与
/// 含底衬的整岛尺寸（宿主据此开窗与命中）。
@MainActor
enum PomodoroIslandLayout {
    static let chromePadding: CGFloat = 10
    /// 紧凑态内容尺寸（图标 + 倒计时）。
    static let compactContentSize = CGSize(width: 158, height: 26)
    /// 展开态内容尺寸（阶段标题 + 大倒计时 + 进度条 + 控制按钮）。
    static let expandedContentSize = CGSize(width: 244, height: 96)

    static var compactSize: CGSize {
        CGSize(
            width: compactContentSize.width + chromePadding * 2,
            height: compactContentSize.height + chromePadding * 2
        )
    }

    static var expandedSize: CGSize {
        CGSize(
            width: expandedContentSize.width + chromePadding * 2,
            height: expandedContentSize.height + chromePadding * 2
        )
    }

    /// 向宿主声明的整岛上限（展开态；悬停 / 微休息自动展开都在此尺寸内变形）。
    static var maxSize: CGSize { expandedSize }

    // 阶段强调色（白色层级之外的少量语义色，见 docs/DESIGN.md §2.4）。
    static let focusAccent = Color(red: 0.96, green: 0.45, blue: 0.38)
    static let restAccent = Color(red: 0.44, green: 0.78, blue: 0.56)
    static let microBreakAccent = Color(red: 0.99, green: 0.8, blue: 0.34)

    static func accent(for phase: PomodoroPhase) -> Color {
        switch phase {
        case .focus: focusAccent
        case .rest: restAccent
        case .microBreak: microBreakAccent
        case .idle: .white
        }
    }

    static func symbol(for phase: PomodoroPhase) -> String {
        switch phase {
        case .focus, .idle: "timer"
        case .rest: "leaf.fill"
        case .microBreak: "eye.fill"
        }
    }

    static func phaseTitle(for display: PomodoroDisplay) -> String {
        if display.isPaused { return L("phase.paused") }
        switch display.phase {
        case .focus, .idle: return L("phase.focus")
        case .rest: return L("phase.rest")
        case .microBreak: return L("phase.microBreak")
        }
    }
}

/// 活动岛内容：紧凑态常驻显示倒计时；悬停展开出进度条与控制按钮，
/// 微休息期间自动展开提醒离开屏幕（所有屏幕的岛实例共享同一 store 状态）。
struct PomodoroIslandView: View {
    @ObservedObject var store: PomodoroStore
    @State private var isHovering = false

    private var isExpanded: Bool {
        isHovering || store.display.phase == .microBreak
    }

    var body: some View {
        ZStack {
            if isExpanded {
                expandedContent.transition(.opacity)
            } else {
                compactContent.transition(.opacity)
            }
        }
        .frame(
            width: isExpanded
                ? PomodoroIslandLayout.expandedContentSize.width
                : PomodoroIslandLayout.compactContentSize.width,
            height: isExpanded
                ? PomodoroIslandLayout.expandedContentSize.height
                : PomodoroIslandLayout.compactContentSize.height
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isHovering = hovering
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpanded)
    }

    // MARK: 紧凑态

    private var compactContent: some View {
        let display = store.display
        return HStack(spacing: 7) {
            Image(systemName: PomodoroIslandLayout.symbol(for: display.phase))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PomodoroIslandLayout.accent(for: display.phase))
            Text(pomodoroCountdownText(display.remainingSeconds))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
            if display.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: 展开态

    private var expandedContent: some View {
        let display = store.display
        let accent = PomodoroIslandLayout.accent(for: display.phase)
        return VStack(spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                        Text(PomodoroIslandLayout.phaseTitle(for: display))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    if display.phase == .microBreak {
                        Text(L("island.hint"))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer()
                Text(pomodoroCountdownText(display.remainingSeconds))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.94))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(accent.opacity(0.9))
                        .frame(width: max(3, proxy.size.width * display.progress))
                }
            }
            .frame(height: 4)
            HStack(spacing: 12) {
                islandButton(
                    display.isPaused ? "play.fill" : "pause.fill",
                    help: display.isPaused ? L("help.resume") : L("help.pause")
                ) {
                    store.togglePause()
                }
                islandButton("forward.fill", help: skipHelp) {
                    store.skip()
                }
                islandButton("stop.fill", help: L("help.stop")) {
                    store.stop()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var skipHelp: String {
        store.display.phase == .microBreak ? L("island.backToFocus") : L("help.skip")
    }

    private func islandButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
