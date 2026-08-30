import CoreGraphics

// MARK: - 网格指标快照（文档 §5.3）

/// 抽屉网格指标的**值快照**。
///
/// 与 `NotchGridMetrics` 的区别：后者是转发 `GridMetricsStore.shared` 的
/// 静态访问点，每次读取都可能是新值；本类型是某一时刻的快照，作为参数
/// 传进纯计算——这样函数可测（测试塞任意指标即可，不必改进程级单例）。
///
/// 指标是用户可调的（设置 → 布局），**不要跨刷新缓存**：需要当前值时
/// 现取 `.current`，不要存进跨刷新存活的结构里。
struct GridMetrics: Equatable, Sendable {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var spacing: CGFloat
    var contentPadding: CGFloat
    /// 抽屉顶栏高度（钉住 / 编辑等按钮）：非用户可调，但随指标一起传递，
    /// 免得调用点再回头去查 `NotchGridMetrics.drawerTopBarHeight`。
    var topBarHeight: CGFloat

    /// 当前指标快照。
    static var current: GridMetrics {
        GridMetrics(
            cellWidth: NotchGridMetrics.cellWidth,
            cellHeight: NotchGridMetrics.cellHeight,
            spacing: NotchGridMetrics.spacing,
            contentPadding: NotchGridMetrics.contentPadding,
            topBarHeight: NotchGridMetrics.drawerTopBarHeight
        )
    }

    /// 格步长（单元格 + 间距）：全项目唯一一份定义。
    var stepWidth: CGFloat { cellWidth + spacing }
    var stepHeight: CGFloat { cellHeight + spacing }

    func width(columns: Int) -> CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * spacing
    }

    func height(rows: Int) -> CGFloat {
        CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * spacing
    }

    func size(columns: Int, rows: Int) -> CGSize {
        CGSize(width: width(columns: columns), height: height(rows: rows))
    }
}
