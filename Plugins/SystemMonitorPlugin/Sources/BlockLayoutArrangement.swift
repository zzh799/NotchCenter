import NotchCenterKit

// MARK: - 跨度 → 布局形态映射（纯逻辑，视图与测试共用）
//
// 宿主抽屉路径构建 BlockContext 时只填 widthColumns/heightRows，layoutInfo.size
// 恒为 nil（不派生尺寸档），尺寸判定一律走 span；size 仅作无 span 上下文
//（组件目录预览等）的兜底。跨度变化会重走 makeView（BlockViewCacheKey 含跨度），
// 形态在视图创建期即确定，无需运行时切换。

/// 总览块（system.overview）跨度 → 布局形态。
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

/// 单指标块跨度 → cell 形态。
enum MetricCellForm: Equatable {
    /// 1×1：指标名 + 当前值 + 迷你负载条。
    case mini
    /// 2×1：左值列 + sparkline。
    case sparkline

    static func forSpan(widthColumns: Int?, heightRows: Int?, size: BlockSize?) -> MetricCellForm {
        if let columns = widthColumns, let rows = heightRows {
            return columns >= 2 && rows == 1 ? .sparkline : .mini
        }
        return size == .medium ? .sparkline : .mini
    }
}
