import CoreGraphics

// MARK: - 落点区域判定

/// 屏幕点落在抽屉面板的哪个区域。
///
/// 从 `BlockDropTargeting.dropZone` 里剥出来的**纯几何**：不碰
/// `BlockDragCoordinator.Payload`，因此可脱离 AppKit、插件系统与窗口
/// 层级直接测试。
struct DrawerDropPolicy: Equatable, Sendable {
    var visibleFrame: CGRect
    var compactHeight: CGFloat
    var gridTopEdgeY: CGFloat

    init(visibleFrame: CGRect, compactHeight: CGFloat, gridTopEdgeY: CGFloat) {
        self.visibleFrame = visibleFrame
        self.compactHeight = compactHeight
        self.gridTopEdgeY = gridTopEdgeY
    }

    init(mapper: DrawerScreenMapper, compactHeight: CGFloat) {
        self.init(
            visibleFrame: mapper.visibleFrame,
            compactHeight: compactHeight,
            gridTopEdgeY: mapper.gridTopEdgeY
        )
    }

    enum Region: Equatable, Sendable {
        /// 面板之外。
        case outside
        /// 岛顶紧凑带（快速区）。
        case compact
        /// 顶栏（齿轮 / 钉住等按钮所在横条）：不接受落点。
        case topBar
        /// 抽屉网格。
        case grid
    }

    func region(of point: CGPoint) -> Region {
        guard visibleFrame.contains(point) else { return .outside }
        // 命中区取**整条可见面板顶部的紧凑带高度**，不是 `pair.hotFrame`——
        // 后者宽度只够绕刘海的带本体，拖到岛顶两侧会被误判成网格区，
        // 快捷按钮因此"放不进快速区"。
        if point.y >= visibleFrame.maxY - compactHeight { return .compact }
        if point.y > gridTopEdgeY { return .topBar }
        return .grid
    }
}
