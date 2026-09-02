import AppKit
import Foundation
import NotchCenterKit

// MARK: - 紧凑带活动摘要：展示排布与外观度量（Agent Note 2026-09-03-compact-area-activity-summary）

/// 摘要「左右各一、最新优先、收回回退」的纯排布逻辑（宿主侧可测单元）。
///
/// 规则：
/// - 抽屉展开期间摘要整体让位（与旧活动岛同一纪律），不返回任何摘要；
/// - 至多展示最近两条：**最新在左、次新在右**；仅一条时在左；
/// - 「收回回退」由调用方在更新序列后重算本函数天然达成（被收回者出列后，
///   余下的次新/更早者自动顶上空位）。
enum ActivitySummaryDisplay {
    /// 依据提交序列（新追加在尾）与抽屉状态，得出左右两侧应展示的摘要。
    static func visiblePair(
        from summaries: [ActivitySummary],
        drawerExpanded: Bool
    ) -> (left: ActivitySummary?, right: ActivitySummary?) {
        guard !drawerExpanded, !summaries.isEmpty else { return (nil, nil) }
        let newest = summaries[summaries.count - 1]
        guard summaries.count >= 2 else { return (newest, nil) }
        return (newest, summaries[summaries.count - 2])
    }
}

/// 宿主绘制的摘要芯片外观常量与宽度估算。
///
/// 芯片宽度由宿主按文案估算（与 SwiftUI 渲染近似 + 余量，宁宽勿裁），
/// 控制器据此同步紧凑带几何——不走视图逐帧回写，避免「测量→重建」环路。
/// 文案超宽时芯片内文本截断（估算留余量后通常不触发）。
@MainActor
enum SummaryChipMetrics {
    /// 芯片主文案字体（渲染侧 SwiftUI 用同一规格）。
    static let textFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// 芯片副文案字体（渲染侧同规格，略小、常规字重）。
    static let subtitleFont = NSFont.systemFont(ofSize: 11)
    /// 引导符号占宽（渲染侧 SF Symbol 13pt 近似）。
    static let symbolWidth: CGFloat = 14
    /// 符号与文本、主/副文案之间的间距。
    static let symbolTextGap: CGFloat = 5
    /// 芯片横向内边距（左右合计）。
    static let horizontalPadding: CGFloat = 20
    /// 估算的余量（覆盖字体回退/符号宽度误差，宁宽勿裁）。
    static let measurementHeadroom: CGFloat = 6
    /// 芯片宽度上限（超长文案截断）。
    static let maxWidth: CGFloat = 180

    /// 文案宽度（AppKit 度量，含字体回退；与 SwiftUI 渲染同字体规格）。
    static func textWidth(_ text: String, font: NSFont = textFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// 估算一颗摘要芯片的展示宽度：内边距 + 符号位 + **主文案** +
    /// 副文案（非空时连同间距计入：副文案渲染在同一条文本行内，
    /// 不估算它芯片就会裁到副文案）。封顶 `maxWidth`，超长由视图截断兜底。
    static func estimatedWidth(for summary: ActivitySummary) -> CGFloat {
        let symbol = summary.symbolName == nil ? 0 : symbolWidth + symbolTextGap
        var text = textWidth(summary.title)
        if let subtitle = summary.subtitle, !subtitle.isEmpty {
            text += symbolTextGap + textWidth(subtitle, font: subtitleFont)
        }
        let raw = horizontalPadding + symbol + text + measurementHeadroom
        return min(maxWidth, max(0, ceil(raw)))
    }
}
