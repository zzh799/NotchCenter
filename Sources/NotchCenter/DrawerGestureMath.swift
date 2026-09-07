import CoreGraphics
import NotchCenterKit

// MARK: - 抽屉手势数学

/// 从 SwiftUI 视图里剥出来的**纯计算**：拖拽位移 → 目标格、缩放位移 →
/// 候选跨度、缩放预览的补偿偏移。
///
/// 剥出来的唯一目的是可测——`DrawerPanelView` / `DrawerBlockContainer`
/// 依赖 `PanelUIState` 与真实窗口，无法在 `swift test` 下构造；这三个类型
/// 只吃值类型，测试可以直接打。
///
/// 这些函数的语义必须与抽出前的视图实现**逐分支等价**：它们描述的是
/// 已经调好的手感（死区、吸附、夹紧），重构不改行为。

/// 缩放握把的夹紧上限。
enum DrawerResizeLimits {
    /// 纵向无容量概念，纯手感上限。
    static let maxRows = 6
}

/// 拖拽位移 → 目标格。
enum DragTargetResolver {
    /// 语义：`placement.origin + round(translation / 步长)`。
    ///
    /// 拖拽手势可以继续用默认 `.local` 坐标空间：被拖块的容器 position
    /// 在拖拽期间不随预览变化（`resolveOrigin` 把它排除），local 空间稳定。
    /// **只有缩放必须 `.global`**——见 `DrawerBlockContainer.resizeGesture`。
    static func target(
        placement: PlacedBlock,
        translation: CGSize,
        metrics: GridMetrics
    ) -> (column: Int, row: Int) {
        let deltaColumns = Int((translation.width / metrics.stepWidth).rounded())
        let deltaRows = Int((translation.height / metrics.stepHeight).rounded())
        return (
            column: placement.originColumn + deltaColumns,
            row: placement.originRow + deltaRows
        )
    }
}

/// 缩放位移 → 候选跨度。
enum ResizeSpanResolver {
    /// 连续跨度（未量化）：基准跨度 + 位移折算的格数。
    ///
    /// `base` 是**按下瞬间**的跨度，跨手势事件保持稳定——这是"按下不会
    /// 瞬间缩小"的前提（位移为零时结果即 base）。
    static func continuous(
        base: GridSpan,
        translation: CGSize,
        metrics: GridMetrics
    ) -> (columns: CGFloat, rows: CGFloat) {
        (
            columns: CGFloat(base.columns) + translation.width / metrics.stepWidth,
            rows: CGFloat(base.rows) + translation.height / metrics.stepHeight
        )
    }

    /// 死区量化 + 逐轴钳进块的允许矩形盒（列 `[minSize.columns...maxSize.columns]`、
    /// 行 `[minSize.rows...min(maxSize.rows, maxRows)]`），盒内任意整数跨可达。
    ///
    /// 量化经 `ResizeHysteresis` 死区迟滞：朴素 round() 会在半格边界处随
    /// ±1px 抖动来回翻转，预览随之闪烁。
    ///
    /// 存量超盒布局（插件更新后显示跨度落在盒外）的手势语义：预览目标从
    /// 按下瞬间的当前跨度起被钳进盒内——首个像素级位移即夹到最近的盒边界
    /// （不得大于最大 / 小于最小），与"存量照显、下次拖拽即夹"的产品策略一致。
    static func resolve(
        base: GridSpan,
        translation: CGSize,
        current: GridSpan,
        minSize: GridSpan,
        maxSize: GridSpan,
        metrics: GridMetrics
    ) -> GridSpan {
        let raw = continuous(base: base, translation: translation, metrics: metrics)
        let quantizedColumns = ResizeHysteresis.quantized(raw.columns, current: current.columns)
        let quantizedRows = ResizeHysteresis.quantized(raw.rows, current: current.rows)
        return GridSpan(
            columns: min(max(quantizedColumns, minSize.columns), maxSize.columns),
            rows: min(max(quantizedRows, minSize.rows), min(maxSize.rows, DrawerResizeLimits.maxRows))
        )
    }
}

/// 缩放预览的补偿偏移。
enum ResizeCompensation {
    /// 容器被外层按**提交跨度**定 frame 并居中定位，内部按**预览跨度**渲染
    /// 时会以中心对称扩张。把增长量的一半平移回来，使左上角锚定不动
    /// （原点不随缩放改变）。
    static func offset(from: GridSpan, to: GridSpan, metrics: GridMetrics) -> CGSize {
        CGSize(
            width: (metrics.width(columns: to.columns) - metrics.width(columns: from.columns)) / 2,
            height: (metrics.height(rows: to.rows) - metrics.height(rows: from.rows)) / 2
        )
    }
}
