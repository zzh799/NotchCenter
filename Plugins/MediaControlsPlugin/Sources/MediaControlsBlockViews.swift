import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（封面 / 曲目 / 进度 / 控制钮）

/// 控制面统一强调色（与 DESIGN.md §2.4 的语义色用法同族：白色层级之外的少量点缀）。
enum MediaControlsTheme {
    static let accent = Color(red: 0.45, green: 0.65, blue: 1.0)
}

/// 抽屉块：媒体控制卡（当前播放曲目的封面、标题、进度与播放控制）。
/// 无播放内容时显示空态引导；私有框架不可用时显示降级说明。
struct MediaControlsDrawerBlockView: View {
    let context: BlockContext
    @ObservedObject private var controller = MediaPlayerController.shared

    var body: some View {
        let size = context.layoutInfo.frame.size
        Group {
            switch controller.display.state {
            case .unavailable:
                emptyState(
                    symbol: "exclamationmark.triangle",
                    title: L("drawer.unavailable"),
                    hint: L("drawer.unavailable.hint")
                )
            case .idle:
                emptyState(
                    symbol: "music.note",
                    title: L("drawer.nothing"),
                    hint: L("drawer.hint")
                )
            case .playing, .paused:
                activeContent
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
    }

    // MARK: 空态 / 降级态

    private func emptyState(symbol: String, title: String, hint: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system( 22, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(0.07)))
            Text(title)
                .font(NotchTokens.Text.system( 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(hint)
                .font(NotchTokens.Text.system( 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 播放中 / 暂停

    private var activeContent: some View {
        let display = controller.display
        let isPaused = display.state == .paused
        return VStack(spacing: 10) {
            // 行 1：封面 + 曲目信息
            HStack(spacing: 12) {
                artworkView
                    .frame(width: 54, height: 54)
                    .overlay {
                        if isPaused {
                            // 暂停时封面压暗 + 中央播放提示，状态一眼可辨。
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.black.opacity(0.42))
                            Image(systemName: "play.fill")
                                .font(NotchTokens.Text.system( 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    if let title = display.title, !title.isEmpty {
                        Text(title)
                            .font(NotchTokens.Text.system( 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if isPaused {
                            Text(L("state.paused"))
                                .font(NotchTokens.Text.system( 9.5, weight: .semibold))
                                .foregroundStyle(MediaControlsTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule().fill(MediaControlsTheme.accent.opacity(0.18))
                                )
                        }
                        Text(subtitleLine)
                            .font(NotchTokens.Text.system( 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    controlButtons
                }
                Spacer(minLength: 0)
            }
            // 行 2：进度条 + 时间
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.09))
                        Capsule()
                            .fill(progressAccent(isPaused: isPaused))
                            .frame(width: progressWidth(proxy.size.width))
                    }
                }
                .frame(height: 3)
                .animation(.linear(duration: 0.9), value: display.elapsed)
                HStack {
                    Text(Self.timeText(display.elapsed))
                    Spacer()
                    Text(Self.timeText(display.duration))
                }
                .font(NotchTokens.Text.system( 9.5, design: .monospaced).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(14)
        .help(subtitleLine)
        .accessibilityElement(children: .contain)
    }

    // MARK: 子视图

    private var artworkView: some View {
        Group {
            if let artwork = controller.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(0.07))
                    Image(systemName: "music.note")
                        .font(NotchTokens.Text.system( 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var controlButtons: some View {
        HStack(spacing: 10) {
            roundButton("backward.fill", help: L("help.previous")) {
                controller.previousTrack()
            }
            roundButton(
                controller.display.state == .paused ? "play.fill" : "pause.fill",
                help: controller.display.state == .paused ? L("help.play") : L("help.pause"),
                emphasized: true
            ) {
                controller.togglePlayPause()
            }
            roundButton("forward.fill", help: L("help.next")) {
                controller.nextTrack()
            }
        }
    }

    private func roundButton(
        _ symbol: String,
        help: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            // isPreview 契约：预览副本不认领跨实例交互副作用（滑动切页的
            // 非激活页副本），点击只读展示，不投递媒体命令。
            guard !context.layoutInfo.isPreview else { return }
            action()
        } label: {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system( 12, weight: .semibold))
                .foregroundStyle(.white.opacity(emphasized ? 0.95 : 0.8))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        emphasized ? MediaControlsTheme.accent.opacity(0.85) : .white.opacity(0.09)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled(true)
        .help(help)
    }

    private var subtitleLine: String {
        let artist = controller.display.artist.flatMap { $0.isEmpty ? nil : $0 }
        let album = controller.display.album.flatMap { $0.isEmpty ? nil : $0 }
        switch (artist, album) {
        case let (artist?, album?): return "\(artist) — \(album)"
        case let (artist?, nil): return artist
        case let (nil, album?): return album
        case (nil, nil): return ""
        }
    }

    private func progressAccent(isPaused: Bool) -> Color {
        isPaused ? .white.opacity(0.5) : MediaControlsTheme.accent.opacity(0.9)
    }

    private func progressWidth(_ total: CGFloat) -> CGFloat {
        guard controller.display.duration > 0 else { return 0 }
        let fraction = min(max(controller.display.elapsed / controller.display.duration, 0), 1)
        return max(3, total * fraction)
    }

    private static func timeText(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
