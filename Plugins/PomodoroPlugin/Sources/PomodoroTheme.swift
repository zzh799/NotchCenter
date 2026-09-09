import NotchCenterKit
import SwiftUI

// MARK: - 阶段展示常量（原 PomodoroIslandLayout；活动岛移除后仅保留展示语义部分）

/// 番茄钟阶段的外观常量：阶段色、引导符号与标题文案（抽屉块 /
/// 活动摘要芯片共用同一套，保证各载体视觉一致）。
///
/// 豁免说明：三阶段色是数据语义色（专注/休息/微休息的即时状态，不可只用
/// 白 alpha 表达），按插件约定收敛在本调色板单一文件中，不向调用处扩散；
/// `scan-ui-tokens` 基线登记 3 项，不新增。
@MainActor
enum PomodoroTheme {
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
