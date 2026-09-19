import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 插件本地样式收敛点
//
// `docs/agents/插件开发约定.md`：颜色/字体/间距/动效**推荐**引用 `NotchTokens`；
// token 未覆盖或插件需要自有视觉时，可在插件自身代码中声明命名常量，并收敛到
// 单一样式/调色板文件（不推荐在调用处散写内联字面量）。
//
// **豁免理由**：状态色属于该约定明确豁免的「数据可视化语义色」——执行成功/失败/
// 超时/中止是数据语义，不是 UI 主题语义，`NotchTokens.Semantic` 也覆盖不了失败
// 红 / 超时橙 / 中性灰这三档。取值一律经 `NSColor` 系统语义色桥接（与 Kit 自己的
// `NotchTokens.Semantic.link = Color(NSColor.systemBlue)` 同一条路），既不自造
// 裸 RGB 字面量，也随系统外观解析。全部集中在本文件，调用处只引用
// `SchedulerPalette.*`。
enum SchedulerPalette {
    /// 成功（复用 Kit 的强调绿，保持与既有"健康"语义一致）。
    static let success = NotchTokens.Semantic.accentGreen
    /// 失败（退出码非 0 / 起不来）。
    static let failure = Color(NSColor.systemRed)
    /// 超时（守卫超时被杀）。
    static let timeout = Color(NSColor.systemOrange)
    /// 中止 / 中断（宿主退出、崩溃遗留）——不是失败，用中性灰。
    static let neutral = Color(NSColor.systemGray)
    /// 任务被禁用。
    static let disabled = NotchTokens.Foreground.disabled

    /// 状态点颜色。
    static func color(for status: TaskRun.Status) -> Color {
        switch status {
        case .succeeded: return success
        case .failed: return failure
        case .timedOut: return timeout
        case .running: return NotchTokens.Semantic.link
        case .aborted, .interrupted: return neutral
        }
    }
}

/// 块内布局常量（与块视图同源；打包期 `probes` 必须用这里的同一套数字推导，
/// 否则探针会与真实布局漂移）。
enum SchedulerMetrics {
    /// 块内边距。
    static let padding: CGFloat = NotchTokens.Space.cardPadding
    /// 工具行高度。
    static let toolbarHeight: CGFloat = 24
    /// 工具行与列表的间距。
    static let toolbarSpacing: CGFloat = 6
    /// 任务行高度。
    static let rowHeight: CGFloat = 52
    /// 任务行间距。
    static let rowSpacing: CGFloat = 6
    /// 任务列表在最小尺寸下必须完整可见的行数（探针据此声明）。
    static let visibleRowsAtMinimum = 3
    /// 空态占位高度。
    static let emptyStateHeight: CGFloat = 64
    /// 单行文本行高（探针推算用）。
    static let textLineHeight: CGFloat = 15

    /// 最小尺寸下任务列表区所需高度。
    static var listMinimumHeight: CGFloat {
        CGFloat(visibleRowsAtMinimum) * rowHeight
            + CGFloat(visibleRowsAtMinimum - 1) * rowSpacing
    }
}
