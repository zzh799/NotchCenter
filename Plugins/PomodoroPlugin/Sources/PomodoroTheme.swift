import SwiftUI

// MARK: - 阶段展示语义（原 PomodoroIslandLayout；活动岛移除后仅保留展示语义部分）

/// 番茄钟阶段的外观语义：引导符号与标题文案（抽屉块 / 活动摘要芯片共用
/// 同一套，保证各载体视觉一致）。
///
/// 强调色一律跟随系统强调色（`Color.accentColor`），不维护插件自有色板：
/// 阶段区分由符号（timer/leaf/eye）与文案承担（决策见 2026-09-09
/// 番茄钟跟随系统强调色与对称居中 note）。
@MainActor
enum PomodoroTheme {
    /// 活动阶段强调色：跟随用户在系统设置里选的强调色。
    static let activeAccent = Color.accentColor

    static func accent(for phase: PomodoroPhase) -> Color {
        switch phase {
        case .idle: .white
        case .focus, .rest, .microBreak, .awaitingRating: activeAccent
        }
    }

    static func symbol(for phase: PomodoroPhase) -> String {
        switch phase {
        case .focus, .idle: "timer"
        case .rest: "leaf.fill"
        case .microBreak: "eye.fill"
        case .awaitingRating: "face.smiling"
        }
    }

    static func phaseTitle(for display: PomodoroDisplay) -> String {
        if display.isPaused { return L("phase.paused") }
        switch display.phase {
        case .focus, .idle: return L("phase.focus")
        case .rest: return L("phase.rest")
        case .microBreak: return L("phase.microBreak")
        case .awaitingRating: return L("phase.awaitingRating")
        }
    }
}
