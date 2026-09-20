import NotchCenterKit
import SwiftUI

// MARK: - CalendarPlugin（官方「日历」插件）

/// 抽屉里的当月速览块：公历月网格 + 今日农历，点击打开日历.app、长按看今日详情。
/// 纯展示（不翻月、无实例状态、无设置界面、无快捷按钮），版式与探针同源于
/// `CalendarMonthMetrics`。决策见 docs/agent-notes/proposed/2026-09-20-calendar-month-block.md。
@objc(CalendarPlugin) @MainActor
public final class CalendarPlugin: NSObject, NotchCenterPlugin {
    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe；区带镜像 `CalendarMonthMetrics`
    /// 的四段纵向分配：内边距 10 → 头部 15 → 间隙 2 → 星期行 13 → 网格 100，
    /// 合计 150）。意图：三段区带在 150×150 下须完整可见且互不重叠；块高小到
    /// 塞不下四段时越界判定落在网格带上（该带已并入底部内边距）。
    private static func monthLayoutProbes(for size: CGSize) -> [BlockProbe] {
        [
            BlockProbe(id: "calendar.header", rect: CalendarMonthMetrics.headerRect(for: size)),
            BlockProbe(id: "calendar.weekday", rect: CalendarMonthMetrics.weekdayRect(for: size)),
            BlockProbe(id: "calendar.grid", rect: CalendarMonthMetrics.gridRect(for: size)),
        ]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "calendar.month",
                displayName: L("block.month.name"),
                kind: .drawer,
                // 三档固定同值：7 列 × 6 行在更窄的宽度下会把数字压到 9pt 以下，
                // 更宽只是留白，因此不开自适应区间（理由见决策记录「备选方案」）。
                minSize: BlockPixelSize(width: 150, height: 150),
                maxSize: BlockPixelSize(width: 150, height: 150),
                recommendedSize: BlockPixelSize(width: 150, height: 150),
                symbolName: "calendar",
                probes: { info in
                    Self.monthLayoutProbes(for: info.frame.size)
                },
                makeView: { context in
                    AnyView(CalendarMonthBlockView(context: context))
                }
            )
        ]
    }

    public override init() {
        super.init()
    }
}
