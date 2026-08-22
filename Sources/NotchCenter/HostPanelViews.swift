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
}

struct CompactPanelView: View {
    @ObservedObject var ui: PanelUIState
    /// 本面板所在屏幕的刘海/回退几何（每屏一份：外接屏回退与内建屏实测
    /// 刘海的宽度/槽位布局不同，不能共享主屏几何，否则非主屏条带偏心、
    /// 图标相对物理刘海错位）。
    var layout: NotchLayout
    let actions: CompactActions
    /// 是否自绘黑色底衬（独立热区窗口为 true；嵌入抽屉岛顶时为 false，
    /// 由抽屉统一背景提供，避免叠加描边/阴影）。
    var showsBand = true

    @State private var isHovering = false

    private let cornerRadius: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let isEditing = ui.isEditing
            let strip = layout.compactStrip
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
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
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
    /// 编辑模式一键重排：按阅读顺序紧密排布所有抽屉块。
    let onReorderBlocks: () -> Void
    /// 拖拽实时预览：返回全体块的新位置（不落盘）。
    let onPreviewMove: (String, Int, Int) -> [String: LayoutEngine.GridOrigin]
    /// 缩放实时预览：返回全体块的新位置（下方块推挤下移，不落盘）。
    let onPreviewResize: (String, Int, Int) -> [String: LayoutEngine.GridOrigin]
    /// 拖拽结束提交（含自动重排）。
    let onCommitDrag: (String, Int, Int) -> Void
}

/// 缩放握把的死区量化（迟滞）：把连续跨度值吸附到整数档位，
/// 且只有越过当前档位的半格边界（0.5 ± band）之外才允许换档，
/// 边界两侧各留 band 宽的稳定带。否则鼠标在半格边界附近抖动时，
/// round() 会在相邻档位间来回翻转，预览随之闪烁。
enum ResizeHysteresis {
    /// 死区余量（单位：网格步长）。0.18 格 ≈ 水平 29pt / 垂直 24pt，
    /// 远大于像素级抖动，又不足以下意识拖动跨越。
    static let band: CGFloat = 0.18

    /// 死区量化：`continuous` 越过当前档位的边界 ± band 之外才换档，
    /// 否则保持 `current`；越过较多时一次跨多档直接落到最近整数。
    static func quantized(_ continuous: CGFloat, current: Int, band: CGFloat = ResizeHysteresis.band) -> Int {
        let delta = continuous - CGFloat(current)
        if delta > 0.5 + band {
            return Int((continuous - band).rounded())
        }
        if delta < -0.5 - band {
            return Int((continuous + band).rounded())
        }
        return current
    }
}

/// 抽屉内容实际渲染尺寸的逐帧上报（含 spring 动画中间帧）。
private struct DrawerContentSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct DrawerPanelView: View {
    @ObservedObject var ui: PanelUIState
    /// 抽屉展开所在屏幕的几何（岛顶紧凑带、揭示动画起点宽度都按该屏
    /// 刘海计算；抽屉只会在 activePair 上展示，故用所属 pair 的布局）。
    var layout: NotchLayout
    /// 岛顶的紧凑区（刘海高度带）：随抽屉一起作为“岛体”展示，视觉融合。
    var compactView: CompactPanelView
    let actions: DrawerActions
    /// 内容几何逐帧上报（含 spring 动画过程中的每一帧）：控制器据此把
    /// 窗口 frame 贴合内容——窗口与内容共用 SwiftUI spring，严丝合缝。
    /// 注意：沙箱化进程上 preference 不传播（诊断须在非沙箱环境运行）。
    var onContentSizeChange: ((CGSize) -> Void)?

    private let cornerRadius: CGFloat = 18

    /// 抽屉窗口总高 = 紧凑带 + 内容。
    private var totalHeight: CGFloat {
        ui.drawerWindowSize.height + layout.compactSize.height
    }

    var body: some View {
        // 灵动岛式展开：窗口固定为最终尺寸（含顶部紧凑带），内容经遮罩
        // 从刘海尺寸插值放大，随进度淡入（沿用旧版 revealProgress 方案）。
        VStack(spacing: 0) {
            // 与独立紧凑面板完全相同的尺寸并水平居中：
            // 保证展开动画前后图标在屏幕上的绝对位置不变。
            compactView
                .frame(
                    width: layout.compactSize.width,
                    height: layout.compactSize.height
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
        // 逐帧上报内容几何（固定 frame 的实际渲染尺寸，含动画中间帧），
        // 控制器据此同步窗口 frame —— 窗口与内容共用同一 SwiftUI spring。
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DrawerContentSizePreferenceKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(DrawerContentSizePreferenceKey.self) { size in
            onContentSizeChange?(size)
        }
        // 宿主视图内顶对齐：窗口与内容高度的瞬时差只落在窗口底部
        // （透明区、不可见），内容顶部（菜单栏覆盖带）永不下坠。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .opacity(revealedContentOpacity)
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

    // MARK: 揭示动画几何

    private var strip: CompactStripLayout {
        layout.compactStrip
    }

    /// 起点：紧凑黑色带的宽度与刘海高度（与常驻紧凑区完全重合）。
    private var revealedStartSize: CGSize {
        CGSize(
            width: strip.rightPanelX + strip.rightPanelWidth,
            height: layout.compactSize.height
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

    /// 缩放手势：基于位移增量的目标格数。**平移量必须在稳定坐标系度量**
    /// （`.global` 锚定窗口，拖拽期间窗口不动）：默认的 `.local` 空间挂在
    /// 握把上，预览每长一格，握把连同其 local 空间整体平移一格，translation
    /// 瞬间反跳一整格——死区无法吸收，形成“增长 → 平移量清零 → 缩回 →
    /// 恢复”的逐事件自激振荡（原大小/目标大小逐像素切换）。复刻复现与
    /// 日志见 `ResizeProbe`（NOTCHCENTER_RESIZE_PROBE=1）。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                onResizeChanged(value.translation)
            }
            .onEnded { _ in
                onResizeCommit()
            }
    }
}

// MARK: - 添加块区域（文档 §5.5）

/// 目录的插件分组：上栏列紧凑块、下栏列抽屉块（均来自已启用插件）。
struct CatalogPluginGroup: Identifiable {
    let pluginID: String
    let displayName: String
    let compactBlocks: [NotchBlock]
    let drawerBlocks: [NotchBlock]

    var id: String { pluginID }
}

/// 编辑模式的横向 AddBlock 区域：插入在紧凑带与网格之间，自身分上下两栏。
/// 上栏：紧凑块目录，点击加入第一个空槽（槽满时条目置灰禁用、区域保持占位）；
/// 下栏：抽屉块目录，按插件内联分组（插件名小标签 → 块条目 → 竖分隔线），
/// 单行横向滚动不换行。条目统一为“图标 + 块名”药丸；块未声明 symbolName
/// 时回退纯文本。
struct AddBlockArea: View {
    let plugins: [CatalogPluginGroup]
    let canAddCompact: Bool
    let onAddBlock: (String, String) -> Void

    /// 行高（上下两栏一致，条目在行内垂直居中）。
    static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 6
    private static let verticalPadding: CGFloat = 7
    private static let separatorHeight: CGFloat = 1

    /// 区域总高：控制器据此联动抽屉窗口高度，与 body 布局保持同一公式。
    static func height(for plugins: [CatalogPluginGroup]) -> CGFloat {
        let hasCompactRow = plugins.contains { !$0.compactBlocks.isEmpty }
        let hasDrawerRow = plugins.contains { !$0.drawerBlocks.isEmpty }
        let rows = (hasCompactRow ? 1 : 0) + (hasDrawerRow ? 1 : 0)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * rowSpacing
            + verticalPadding * 2
            + separatorHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Self.rowSpacing) {
                if hasCompactRow {
                    compactRow
                        .frame(height: Self.rowHeight)
                }
                if hasDrawerRow {
                    drawerRow
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.vertical, Self.verticalPadding)

            // 与网格的分界发丝线（DESIGN.md hairlines）。
            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(height: Self.separatorHeight)
        }
    }

    private var hasCompactRow: Bool {
        plugins.contains { !$0.compactBlocks.isEmpty }
    }

    private var hasDrawerRow: Bool {
        plugins.contains { !$0.drawerBlocks.isEmpty }
    }

    /// 上栏：紧凑块目录（跨插件扁平排列）。
    private var compactRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                rowCaption("Compact")
                ForEach(flatCompactEntries) { entry in
                    catalogPill(
                        entry.block,
                        pluginID: entry.pluginID,
                        disabled: !canAddCompact,
                        help: canAddCompact
                            ? "Add to the compact strip"
                            : "All compact slots are full"
                    )
                }
            }
        }
    }

    /// 下栏：抽屉块目录，按插件内联分组。
    private var drawerRow: some View {
        let groups = plugins.filter { !$0.drawerBlocks.isEmpty }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                rowCaption("Drawer")
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, plugin in
                    HStack(spacing: 6) {
                        Text(plugin.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.42))
                            .fixedSize()
                        ForEach(plugin.drawerBlocks) { block in
                            catalogPill(
                                block,
                                pluginID: plugin.pluginID,
                                disabled: false,
                                help: "Add to the drawer grid"
                            )
                        }
                    }
                    if index < groups.count - 1 {
                        groupDivider
                    }
                }
            }
        }
    }

    /// 上栏条目：紧凑块跨插件扁平化。
    private var flatCompactEntries: [CompactCatalogEntry] {
        plugins.flatMap { group in
            group.compactBlocks.map { block in
                CompactCatalogEntry(pluginID: group.pluginID, block: block)
            }
        }
    }

    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.38))
            .fixedSize()
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(width: 1, height: 16)
    }

    /// 目录药丸：图标 + 块名；未声明 symbolName 的块回退纯文本。
    private func catalogPill(
        _ block: NotchBlock,
        pluginID: String,
        disabled: Bool,
        help: String
    ) -> some View {
        Button {
            onAddBlock(pluginID, block.id)
        } label: {
            HStack(spacing: 5) {
                if let symbolName = block.symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text(block.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.055))
            )
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(disabled)
        .help(help)
    }
}

/// 上栏的紧凑块条目（跨插件扁平化后的载体）。
private struct CompactCatalogEntry: Identifiable {
    let pluginID: String
    let block: NotchBlock
    let id: String

    @MainActor
    init(pluginID: String, block: NotchBlock) {
        self.pluginID = pluginID
        self.block = block
        self.id = pluginID + "." + block.id
    }
}