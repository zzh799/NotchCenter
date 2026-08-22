import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 紧凑区面板（文档 §5.2）

/// 紧凑面板元素：一个槽位及其块视图。
struct CompactElement: Identifiable {
    let slotIndex: Int
    let reference: CompactSlotReference?
    let block: NotchBlock?
    let view: AnyView?
    let frame: CGRect

    var id: Int { slotIndex }
}

struct CompactActions {
    let onRemoveBlock: (Int) -> Void
    let onTapBackground: () -> Void
    let onExpand: () -> Void
    /// 添加紧凑块（编辑模式“+”菜单，文档 §5.5）。
    let onAddCompact: (String, String) -> Void
}

/// 紧凑块目录项（编辑模式“+”菜单用）。
struct CompactCatalogItem: Identifiable {
    let pluginID: String
    let blockID: String
    let displayName: String

    var id: String { pluginID + "." + blockID }
}

struct CompactPanelView: View {
    @ObservedObject var ui: PanelUIState
    let actions: CompactActions
    /// 是否自绘黑色底衬（独立热区窗口为 true；嵌入抽屉岛顶时为 false，
    /// 由抽屉统一背景提供，避免叠加描边/阴影）。
    var showsBand = true

    @State private var isHovering = false

    private let cornerRadius: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let isEditing = ui.isEditing
            let strip = ui.compactLayout.compactStrip
            let panelHeight = proxy.size.height

            // .top 对齐让黑色带在窗口内水平居中（其余元素均为绝对定位），
            // 与抽屉遮罩的中心对称展开、刘海位置保持一致。
            ZStack(alignment: .top) {
                // 整条黑色填充带：横跨左右面板并覆盖刘海区域，
                // 与刘海融为一体（灵动岛观感，文档 §5.2）。
                if showsBand {
                    TopAttachedRoundedShape(radius: cornerRadius)
                        .fill(
                            Color(red: 0.02, green: 0.02, blue: 0.025)
                                .opacity(isHovering ? 0.99 : 0.96)
                        )
                        .overlay {
                            TopAttachedRoundedShape(radius: cornerRadius)
                                .stroke(.white.opacity(isHovering ? 0.15 : 0.09), lineWidth: 1)
                        }
                        .shadow(
                            color: .black.opacity(isHovering ? 0.32 : 0.18),
                            radius: 12,
                            y: 5
                        )
                        .frame(width: strip.rightPanelX + strip.rightPanelWidth, height: panelHeight)
                }

                // click 模式下的悬停指示条（位于刘海中央）。
                if ui.showsClickModeHint, isHovering, !isEditing {
                    Capsule()
                        .fill(.white.opacity(0.72))
                        .frame(width: 48, height: 2)
                        .shadow(color: .white.opacity(0.32), radius: 4)
                        .position(x: strip.notchCenterX, y: 7)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }

                // 点击热区：整帧可交互，点击空白处展开抽屉（块视图在上层优先响应）。
                Color.black.opacity(0.0001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: actions.onTapBackground)

                ForEach(ui.compactElements) { element in
                    if let view = element.view {
                        let rect = strip.slotRect(at: element.slotIndex) ?? .zero
                        CompactBlockContainer(
                            element: element,
                            view: view,
                            isEditing: isEditing,
                            onRemove: { actions.onRemoveBlock(element.slotIndex) },
                            onExpand: actions.onExpand
                        )
                        .position(x: rect.midX, y: rect.midY)
                    }
                }

                // 编辑模式：“+”添加紧凑块（右侧面板之外的预留区）。
                if isEditing {
                    addCompactButton
                        .position(strip.editButtonPoint)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var addCompactButton: some View {
        Menu {
            ForEach(ui.compactCatalog) { item in
                Button {
                    actions.onAddCompact(item.pluginID, item.blockID)
                } label: {
                    Text(item.displayName)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(
                    width: NotchGeometry.compactSlotSize.width,
                    height: NotchGeometry.compactSlotSize.height
                )
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                        .fill(.white.opacity(0.05))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // macOS Menu 会按菜单项内容撑宽标签，需显式约束为槽位大小，
        // 否则 .position 定位时图标会偏离（标签左对齐于超宽 frame）。
        .frame(
            width: NotchGeometry.compactSlotSize.width,
            height: NotchGeometry.compactSlotSize.height
        )
        .disabled(!ui.canAddCompact || ui.compactCatalog.isEmpty)
        .help(ui.canAddCompact ? "Add compact block" : "All compact slots are full")
    }
}

/// 紧凑块容器：槽位内的块视图 + 默认点击展开（文档 §6.2）+ 编辑模式移除。
private struct CompactBlockContainer: View {
    let element: CompactElement
    let view: AnyView
    let isEditing: Bool
    let onRemove: () -> Void
    let onExpand: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            group
                .frame(width: NotchGeometry.compactSlotSize.width, height: NotchGeometry.compactSlotSize.height)

            if isEditing {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -2)
                .help("Remove block")
            }
        }
    }

    @ViewBuilder
    private var group: some View {
        if element.block?.interaction == .expandDrawer {
            // 默认交互：点击展开抽屉（文档 §6.2）。
            view
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)
        } else {
            // .custom 交互由插件视图自行处理；核心不拦截点击。
            view
        }
    }
}

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
    let onTogglePin: () -> Void
    let onToggleEdit: () -> Void
    let onCollapse: () -> Void
    let onRemoveBlock: (String) -> Void
    let onMoveBlock: (String, Int, Int) -> Void
    let onResizeBlock: (String, Int, Int) -> Void
    let onAddBlock: (String, String) -> Void
    /// 拖拽实时预览：返回全体块的新位置（不落盘）。
    let onPreviewMove: (String, Int, Int) -> [String: LayoutEngine.GridOrigin]
    /// 拖拽结束提交（含自动重排）。
    let onCommitDrag: (String, Int, Int) -> Void
}

struct DrawerPanelView: View {
    @ObservedObject var ui: PanelUIState
    /// 岛顶的紧凑区（刘海高度带）：随抽屉一起作为“岛体”展示，视觉融合。
    var compactView: CompactPanelView
    let actions: DrawerActions

    private let cornerRadius: CGFloat = 18

    /// 抽屉窗口总高 = 紧凑带 + 内容。
    private var totalHeight: CGFloat {
        ui.drawerWindowSize.height + ui.compactLayout.compactSize.height
    }

    var body: some View {
        // 灵动岛式展开：窗口固定为最终尺寸（含顶部紧凑带），内容经遮罩
        // 从刘海尺寸插值放大，随进度淡入（沿用旧版 revealProgress 方案）。
        VStack(spacing: 0) {
            // 与独立紧凑面板完全相同的尺寸并水平居中：
            // 保证展开动画前后图标在屏幕上的绝对位置不变。
            compactView
                .frame(
                    width: ui.compactLayout.compactSize.width,
                    height: ui.compactLayout.compactSize.height
                )
                .frame(maxWidth: .infinity)
            content
        }
        .frame(width: ui.drawerWindowSize.width, height: totalHeight)
        .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
        .mask(alignment: .top) {
            TopAttachedRoundedShape(radius: revealCornerRadius)
                .frame(width: revealWidth, height: revealHeight)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .overlay(alignment: .top) {
            TopAttachedRoundedShape(radius: revealCornerRadius)
                .stroke(.white.opacity(0.09), lineWidth: 1)
                .frame(width: revealWidth, height: revealHeight)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(ui.isDrawerExpanded)
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                topBar
                    .frame(height: NotchGridMetrics.drawerTopBarHeight)

                ScrollView(showsIndicators: true) {
                    grid
                }
            }
            .padding(.horizontal, NotchGridMetrics.contentPadding)
            .padding(.bottom, NotchGridMetrics.contentPadding)

            if ui.isEditing {
                PluginCatalogSidebar(
                    plugins: ui.catalogPlugins,
                    onAddBlock: actions.onAddBlock
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .opacity(revealedContentOpacity)
    }

    // MARK: 揭示动画几何

    private var strip: CompactStripLayout {
        ui.compactLayout.compactStrip
    }

    /// 起点：紧凑黑色带的宽度与刘海高度（与常驻紧凑区完全重合）。
    private var revealedStartSize: CGSize {
        CGSize(
            width: strip.rightPanelX + strip.rightPanelWidth,
            height: ui.compactLayout.compactSize.height
        )
    }

    private var revealWidth: CGFloat {
        interpolate(from: revealedStartSize.width, to: ui.drawerWindowSize.width)
    }

    private var revealHeight: CGFloat {
        interpolate(from: revealedStartSize.height, to: totalHeight)
    }

    private var revealCornerRadius: CGFloat {
        interpolate(from: 11, to: cornerRadius)
    }

    /// 内容在揭示后段淡入（进度 0.42 → 0.76）。
    private var revealedContentOpacity: CGFloat {
        min(max((ui.revealProgress - 0.42) / 0.34, 0), 1)
    }

    private func interpolate(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * ui.revealProgress
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("NotchCenter")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 0)

            topBarButton(
                systemImage: ui.isPinned ? "pin.fill" : "pin",
                help: ui.isPinned ? "Unpin drawer" : "Pin drawer open",
                action: actions.onTogglePin,
                tint: ui.isPinned ? .white.opacity(0.9) : .white.opacity(0.65)
            )

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
            height: ui.drawerContentSize.height,
            alignment: .topLeading
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ui.drawerElements.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: previewPositions)

    }

    @State private var previewPositions: [String: LayoutEngine.GridOrigin] = [:]
    @State private var draggingPlacementID: String?
    /// 缩放预览：正在调整的块及其目标跨度（由父视图持有，跨手势中断稳定）。
    @State private var resizingPlacementID: String?
    @State private var resizePreviewColumns: Int?
    @State private var resizePreviewRows: Int?

    /// 缩放位移 → 目标跨度。按下瞬间位移为零，目标即当前尺寸（不会瞬间缩小）。
    /// 吸附采用迟滞策略：只有当候选跨度明显更近（余量一个网格单位）时才切换预览，
    /// 边界处的亚像素抖动不会再引起"当前 ↔ 候选"的尺寸闪烁；也不依赖任何
    /// 手势重启启发式——基准固定为按下时的 placement，映射是纯函数、无路径依赖。
    private func handleResizeTranslate(_ translation: CGSize, for element: DrawerElement) {
        if resizingPlacementID != element.id {
            resizingPlacementID = element.id
            resizePreviewColumns = element.placement.widthColumns
            resizePreviewRows = element.placement.heightRows
        }

        let stepW = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing
        let stepH = NotchGridMetrics.cellHeight + NotchGridMetrics.spacing
        let rawColumns = min(
            max(element.placement.widthColumns + Int(round(translation.width / stepW)), 1),
            4
        )
        let rawRows = min(
            max(element.placement.heightRows + Int(round(translation.height / stepH)), 1),
            6
        )
        let rawSpan = GridSpan(columns: rawColumns, rows: rawRows)

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

        // 迟滞：当前预览到目标的距离比候选多出至少一个网格单位才切换，
        // 否则保持现状——切换点两侧各留出半个单位的稳定带。
        let currentColumns = resizePreviewColumns ?? element.placement.widthColumns
        let currentRows = resizePreviewRows ?? element.placement.heightRows
        let currentDistance = abs(currentColumns - rawColumns) + abs(currentRows - rawRows)
        let switchedAlready = currentColumns != element.placement.widthColumns
            || currentRows != element.placement.heightRows

        if !switchedAlready || currentDistance >= nearestDistance + 1 {
            resizePreviewColumns = candidate.columns
            resizePreviewRows = candidate.rows
        }
    }

    /// 松手提交预览跨度（预览始终 ∈ supportedSpans，所见即所得）；
    /// 与当前一致时不产生任何操作。
    private func commitResize(for element: DrawerElement) {
        defer {
            resizingPlacementID = nil
            resizePreviewColumns = nil
            resizePreviewRows = nil
        }
        guard let columns = resizePreviewColumns,
              let rows = resizePreviewRows,
              columns != element.currentSpan?.columns || rows != element.currentSpan?.rows else {
            return
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

/// 抽屉块容器：稳定身份 + 块视图 + 编辑模式（文档 §5.5）。
/// - 拖动整块移动：拖动中实时预览（被占用块向下推挤自动重排），松手提交；
/// - 右下角握把拖动调整尺寸，缩放过程中组件左上角保持不动；
/// - 移除按钮跟随块一起移动。
private struct DrawerBlockContainer: View {
    let element: DrawerElement
    let isEditing: Bool
    let isDragging: Bool
    /// 缩放预览目标（由父视图持有；nil 表示未在缩放）。
    let previewColumns: Int?
    let previewRows: Int?
    let onResizeChanged: (CGSize) -> Void
    let onResizeCommit: () -> Void
    let onRemove: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    @State private var dragOffset: CGSize = .zero

    private let cornerRadius: CGFloat = 12

    var body: some View {
        let columns = previewColumns ?? element.placement.widthColumns
        let rows = previewRows ?? element.placement.heightRows
        let width = NotchGridMetrics.contentWidth(columns: columns)
        let height = NotchGridMetrics.contentHeight(rows: rows)
        // 缩放预览补偿：容器被外层按旧尺寸居中定位，内部变大会以中心对称扩张。
        // 把增长量的一半平移回来，使组件左上角始终锚定在原点（原点不随缩放改变）。
        let deltaWidth = width - NotchGridMetrics.contentWidth(columns: element.placement.widthColumns)
        let deltaHeight = height - NotchGridMetrics.contentHeight(rows: element.placement.heightRows)

        // 预览尺寸必须显式套在内容上（含所有 overlay），否则块永远按外层
        // 提案的原始尺寸渲染，补偿偏移会退化成纯位移（上移/下移半行的来源）。
        return element.view
            .frame(width: width, height: height)
            .background(isEditing ? Color.white.opacity(0.03) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if isEditing {
                    // 编辑模式高亮组件边缘。
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            .white.opacity(isDragging || isResizing ? 0.75 : 0.4),
                            lineWidth: isDragging || isResizing ? 1.5 : 1
                        )
                }
            }
            // 编辑模式交互层：屏蔽块内容自身手势（如文本选中），
            // 让拖动/缩放在所有块上行为一致。所有层都用 overlay——
            // 尺寸严格等于内容本身，不会被外层的旧尺寸 proposal 撑大
            // （此前用 ZStack + 弹性子视图，缩小到 1 行时位置会上偏半行）。
            .overlay {
                if isEditing {
                    Color.clear.contentShape(Rectangle())
                }
            }
            .overlay(alignment: .topTrailing) {
                if isEditing {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Remove block")
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isEditing {
                    // 右下角缩放握把：唯一的调整尺寸入口，向右下拖动扩大、
                    // 左上角原点保持不动，松手在支持的尺寸等级间吸附。
                    resizeHandle
                }
            }
            .contentShape(Rectangle())
            .offset(x: deltaWidth / 2, y: deltaHeight / 2)
            .offset(dragOffset)
            .gesture(
                isEditing && !isResizing
                    ? DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            dragOffset = value.translation
                            onDragChanged(value.translation)
                        }
                        .onEnded { value in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                dragOffset = .zero
                            }
                            onDragEnded(value.translation)
                        }
                    : nil
            )
    }

    private var isResizing: Bool {
        previewColumns != nil || previewRows != nil
    }

    // MARK: 编辑控件（跟随块移动）

    @State private var isResizeHandleHovering = false

    /// 右下角缩放握把：对角双箭头图标 + 圆形底衬，悬停/拖动中增亮放大。
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(isResizing ? 0.95 : 0.7))
            .frame(width: 22, height: 22)
            .background {
                Circle()
                    .fill(.white.opacity(isResizing ? 0.28 : 0.14))
                    .overlay {
                        Circle()
                            .stroke(
                                .white.opacity(isResizing ? 0.55 : 0.25),
                                lineWidth: 1
                            )
                    }
            }
            .scaleEffect(isResizing ? 1.12 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isResizing)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .padding(5)
            .contentShape(Rectangle())
            .onHover { isResizeHandleHovering = $0 }
            .background {
                if isResizeHandleHovering, !isResizing {
                    Circle()
                        .fill(.white.opacity(0.08))
                        .padding(2)
                }
            }
            .highPriorityGesture(resizeGesture)
            .help("Drag to resize")
    }

    /// 缩放手势：基于位移增量的目标格数。手势重启的检测与重基准在父视图完成，
    /// 保证中断后从当前预览尺寸继续，不会跳回原始大小或瞬间缩小。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                onResizeChanged(value.translation)
            }
            .onEnded { _ in
                onResizeCommit()
            }
    }
}

// MARK: - 添加块目录（文档 §5.5）

/// 目录侧边栏的插件分组（只列抽屉块；紧凑块由紧凑区槽位旁的“+”添加，文档 §5.5）。
struct CatalogPluginGroup: Identifiable {
    let pluginID: String
    let displayName: String
    let drawerBlocks: [NotchBlock]

    var id: String { pluginID }
}

struct PluginCatalogSidebar: View {
    let plugins: [CatalogPluginGroup]
    let onAddBlock: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Block")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.03))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(plugins) { plugin in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plugin.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.42))

                            ForEach(plugin.drawerBlocks) { block in
                                Button {
                                    onAddBlock(plugin.pluginID, block.id)
                                } label: {
                                    HStack {
                                        Text(block.displayName)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.8))
                                        Spacer()
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(.white.opacity(0.055))
                                    )
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.045, green: 0.045, blue: 0.055).opacity(0.97))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
        )
        .padding(.leading, NotchGridMetrics.contentPadding)
        .padding(.top, NotchGridMetrics.contentPadding + NotchGridMetrics.drawerTopBarHeight)
        .padding(.bottom, NotchGridMetrics.contentPadding)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}