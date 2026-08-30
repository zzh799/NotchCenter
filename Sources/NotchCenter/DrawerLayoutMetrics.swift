import CoreGraphics

// MARK: - 抽屉布局指标

/// 一次面板尺寸更新要写入 `PanelUIState` 的全部几何。
struct DrawerLayoutMetrics: Equatable {
    /// 网格内容尺寸（网格容器高度按它算，内容 ≡ 可视区才不闪滚动条）。
    var contentSize: CGSize
    /// 可见面板尺寸（`uiState.drawerWindowSize`，唯一的 spring 动画真源）。
    var windowSize: CGSize
    /// 渲染基准列。**nil = 调用方不得写 `drawerGridLeftColumn`**。
    ///
    /// 落点预览（从设置面板拖入）时块还没动，写左列等于让全体块横移，
    /// 与「拖动期间其余块零位移」直接冲突。此前这只是 `applyDropPreview
    /// WindowSize` 上的一句注释约束，漏改就是一次全体横移的视觉 bug；
    /// 变成 optional 后由类型保证。
    var leftColumn: Int?
}

/// 面板尺寸指标的**纯计算**：此前散在两个 `apply*WindowSize` 里各自算一遍，
/// 抽出来后可脱离窗口与 `PanelUIState` 测试。
enum DrawerLayoutMetricsResolver {
    /// 块**已被推挤**的预览（缩放 / 抽屉内重排）：必须重算左列。
    static func pushed(
        columnRange: (min: Int, max: Int),
        bottomRow: Int,
        geometry: DrawerGridGeometry,
        maxHeight: CGFloat?
    ) -> DrawerLayoutMetrics {
        let span = min(max(columnRange.max - columnRange.min, 1), geometry.capacity)
        return make(
            columns: span,
            rows: bottomRow,
            geometry: geometry,
            maxHeight: maxHeight,
            leftColumn: columnRange.min
        )
    }

    /// 只有**占位框**的预览（从设置面板拖入）：左列恒为 nil。
    static func dropZone(
        leftColumn: Int,
        rightEdge: Int,
        rows: Int,
        geometry: DrawerGridGeometry,
        maxHeight: CGFloat?
    ) -> DrawerLayoutMetrics {
        let span = min(max(rightEdge - leftColumn, 1), geometry.capacity)
        return make(
            columns: span,
            rows: rows,
            geometry: geometry,
            maxHeight: maxHeight,
            leftColumn: nil
        )
    }

    private static func make(
        columns: Int,
        rows: Int,
        geometry: DrawerGridGeometry,
        maxHeight: CGFloat?,
        leftColumn: Int?
    ) -> DrawerLayoutMetrics {
        let metrics = geometry.metrics
        let rowCount = max(rows, 1)
        var windowSize = CGSize(
            width: metrics.width(columns: columns) + metrics.contentPadding * 2,
            // 顶部不再预留 padding：内容栈从顶栏直接开始，多加一项只会
            // 落到 ScrollView 底部与内容自身 bottom padding 叠加。
            height: metrics.topBarHeight
                + metrics.height(rows: rowCount)
                + metrics.contentPadding
        )
        // 超出屏幕可用高度时封顶（网格 ScrollView 可视高度随之压缩）。
        if let maxHeight, windowSize.height > maxHeight {
            windowSize.height = maxHeight
        }
        return DrawerLayoutMetrics(
            contentSize: metrics.size(columns: columns, rows: rowCount),
            windowSize: windowSize,
            leftColumn: leftColumn
        )
    }
}
