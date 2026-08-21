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
    let layout: NotchLayout
    let elements: [CompactElement]
    let isEditing: Bool
    let showsClickModeHint: Bool
    let compactCatalog: [CompactCatalogItem]
    let canAddCompact: Bool
    let actions: CompactActions

    @State private var isHovering = false

    private let cornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            // 编辑模式需要容纳“+”添加按钮：面板略加宽（仍在窗口内），槽位行左移让位。
            let editExtras: CGFloat = isEditing ? 48 : 0
            let panelWidth = min(layout.compactSize.width + editExtras, proxy.size.width - 8)
            let panelHeight = proxy.size.height
            // 面板在窗口内的水平原点（面板水平居中于刘海下方）。
            let panelOriginX = (proxy.size.width - panelWidth) / 2
            let slotRowWidth =
                (CGFloat(NotchGeometry.compactSlotCount)
                    * (NotchGeometry.compactSlotSize.width + NotchGeometry.compactSlotSpacing))
                - NotchGeometry.compactSlotSpacing
            let slotRowX = panelOriginX + (panelWidth - slotRowWidth) / 2 - (isEditing ? 22 : 0)
            let slotY = panelHeight - NotchGeometry.compactSlotSize.height - 1

            ZStack(alignment: .top) {
                // 常驻的黑色紧凑面板（贴近刘海观感，与抽屉同款配色）。
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
                        radius: 16,
                        y: 7
                    )
                    .frame(width: panelWidth, height: panelHeight)
                    .position(x: proxy.size.width / 2, y: panelHeight / 2)

                // click 模式下的悬停指示条（沿用旧版 CompactNotchView 的提示方式）。
                if showsClickModeHint, isHovering, !isEditing {
                    Capsule()
                        .fill(.white.opacity(0.72))
                        .frame(width: 48, height: 2)
                        .shadow(color: .white.opacity(0.32), radius: 4)
                        .position(x: proxy.size.width / 2, y: 7)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }

                // 点击热区：整帧可交互，点击空白处展开抽屉（块视图在上层优先响应）。
                Color.black.opacity(0.0001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: actions.onTapBackground)

                ForEach(elements) { element in
                    if let view = element.view {
                        let slotX = slotRowX
                            + CGFloat(element.slotIndex) * (NotchGeometry.compactSlotSize.width + NotchGeometry.compactSlotSpacing)
                        CompactBlockContainer(
                            element: element,
                            view: view,
                            isEditing: isEditing,
                            onRemove: { actions.onRemoveBlock(element.slotIndex) },
                            onExpand: actions.onExpand
                        )
                        .position(
                            x: slotX + NotchGeometry.compactSlotSize.width / 2,
                            y: slotY + NotchGeometry.compactSlotSize.height / 2
                        )
                    }
                }

                // 编辑模式：槽位旁“+”添加紧凑块（贴在面板右缘，垂直对齐槽位行）。
                if isEditing {
                    addCompactButton
                        .position(
                            x: panelOriginX + panelWidth - 20,
                            y: slotY + NotchGeometry.compactSlotSize.height / 2
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var addCompactButton: some View {
        Menu {
            ForEach(compactCatalog) { item in
                Button {
                    actions.onAddCompact(item.pluginID, item.blockID)
                } label: {
                    Text(item.displayName)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                        .fill(.white.opacity(0.05))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!canAddCompact || compactCatalog.isEmpty)
        .help(canAddCompact ? "Add compact block" : "All compact slots are full")
    }
}

/// 紧凑块容器：44×44 槽位内的块视图 + 默认点击展开（文档 §6.2）+ 编辑模式移除。
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
    let supportedSizes: [BlockSize]
    let currentSize: BlockSize?

    var id: String { placement.placementID }
}

struct DrawerActions {
    let onTogglePin: () -> Void
    let onToggleEdit: () -> Void
    let onCollapse: () -> Void
    let onRemoveBlock: (String) -> Void
    let onMoveBlock: (String, Int, Int) -> Void
    let onResizeBlock: (String, BlockSize) -> Void
    let onAddBlock: (String, String) -> Void
    /// 拖拽实时预览：返回全体块的新位置（不落盘）。
    let onPreviewMove: (String, Int, Int) -> [String: LayoutEngine.GridOrigin]
    /// 拖拽结束提交（含自动重排）。
    let onCommitDrag: (String, Int, Int) -> Void
}

struct DrawerPanelView: View {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    /// 窗口内容尺寸（与 layoutEngine.drawerWindowSize() 一致；根视图固定为它，
    /// 避免 NSHostingView 按 SwiftUI 理想尺寸把窗口/内容撑宽）。
    let windowSize: CGSize
    let elements: [DrawerElement]
    let catalogPlugins: [CatalogPluginGroup]
    let isPinned: Bool
    let isEditing: Bool
    let actions: DrawerActions

    private let cornerRadius: CGFloat = 18

    var body: some View {
        ZStack(alignment: .top) {
            RoundedTopBackground(cornerRadius: cornerRadius)

            VStack(spacing: 0) {
                topBar
                    .frame(height: NotchGridMetrics.drawerTopBarHeight)

                ScrollView(showsIndicators: true) {
                    grid
                }
            }
            .padding(.horizontal, NotchGridMetrics.contentPadding)
            .padding(.bottom, NotchGridMetrics.contentPadding)

            if isEditing {
                PluginCatalogSidebar(
                    plugins: catalogPlugins,
                    onAddBlock: actions.onAddBlock
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .clipped()
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("NotchCenter")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 0)

            topBarButton(
                systemImage: isPinned ? "pin.fill" : "pin",
                help: isPinned ? "Unpin drawer" : "Pin drawer open",
                action: actions.onTogglePin,
                tint: isPinned ? .white.opacity(0.9) : .white.opacity(0.65)
            )

            topBarButton(
                systemImage: isEditing ? "pencil.slash" : "pencil",
                help: isEditing ? "Done editing layout" : "Edit layout",
                action: actions.onToggleEdit,
                tint: isEditing ? .white.opacity(0.9) : .white.opacity(0.65)
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
            ForEach(elements) { element in
                let origin = resolveOrigin(for: element)
                DrawerBlockContainer(
                    element: element,
                    isEditing: isEditing,
                    isDragging: draggingPlacementID == element.id,
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
                    },
                    onResize: actions.onResizeBlock
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
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: elements.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: previewPositions)
    }

    @State private var previewPositions: [String: LayoutEngine.GridOrigin] = [:]
    @State private var draggingPlacementID: String?

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

/// 抽屉背景：近黑半透明 + 顶部圆角 + 细描边。
private struct RoundedTopBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        TopAttachedRoundedShape(radius: cornerRadius)
            .fill(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
            .overlay {
                TopAttachedRoundedShape(radius: cornerRadius)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
    }
}

/// 抽屉块容器：稳定身份 + 块视图 + 编辑模式（文档 §5.5）。
/// - 拖动整块移动：拖动中实时预览（被占用块向下推挤自动重排），松手提交；
/// - 高亮边缘 + 拖动右/下边缘与右下角调整尺寸（在支持的尺寸等级间吸附）；
/// - 移除按钮跟随块一起移动。
private struct DrawerBlockContainer: View {
    let element: DrawerElement
    let isEditing: Bool
    let isDragging: Bool
    let onRemove: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    let onResize: (String, BlockSize) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var resizeColumns: Int?
    @State private var resizeRows: Int?

    private let cornerRadius: CGFloat = 12
    private let handleThickness: CGFloat = 10

    var body: some View {
        let columns = resizeColumns ?? element.placement.widthColumns
        let rows = resizeRows ?? element.placement.heightRows

        ZStack(alignment: .topTrailing) {
            element.view
                .background(isEditing ? Color.white.opacity(0.03) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if isEditing {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                .white.opacity(isDragging ? 0.62 : 0.45),
                                lineWidth: isDragging ? 1.5 : 1
                            )
                    }
                }
                .frame(
                    width: NotchGridMetrics.contentWidth(columns: columns),
                    height: NotchGridMetrics.contentHeight(rows: rows)
                )

            if isEditing {
                controls
            }
        }
        .contentShape(Rectangle())
        .offset(dragOffset)
        .gesture(
            isEditing && resizeColumns == nil && resizeRows == nil
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

    // MARK: 编辑控件（跟随块移动）

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .trailing, spacing: 4) {
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

        // 边缘调整尺寸手柄（拖动右缘/下缘/右下角）。
        resizeHandles
            .allowsHitTesting(resizeColumns == nil && resizeRows == nil)
    }

    @ViewBuilder
    private var resizeHandles: some View {
        if isEditing {
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                ZStack(alignment: .bottomTrailing) {
                    // 右缘：上下留出移除按钮区域。
                    Rectangle()
                        .fill(.white.opacity(0.55))
                        .frame(width: handleThickness)
                        .position(x: w - handleThickness / 2, y: h / 2 + 10)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            resizeWidthGesture
                        )
                        .help("Drag to resize width")

                    // 下缘。
                    Rectangle()
                        .fill(.white.opacity(0.55))
                        .frame(height: handleThickness)
                        .position(x: w / 2, y: h - handleThickness / 2)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            resizeHeightGesture
                        )
                        .help("Drag to resize height")

                    // 右下角。
                    Rectangle()
                        .fill(.white.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .position(x: w - 9, y: h - 9)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            resizeCornerGesture
                        )
                        .help("Drag to resize")
                }
            }
            .allowsHitTesting(true)
        }
    }

    private var resizeWidthGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cell = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing
                let startColumns = element.placement.widthColumns
                let delta = Int((value.translation.width / cell).rounded())
                resizeColumns = min(max(startColumns + delta, 1), 4)
            }
            .onEnded { _ in
                commitResize()
            }
    }

    private var resizeHeightGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cell = NotchGridMetrics.cellHeight + NotchGridMetrics.spacing
                let startRows = element.placement.heightRows
                let delta = Int((value.translation.height / cell).rounded())
                resizeRows = min(max(startRows + delta, 1), 6)
            }
            .onEnded { _ in
                commitResize()
            }
    }

    private var resizeCornerGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cellW = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing
                let cellH = NotchGridMetrics.cellHeight + NotchGridMetrics.spacing
                let deltaColumns = Int((value.translation.width / cellW).rounded())
                let deltaRows = Int((value.translation.height / cellH).rounded())
                resizeColumns = min(max(element.placement.widthColumns + deltaColumns, 1), 4)
                resizeRows = min(max(element.placement.heightRows + deltaRows, 1), 6)
            }
            .onEnded { _ in
                commitResize()
            }
    }

    /// 松手时在支持的尺寸等级间吸附；无匹配尺寸则回退原尺寸。
    private func commitResize() {
        let columns = resizeColumns ?? element.placement.widthColumns
        let rows = resizeRows ?? element.placement.heightRows
        resizeColumns = nil
        resizeRows = nil

        guard let size = element.supportedSizes.first(where: {
            $0.gridSpan.columns == columns && $0.gridSpan.rows == rows
        }), size != element.currentSize else {
            return
        }
        onResize(element.id, size)
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