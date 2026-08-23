import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉面板（文档 §5.3 / §5.5）

/// 抽屉网格元素：已放置块 + 视图 + 支持的尺寸。
struct DrawerElement: Identifiable {
    let placement: PlacedBlock
    let view: AnyView
    /// 支持的完整跨度集合（列数 × 行数，来自块声明的 supportedSpans）。
    let supportedSpans: [GridSpan]
    /// 当前已提交的跨度（与 placement 一致；布局遗留数据可能为 nil）。
    let currentSpan: GridSpan?

    var id: String { placement.placementID }
}

struct DrawerActions {
    let onShowSettings: () -> Void
    let onTogglePin: () -> Void
    let onToggleEdit: () -> Void
    let onCollapse: () -> Void
    let onRemoveBlock: (String) -> Void
    let onMoveBlock: (String, Int, Int) -> Void
    let onResizeBlock: (String, Int, Int) -> Void
    let onAddBlock: (String, String) -> Void
    /// 编辑模式一键重排：按阅读顺序紧密排布所有抽屉块。
    let onReorderBlocks: () -> Void
    /// 拖拽实时预览：返回全体块的新位置（不落盘）。
    let onPreviewMove: (String, Int, Int) -> [String: LayoutEngine.GridOrigin]
    /// 缩放实时预览：返回全体块的新位置（下方块推挤下移，不落盘）。
    let onPreviewResize: (String, Int, Int) -> [String: LayoutEngine.GridOrigin]
    /// 拖拽结束提交（含自动重排）。
    let onCommitDrag: (String, Int, Int) -> Void
}

struct DrawerPanelView: View {
    @ObservedObject var ui: PanelUIState
    /// 抽屉展开所在屏幕的几何（岛顶紧凑带、收起尺寸都按该屏刘海计算；
    /// 抽屉只会在 activePair 上展示，故用所属 pair 的布局）。
    var layout: NotchLayout
    /// 岛顶的紧凑区（刘海高度带）：随抽屉一起作为“岛体”展示，视觉融合。
    var compactView: CompactPanelView
    let actions: DrawerActions

    /// 抽屉内容淡入淡出（参考 codex-island 的 contentVisible 节奏：
    /// 展开后段淡入、收起时先淡出再缩形）。
    @State private var contentVisible = false

    private let cornerRadius: CGFloat = 18

    var body: some View {
        // 参考codex-island 的 model.size 模式：容器 frame 直接绑定
        // `ui.drawerWindowSize`（唯一动画真源，收起 = 紧凑带尺寸），展开/
        // 收起/增删块的一切尺寸变化都是这个 frame 的 spring 变形；抽屉
        // 内容条件存在并延迟淡入。窗口 frame 永不参与动画（固定满高）。
        VStack(spacing: 0) {
            // 与独立紧凑面板完全相同的尺寸并水平居中：
            // 保证展开动画前后图标在屏幕上的绝对位置不变。
            compactView
                .frame(
                    width: layout.compactSize.width,
                    height: layout.compactSize.height
                )
                .frame(maxWidth: .infinity)

            if ui.isDrawerExpanded {
                content
                    .opacity(contentVisible ? 1 : 0)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(
            width: ui.drawerWindowSize.width,
            height: ui.drawerWindowSize.height + layout.compactSize.height,
            // 顶缘钉死：收起时 content 退出布局（其快照在移除过渡期间仍
            // 挂在树里），VStack 与仍在收缩的容器高度不一致——默认的
            // .center 会把只剩紧凑带的 VStack 居中/顶出容器，图标随之下坠。
            // .top 让岛顶紧凑带（及图标）在展开/收起全程保持屏幕绝对位置不变。
            alignment: .top
        )
        .background(
            TopAttachedRoundedShape(radius: cornerRadius)
                .fill(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
        )
        .clipShape(TopAttachedRoundedShape(radius: cornerRadius))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .overlay(alignment: .top) {
            TopAttachedRoundedShape(radius: cornerRadius)
                .stroke(.white.opacity(0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(ui.isDrawerExpanded)
        // 固定满高满宽窗口内顶对齐 + 水平居中：窗口比可见面板高/宽的部分
        // 永远是透明区（命中测试穿透），面板顶缘钉死窗口顶缘、绕屏幕中线
        // 居中——宽度随占用列数自适应时面板始终对准刘海。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: ui.isDrawerExpanded) { _, expanded in
            if expanded {
                // 先让容器形变启动，内容在后段淡入（形变 commit → 内容到达）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard ui.isDrawerExpanded else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        contentVisible = true
                    }
                }
            } else {
                // 收起：内容立即淡出（与缩形重叠 20ms 起步，避免黑块闪现）。
                withAnimation(.easeOut(duration: 0.1)) {
                    contentVisible = false
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: NotchGridMetrics.drawerTopBarHeight)

            // 编辑模式：紧凑带与网格之间插入全宽 AddBlock 目录条，
            // 主面板内容真实下移（不再覆盖网格的浮动侧栏）。
            addBlockStrip

            ScrollView(showsIndicators: true) {
                grid
            }
        }
        .padding(.horizontal, NotchGridMetrics.contentPadding)
        .padding(.bottom, NotchGridMetrics.contentPadding)
    }

    /// 高度 0 ↔ 目标值的弹性过渡：目录条淡入淡出，网格同步下移
    /// （spring 参数与块拖拽/缩放一致，文档 §5.5）。
    private var addBlockStrip: some View {
        Group {
            if ui.isEditing {
                AddBlockArea(
                    plugins: ui.catalogPlugins,
                    canAddCompact: ui.canAddCompact,
                    onAddBlock: actions.onAddBlock
                )
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ui.isEditing)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            // 原标题位置改为设置按钮（accessory 应用无菜单栏，这是常驻入口）。
            topBarButton(
                systemImage: "gearshape",
                help: "Settings",
                action: actions.onShowSettings,
                tint: .white.opacity(0.65)
            )

            Spacer(minLength: 0)

            // 编辑模式隐藏钉住按钮，其槽位让给一键重排（编辑按钮左边）；
            // 钉住状态保留，退出编辑后恢复显示——槽位固定，编辑/关闭按钮不跳动。
            if ui.isEditing {
                topBarButton(
                    systemImage: "arrow.down.forward.and.arrow.up.backward",
                    help: "Tidy layout (top-to-bottom, left-to-right)",
                    action: actions.onReorderBlocks,
                    tint: .white.opacity(0.9)
                )
                .transition(.opacity)
            } else {
                topBarButton(
                    systemImage: ui.isPinned ? "pin.fill" : "pin",
                    help: ui.isPinned ? "Unpin drawer" : "Pin drawer open",
                    action: actions.onTogglePin,
                    tint: ui.isPinned ? .white.opacity(0.9) : .white.opacity(0.65)
                )
                .transition(.opacity)
            }

            topBarButton(
                systemImage: ui.isEditing ? "pencil.slash" : "pencil",
                help: ui.isEditing ? "Done editing layout" : "Edit layout",
                action: actions.onToggleEdit,
                tint: ui.isEditing ? .white.opacity(0.9) : .white.opacity(0.65)
            )

            topBarButton(
                systemImage: "chevron.down",
                help: "Close drawer",
                action: actions.onCollapse,
                tint: .white.opacity(0.65)
            )
        }
        .padding(.horizontal, 4)
    }

    private func topBarButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void,
        tint: Color
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.055))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ui.drawerElements) { element in
                let origin = resolveOrigin(for: element)
                DrawerBlockContainer(
                    element: element,
                    isEditing: ui.isEditing,
                    isDragging: draggingPlacementID == element.id,
                    previewColumns: resizingPlacementID == element.id ? resizePreviewColumns : nil,
                    previewRows: resizingPlacementID == element.id ? resizePreviewRows : nil,
                    onResizeChanged: { translation in
                        handleResizeTranslate(translation, for: element)
                    },
                    onResizeCommit: { commitResize(for: element) },
                    onRemove: { actions.onRemoveBlock(element.id) },
                    onDragChanged: { translation in
                        draggingPlacementID = element.id
                        let target = dragTarget(for: element, translation: translation)
                        previewPositions = actions.onPreviewMove(element.id, target.0, target.1)
                    },
                    onDragEnded: { translation in
                        let target = dragTarget(for: element, translation: translation)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            previewPositions = [:]
                        }
                        draggingPlacementID = nil
                        actions.onCommitDrag(element.id, target.0, target.1)
                    }
                )
                .frame(
                    width: element.placement.widthColumns > 0
                        ? gridWidth(columns: element.placement.widthColumns)
                        : 0,
                    height: element.placement.heightRows > 0
                        ? gridHeight(rows: element.placement.heightRows)
                        : 0
                )
                .position(
                    x: gridX(column: origin.column)
                        + gridWidth(columns: element.placement.widthColumns) / 2,
                    y: gridY(row: origin.row)
                        + gridHeight(rows: element.placement.heightRows) / 2
                )
            }
        }
        .frame(
            width: ui.drawerContentSize.width,
            height: gridFrameHeight,
            alignment: .topLeading
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ui.drawerElements.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ui.drawerElements.map(\.placement))
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: previewPositions)

    }

    /// 网格高度：预览可能把块压到（或长到）提交布局之外，按预览最低行扩展
    /// （窗口由控制器同步增高），避免预览块被 ScrollView 裁掉。正在缩放的
    /// 块以预览行数计——模型里的 heightRows 还是旧值，底层块长高时它是
    /// 唯一增高来源。
    private var gridFrameHeight: CGFloat {
        let previewRows = ui.drawerElements
            .map { element -> Int in
                let origin = resolveOrigin(for: element)
                let rows = resizingPlacementID == element.id
                    ? (resizePreviewRows ?? element.placement.heightRows)
                    : element.placement.heightRows
                return origin.row + rows
            }
            .max() ?? 1
        return max(
            ui.drawerContentSize.height,
            NotchGridMetrics.contentHeight(rows: previewRows)
        )
    }

    @State private var previewPositions: [String: LayoutEngine.GridOrigin] = [:]
    @State private var draggingPlacementID: String?
    /// 缩放预览：正在调整的块及其目标跨度（由父视图持有，跨手势中断稳定）。
    @State private var resizingPlacementID: String?
    @State private var resizePreviewColumns: Int?
    @State private var resizePreviewRows: Int?

    /// 缩放位移 → 目标跨度。按下瞬间位移为零，目标即当前尺寸（不会瞬间缩小）。
    /// 量化经 `ResizeHysteresis` 死区迟滞：连续位移越过当前预览的半格边界
    /// 加余量后才换档，边界两侧形成稳定带——朴素的 round() 会在半格边界处
    /// 随 ±1px 抖动在相邻整数间来回翻转，预览随之在原尺寸与目标尺寸间闪烁
    /// （历史上用“候选距离 +1”做余量，整数 L1 距离下等价于“更近即切换”，
    /// 实际没有死区）。基准仍固定为按下时的 placement，除当前预览外无路径
    /// 依赖状态，不依赖手势重启启发式。
    private func handleResizeTranslate(_ translation: CGSize, for element: DrawerElement) {
        if resizingPlacementID != element.id {
            resizingPlacementID = element.id
            resizePreviewColumns = element.placement.widthColumns
            resizePreviewRows = element.placement.heightRows
        }

        let stepW = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing
        let stepH = NotchGridMetrics.cellHeight + NotchGridMetrics.spacing
        let continuousColumns = CGFloat(element.placement.widthColumns) + translation.width / stepW
        let continuousRows = CGFloat(element.placement.heightRows) + translation.height / stepH

        let currentColumns = resizePreviewColumns ?? element.placement.widthColumns
        let currentRows = resizePreviewRows ?? element.placement.heightRows

        let rawColumns = min(
            max(ResizeHysteresis.quantized(continuousColumns, current: currentColumns), 1),
            4
        )
        let rawRows = min(
            max(ResizeHysteresis.quantized(continuousRows, current: currentRows), 1),
            6
        )

        // 候选跨度中离原始目标最近的那个。
        var nearest: GridSpan?
        var nearestDistance = Int.max
        for span in element.supportedSpans {
            let distance = abs(span.columns - rawColumns) + abs(span.rows - rawRows)
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = span
            }
        }
        guard let candidate = nearest else { return }

        let previousColumns = resizePreviewColumns
        let previousRows = resizePreviewRows
        resizePreviewColumns = candidate.columns
        resizePreviewRows = candidate.rows

        // 预览跨度变化时同步推挤下方块（下方整块实时下移，面板随之增高）。
        if previousColumns != candidate.columns || previousRows != candidate.rows {
            previewPositions = actions.onPreviewResize(element.id, candidate.columns, candidate.rows)
        }

        #if DEBUG
        ResizeProbeLog.resizeEvent(
            translation: translation,
            continuousColumns: continuousColumns,
            continuousRows: continuousRows,
            preview: candidate
        )
        #endif
    }

    /// 松手提交预览跨度（预览始终 ∈ supportedSpans，所见即所得）。
    /// 与当前一致时也走提交路径：清空推挤预览并让引擎按需压实/回落面板高度。
    private func commitResize(for element: DrawerElement) {
        defer {
            resizingPlacementID = nil
            resizePreviewColumns = nil
            resizePreviewRows = nil
        }
        guard let columns = resizePreviewColumns, let rows = resizePreviewRows else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            previewPositions = [:]
        }
        actions.onResizeBlock(element.id, columns, rows)
    }

    private func resolveOrigin(for element: DrawerElement) -> LayoutEngine.GridOrigin {
        if let preview = previewPositions[element.id],
           draggingPlacementID != element.id {
            return preview
        }
        return LayoutEngine.GridOrigin(
            column: element.placement.originColumn,
            row: element.placement.originRow
        )
    }

    private func dragTarget(
        for element: DrawerElement,
        translation: CGSize
    ) -> (Int, Int) {
        let cellWidth = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing
        let cellHeight = NotchGridMetrics.cellHeight + NotchGridMetrics.spacing
        let deltaColumns = Int((translation.width / cellWidth).rounded())
        let deltaRows = Int((translation.height / cellHeight).rounded())
        return (
            element.placement.originColumn + deltaColumns,
            element.placement.originRow + deltaRows
        )
    }

    private func gridX(column: Int) -> CGFloat {
        CGFloat(column) * (NotchGridMetrics.cellWidth + NotchGridMetrics.spacing)
    }

    private func gridY(row: Int) -> CGFloat {
        CGFloat(row) * (NotchGridMetrics.cellHeight + NotchGridMetrics.spacing)
    }

    private func gridWidth(columns: Int) -> CGFloat {
        NotchGridMetrics.contentWidth(columns: columns)
    }

    private func gridHeight(rows: Int) -> CGFloat {
        NotchGridMetrics.contentHeight(rows: rows)
    }
}
