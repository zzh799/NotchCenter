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

    /// 横向夹紧上界。
    ///
    /// ⚠️ **已知 bug，本次重构刻意保留旧行为**：它与 `effectiveMaxColumns()`
    /// 脱钩——`previewArrangement(resizing:)` 只 clamp `originColumn`、
    /// **不截断 width**，所以当 capacity < 4（用户把 maxColumns 调到 2/3，
    /// 或屏幕窄）时，能把块撑到 4 列并塞到 `originColumn = -2`，写出
    /// 「跨度 4 > 容量 2」的布局。
    ///
    /// 修复方式：改成 `max(1, capacity)`，并同步 `DrawerGestureMathTests` 中
    /// 标注 `KNOWN BUG` 的那条断言。
    static let legacyColumnUpperBound = 4
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

    /// 死区量化 + 夹紧（列 `1...columnUpperBound`，行 `1...maxRows`）。
    ///
    /// 量化经 `ResizeHysteresis` 死区迟滞：朴素 round() 会在半格边界处随
    /// ±1px 抖动来回翻转，预览随之闪烁。
    static func quantized(
        base: GridSpan,
        translation: CGSize,
        current: GridSpan,
        metrics: GridMetrics,
        columnUpperBound: Int = DrawerResizeLimits.legacyColumnUpperBound
    ) -> GridSpan {
        let raw = continuous(base: base, translation: translation, metrics: metrics)
        return GridSpan(
            columns: min(
                max(ResizeHysteresis.quantized(raw.columns, current: current.columns), 1),
                columnUpperBound
            ),
            rows: min(
                max(ResizeHysteresis.quantized(raw.rows, current: current.rows), 1),
                DrawerResizeLimits.maxRows
            )
        )
    }

    /// 位移 → 候选跨度：量化后吸附到 `supportedSpans` 中 L1 距离最近的一个。
    ///
    /// - Returns: 吸附后的跨度；`supportedSpans` 为空时返回 nil（调用方保持原样）。
    ///
    /// 距离相同时取数组中第一个——与抽出前一致（严格 `<` 才替换），顺序
    /// 依赖 `supportedSpans` 自身的稳定性，不要在调用方依赖具体顺序。
    static func resolve(
        base: GridSpan,
        translation: CGSize,
        current: GridSpan,
        supportedSpans: [GridSpan],
        metrics: GridMetrics,
        columnUpperBound: Int = DrawerResizeLimits.legacyColumnUpperBound
    ) -> GridSpan? {
        let raw = quantized(
            base: base,
            translation: translation,
            current: current,
            metrics: metrics,
            columnUpperBound: columnUpperBound
        )
        var nearest: GridSpan?
        var nearestDistance = Int.max
        for span in supportedSpans {
            let distance = abs(span.columns - raw.columns) + abs(span.rows - raw.rows)
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = span
            }
        }
        return nearest
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
