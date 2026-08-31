import CoreGraphics
import NotchCenterKit

// MARK: - 格

/// 网格中的一个矩形区域（列 / 行 + 跨度）。
///
/// 拖拽落点、缩放跨度、渲染位置统一用它，避免各处散传
/// `(column, row, columns, rows)` 四元组后再各自拼一遍公式。
struct GridCell: Equatable, Hashable, Sendable {
    var column: Int
    var row: Int
    var columnSpan: Int
    var rowSpan: Int

    init(column: Int, row: Int, columnSpan: Int, rowSpan: Int) {
        self.column = column
        self.row = row
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }

    init(_ placement: PlacedBlock) {
        self.init(
            column: placement.originColumn,
            row: placement.originRow,
            columnSpan: placement.widthColumns,
            rowSpan: placement.heightRows
        )
    }

    var span: GridSpan { GridSpan(columns: columnSpan, rows: rowSpan) }

    /// 最低占用行（exclusive）：网格容器高度按它算。
    var bottomRow: Int { row + rowSpan }
}

// MARK: - 网格 ↔ 内容像素

/// 网格坐标 ↔ 网格**内容**像素（原点 = 网格内容左上角，y 向下）。
///
/// 注意与 `LayoutEngineGeometry.frame(for:)` 的区别：后者用**绝对列**
/// （`originColumn × step`，不减左列），喂给插件的 `layoutInfo.frame`；
/// 本类型用于渲染，横坐标 = `(column − leftColumn) × step`。两套坐标系
/// 并存是有意的（插件只读 `frame.size`），不要合并。
struct DrawerGridGeometry: Equatable, Sendable {
    var metrics: GridMetrics
    /// 渲染基准列（= `LayoutEngine.gridLeftColumn()`，左扩时为负）。
    var leftColumn: Int
    /// 列容量（= `LayoutEngine.effectiveMaxColumns()`）：落点夹紧用。
    /// 只做渲染换算、不涉及落点的调用点可传 `.max`。
    var capacity: Int
    /// 行/列下限（= `LayoutEngine.minimumRowCount()` / `minimumColumnCount()`）。
    /// 网格容器高度与窗口高度必须按**同一份**下限夹紧：只夹窗口会让容器比可视区
    /// 矮，落在留白格里的块与占位框被 ScrollView 裁掉。不给默认值——各构造点显式传。
    var minimumRows: Int
    var minimumColumns: Int

    func x(column: Int) -> CGFloat { CGFloat(column - leftColumn) * metrics.stepWidth }
    func y(row: Int) -> CGFloat { CGFloat(row) * metrics.stepHeight }
    func size(columns: Int, rows: Int) -> CGSize { metrics.size(columns: columns, rows: rows) }

    /// 内容坐标系中的 frame（渲染定位与网格容器高度共用）。
    func frame(_ cell: GridCell) -> CGRect {
        CGRect(
            x: x(column: cell.column),
            y: y(row: cell.row),
            width: metrics.width(columns: cell.columnSpan),
            height: metrics.height(rows: cell.rowSpan)
        )
    }

    func center(_ cell: GridCell) -> CGPoint {
        let rect = frame(cell)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// `frame(_:)` 的逆：内容坐标点 → 所在格（跨度恒为 1，调用方再赋跨度）。
    ///
    /// 除法带 1e-6 容差：步长非整数时 `n × step / step` 可能因浮点误差
    /// 落到 n−1，取 floor 就错了一整格。
    func cell(at point: CGPoint) -> GridCell {
        GridCell(
            column: leftColumn + Int(floor(point.x / metrics.stepWidth + 1e-6)),
            row: Int(floor(point.y / metrics.stepHeight + 1e-6)),
            columnSpan: 1,
            rowSpan: 1
        )
    }

    /// 落点夹紧：行非负（网格不支持负行）；列 ∈ [leftColumn, leftColumn + capacity − span]。
    ///
    /// 容量不足跨度时上界退化为 `leftColumn`（保证区间非空），与原实现一致。
    func clamped(_ cell: GridCell) -> GridCell {
        let upperColumn = max(leftColumn + capacity - cell.columnSpan, leftColumn)
        return GridCell(
            column: min(max(cell.column, leftColumn), upperColumn),
            row: max(cell.row, 0),
            columnSpan: cell.columnSpan,
            rowSpan: cell.rowSpan
        )
    }

    /// 一组格的最低占用行（不低于 `minimumRows`）。
    func bottomRow(of cells: [GridCell]) -> Int {
        max(cells.map(\.bottomRow).max() ?? minimumRows, minimumRows)
    }

    /// 覆盖这组格所需的内容高度。
    ///
    /// 网格容器高度必须与窗口高度同相收缩：按已提交布局的旧行高算会让
    /// 内容比可视区高一截，ScrollView 随之反复亮灭滚动条。
    func contentHeight(covering cells: [GridCell]) -> CGFloat {
        metrics.height(rows: bottomRow(of: cells))
    }
}

// MARK: - 内容像素 ↔ 屏幕像素

/// 网格内容 ↔ 屏幕像素（Cocoa，左下原点）。
///
/// `drawerDropZone`（屏幕 → 格）与 `drawerScreenRect`（格 → 屏幕）的唯一
/// 换算桥。互逆性由**结构**保证——`screenPoint` 与 `contentPoint` 是同一
/// 表达式的正逆，不再依赖"两处改同一套常量"的注释约定；
/// `DrawerGridGeometryTests` 用往返测试钉住。
struct DrawerScreenMapper: Equatable, Sendable {
    /// 可见面板屏幕矩形（Cocoa，y 向上）= `visibleDrawerFrame(for:)`。
    var visibleFrame: CGRect
    /// 网格内容顶缘自可见面板顶缘向下的距离 = 紧凑带 + 顶栏。
    var topInset: CGFloat
    var geometry: DrawerGridGeometry

    /// 网格内容顶缘的屏幕 y。
    var gridTopEdgeY: CGFloat { visibleFrame.maxY - topInset }

    func screenPoint(fromContent point: CGPoint) -> CGPoint {
        CGPoint(
            x: visibleFrame.minX + geometry.metrics.contentPadding + point.x,
            y: gridTopEdgeY - point.y
        )
    }

    /// `screenPoint` 的严格逆。
    func contentPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - visibleFrame.minX - geometry.metrics.contentPadding,
            y: gridTopEdgeY - point.y
        )
    }

    func screenRect(fromContent rect: CGRect) -> CGRect {
        let topLeft = screenPoint(fromContent: rect.origin)
        // Cocoa 的 CGRect origin 在左下：顶缘减高度即底边。
        return CGRect(
            x: topLeft.x,
            y: topLeft.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    func screenRect(for cell: GridCell) -> CGRect {
        screenRect(fromContent: geometry.frame(cell))
    }

    /// 屏幕点 → 落点格。顶栏及以上返回 nil；列已按容量夹紧。
    func cell(atScreen point: CGPoint, span: GridSpan) -> GridCell? {
        guard geometry.metrics.stepWidth > 0, geometry.metrics.stepHeight > 0 else { return nil }
        guard point.y <= gridTopEdgeY else { return nil }
        var cell = geometry.cell(at: contentPoint(fromScreen: point))
        cell.columnSpan = span.columns
        cell.rowSpan = span.rows
        return geometry.clamped(cell)
    }
}
