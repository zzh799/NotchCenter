import CoreGraphics
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉交互状态

/// 抽屉内拖拽 / 缩放的手势状态中枢。
///
/// 此前这些状态是 `DrawerPanelView` 上 5 个互不相干的 `@State`
/// （`previewPositions` / `draggingPlacementID` / `resizingPlacementID` /
/// `resizePreviewColumns/Rows`），散落在手势回调里各自维护，且视图无法在
/// 单测里构造——所以这 5 个字段背后的时序契约（松手顺序、清空的动画语义）
/// 一个测试都没有。
///
/// 收进本类型后：手势阶段是一个 `Phase`（拖拽与缩放天然互斥），
/// 状态迁移集中在少数几个方法里，测试用假 `Bridge` 就能完整驱动。
@MainActor
final class DrawerInteractionState: ObservableObject {
    /// 手势阶段。拖拽与缩放互斥（握把用 `highPriorityGesture` 压过块体手势）。
    enum Phase: Equatable {
        case idle
        case dragging(placementID: String)
        case resizing(placementID: String, span: GridSpan)
    }

    /// 与引擎 / 控制器之间的唯一接口。
    ///
    /// 刻意**不持有** `LayoutEngine` 或 `NotchPanelController`：那会形成
    /// 循环引用，也让测试必须构造整个面板（需要真实窗口）。
    struct Bridge {
        var previewMove: (_ id: String, _ column: Int, _ row: Int) -> [String: LayoutEngine.GridOrigin]
        var previewResize: (_ id: String, _ columns: Int, _ rows: Int) -> [String: LayoutEngine.GridOrigin]
        var commitMove: (_ id: String, _ column: Int, _ row: Int) -> Void
        var commitResize: (_ id: String, _ columns: Int, _ rows: Int) -> Void
        var setReorderPreview: (LayoutEngine.GridOrigin?, GridSpan?) -> Void
    }

    @Published private(set) var phase: Phase = .idle

    /// 全体块（含被拖块）推挤后的新位置：**预览即最终布局**的唯一载体。
    @Published private(set) var previewOrigins: [String: LayoutEngine.GridOrigin] = [:]

    private let bridge: Bridge

    /// 缩放按下瞬间的跨度：后续所有位移都相对它折算，跨手势事件保持稳定。
    private var resizeBase: GridSpan?

    init(bridge: Bridge) {
        self.bridge = bridge
    }

    // MARK: 查询

    var draggingPlacementID: String? {
        if case .dragging(let placementID) = phase { return placementID }
        return nil
    }

    var resizingPlacementID: String? {
        if case .resizing(let placementID, _) = phase { return placementID }
        return nil
    }

    /// 缩放预览跨度：容器按它渲染（松手前就能看到新尺寸）。
    func previewSpan(for placementID: String) -> GridSpan? {
        if case .resizing(let id, let span) = phase, id == placementID { return span }
        return nil
    }

    func isResizing(_ placementID: String) -> Bool {
        resizingPlacementID == placementID
    }

    /// 渲染原点：预览优先，但**被拖块自身除外**——它的位置由容器的
    /// `dragOffset` 跟着光标走。
    func resolveOrigin(
        placementID: String,
        committed: LayoutEngine.GridOrigin
    ) -> LayoutEngine.GridOrigin {
        if let preview = previewOrigins[placementID], draggingPlacementID != placementID {
            return preview
        }
        return committed
    }

    // MARK: 拖拽

    func beginDrag(_ placementID: String) {
        // 缩放期间不接管：握把手势优先。
        guard resizingPlacementID == nil else { return }
        phase = .dragging(placementID: placementID)
    }

    /// 拖动中：算出推挤后的全体原点并写回，被拖块落点喂给占位框。
    func updateDrag(_ placementID: String, column: Int, row: Int, span: GridSpan) {
        let origins = bridge.previewMove(placementID, column, row)
        // 被拖块不在结果里（例如块已被移除）时保持现状，不写半截预览。
        guard let dragged = origins[placementID] else { return }
        previewOrigins = origins
        bridge.setReorderPreview(dragged, span)
    }

    func endDrag(_ placementID: String, column: Int, row: Int) {
        // 无动画清空：缩放 / 推挤遗留的预览不该在落位时闪一下。
        if !previewOrigins.isEmpty { previewOrigins = [:] }

        // 回到 idle 必须**早于**提交：否则 `resolveOrigin` 那一帧仍走
        //「排除被拖块」分支，块会先弹回原位再瞬移到落点。
        phase = .idle
        bridge.setReorderPreview(nil, nil)
        bridge.commitMove(placementID, column, row)
    }

    // MARK: 缩放

    func updateResize(
        _ placementID: String,
        translation: CGSize,
        placement: PlacedBlock,
        supportedSpans: [GridSpan],
        metrics: GridMetrics
    ) {
        if resizingPlacementID != placementID {
            // 按下瞬间：基准 = 当前提交跨度，预览从它起步（不会瞬间缩小）。
            let base = GridSpan(columns: placement.widthColumns, rows: placement.heightRows)
            resizeBase = base
            phase = .resizing(placementID: placementID, span: base)
        }
        guard let base = resizeBase,
              case .resizing(_, let current) = phase,
              let candidate = ResizeSpanResolver.resolve(
                  base: base,
                  translation: translation,
                  current: current,
                  supportedSpans: supportedSpans,
                  metrics: metrics
              ) else { return }

        guard candidate != current else { return }
        phase = .resizing(placementID: placementID, span: candidate)
        // 预览跨度变化时同步推挤下方块（下方整块实时下移，面板随之增高）。
        previewOrigins = bridge.previewResize(placementID, candidate.columns, candidate.rows)
    }

    func commitResize(_ placementID: String) {
        // 无论是否真的提交，预览状态都必须清干净（手势已结束）。
        defer {
            phase = .idle
            resizeBase = nil
        }
        guard case .resizing(_, let span) = phase else { return }
        // 缩放提交**带 spring** 清空推挤预览——与拖拽的无动画清空语义不同，
        // 这里要看着下方块平滑落回压实后的位置。
        withAnimation(DrawerAnimation.spring) {
            previewOrigins = [:]
        }
        bridge.commitResize(placementID, span.columns, span.rows)
    }

    // MARK: 复位

    /// 复位：抽屉收起 / 退出编辑 / 会话被打断。
    ///
    /// 收起后 `content` 会退出布局，但本对象仍随面板存活——不清的话残留的
    /// 预览原点会让块在下次展开时停在旧预览位置。
    func reset() {
        phase = .idle
        previewOrigins = [:]
        resizeBase = nil
        bridge.setReorderPreview(nil, nil)
    }
}
