import CoreGraphics
import NotchCenterKit

// MARK: - 跨度 → 布局形态映射（纯逻辑，视图与测试共用）
//
// 宿主在抽屉与目录预览路径都下发 widthColumns/heightRows（layoutInfo.size =
// 当前真实跨度，与 width/height 同值）；nil 仅出现在无落位上下文的防御路径，
// 按推荐 1×1 的 mini / sparklineGrid 形态兜底。跨度变化会重走 makeView
//（BlockViewCacheKey 含跨度），形态在视图创建期即确定，无需运行时切换。

/// 总览块（system.overview）跨度 → 布局方向。
///
/// 只表达“往哪排”（网格 / 横排 / 竖排 / 小条），不表达“画不画曲线”：同一跨度在不同格子尺寸下物理像素差数倍，曲线能不能放下只看实际像素（见 showsSparkline 的注释）。
enum OverviewArrangement: Equatable {
    /// 1×1：横向小条竖排（名称 + 聚合值）。
    case compactStrips
    /// 1×2：迷你 cell 竖排（名称 + 双值 + 迷你负载条）。
    case stackedMiniCells
    /// 2×1：迷你 cell 横排（名称 + 双值 + 迷你负载条）。
    case miniCellRow
    /// 2×2 / 4×4：两列网格（sparkline cell）。
    case sparklineGrid
    /// 4×2 / 4×3：横向一排（sparkline cell）。
    case sparklineRow

    static func forSpan(widthColumns: Int?, heightRows: Int?) -> OverviewArrangement {
        guard let columns = widthColumns, let rows = heightRows else { return .sparklineGrid }
        if columns == 1, rows == 1 { return .compactStrips }
        if columns == 1 { return .stackedMiniCells }
        if rows == 1, columns == 2 { return .miniCellRow }
        if columns == rows { return .sparklineGrid }
        return columns > rows ? .sparklineRow : .stackedMiniCells
    }
}

/// 像素密度判定（混合式的另一半：方向看格数，曲线看像素）。
///
/// 背景：格子宽高用户可调，2x2 在默认格下是 312x252、小格下只有约 162x132，前者放得下 26 高的 sparkline，后者只能放下 4 高的 MiniBar。阈值按内容高度推导：标头约 16 + 数值 22（双值约 32）+ 两处间距 12 + 曲线 26 + 呼吸余量，取整 90。卡片内边距 10 与网格间距 10 与 BlockViews 的 .padding(10) / spacing:10 同值，改任一处须同步。
extension OverviewArrangement {
    /// 有曲线形态（grid / row）在该实际尺寸下是否真画 sparkline；false 时调用方降级为同布局的 MiniBar cell（MiniBar 保留，方向不变）。
    /// enabledCount 参与计算：关掉部分指标后每 cell 分到的高度变大，应自动恢复曲线。非正尺寸（目录预览等无 frame 路径）回 true，保持推荐形态外观。
    static func showsSparkline(
        arrangement: OverviewArrangement,
        contentSize: CGSize,
        enabledCount: Int
    ) -> Bool {
        switch arrangement {
        case .compactStrips, .stackedMiniCells, .miniCellRow:
            return false
        case .sparklineGrid, .sparklineRow:
            guard contentSize.width > 0, contentSize.height > 0 else { return true }
            let cellHeight: CGFloat
            if arrangement == .sparklineGrid {
                let rows = max(1, (max(enabledCount, 1) + 1) / 2)
                cellHeight = (contentSize.height - 20 - CGFloat(rows - 1) * 10) / CGFloat(rows)
            } else {
                cellHeight = contentSize.height - 20
            }
            return cellHeight >= 90
        }
    }
}

/// 单指标块跨度 → cell 形态。
enum MetricCellForm: Equatable {
    /// 1×1：指标名 + 当前值 + 迷你负载条。
    case mini
    /// 2×1：左值列 + sparkline。
    case sparkline

    static func forSpan(widthColumns: Int?, heightRows: Int?) -> MetricCellForm {
        if let columns = widthColumns, let rows = heightRows {
            return columns >= 2 && rows == 1 ? .sparkline : .mini
        }
        // 无落位上下文（防御路径）：按推荐 1×1 的 mini 形态。
        return .mini
    }
}

extension MetricCellForm {
    /// 宽幅曲线（高 52）在该实际尺寸下是否放得下；false 时调用方用 mini 形态（MiniBar 保留）。非正尺寸回 true，保持推荐外观。
    static func showsWideSparkline(contentSize: CGSize) -> Bool {
        guard contentSize.width > 0, contentSize.height > 0 else { return true }
        return contentSize.height - 20 >= 60
    }
}
