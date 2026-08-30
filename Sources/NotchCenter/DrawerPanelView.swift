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
    /// 插件是否提供设置界面（编辑模式左上角齿轮按钮的显隐条件）。
    let hasSettings: Bool

    var id: String { placement.placementID }
}

struct DrawerActions {
    let onShowSettings: () -> Void
    /// 打开设置并直入「组件」页（非编辑态由 setComponentsPageActive 联动进入编辑模式）。
    let onAddComponent: () -> Void
    let onTogglePin: () -> Void
    let onToggleEdit: () -> Void
    let onCollapse: () -> Void
    let onRemoveBlock: (String) -> Void
    /// 编辑模式块左上角设置按钮：(pluginID, placementID, 块全局 frame)，经
    /// SettingPopover 展示设置——优先块实例级视图，回退插件级。
    let onShowBlockSettings: (String, String, CGRect) -> Void
    let onMoveBlock: (String, Int, Int) -> Void
    let onResizeBlock: (String, Int, Int) -> Void
    /// 编辑模式一键重排：按阅读顺序紧密排布所有抽屉块。
    let onReorderBlocks: () -> Void
    /// 拖动实时预览：返回全体块（推挤 + 离线压实）后的新位置（不落盘），
    /// 与提交共用同一算法——预览即最终布局。其余块据此实时推挤
    /// （`previewPositions`），被拖块落点供占位框使用（视图自取）。
    let onPreviewMove: (String, Int, Int) -> [String: LayoutEngine.GridOrigin]
    /// 抽屉内重排的落点预览（虚线占位框；面板尺寸/左列由控制器在
    /// `onPreviewMove` 内同帧写入）。
    /// 传 nil 清空（拖动结束或取消）。
    let onUpdateReorderPreview: (LayoutEngine.GridOrigin?, GridSpan?) -> Void
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
            // 带宽随当前紧凑图标数动态伸缩。
            compactView
                .frame(
                    width: layout.compactStrip(slotCount: ui.compactCount).windowWidth,
                    height: layout.compactHeight
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
            height: ui.drawerWindowSize.height + layout.compactHeight,
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

            // 滚动指示条必须隐藏：网格内容高度与可视区高度是两个独立动画值
            // （gridFrameHeight 与窗口高度各自的 spring 表现层，逐帧量化差
            // ±0.1~0.3pt），多行缩少行时 doc/clip 反复跨越相等点，NSScrollView
            // 的滚动条随之反复亮灭（NOTCHCENTER_SHRINKSCROLL_PROBE 实测：同一
            // 收缩动画中 vHidden 翻转多次）。抽屉本来就是内容自适应面板，静止态
            // 内容 ≡ 可视区，滚动条没有存在意义；屏幕封顶时滚轮滚动依旧可用
            // （仅无指示条）。与紧凑带 HorizontalDragScroll 同理。
            ScrollView(showsIndicators: false) {
                grid
            }
        }
        .padding(.horizontal, NotchGridMetrics.contentPadding)
        .padding(.bottom, NotchGridMetrics.contentPadding)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            // 原标题位置改为设置按钮（accessory 应用无菜单栏，这是常驻入口）。
            topBarButton(
                systemImage: "gearshape",
                help: L("panel.help.settings"),
                action: actions.onShowSettings,
                tint: .white.opacity(0.65)
            )

            Spacer(minLength: 0)

            // 添加组件（常驻）：打开设置并直入「组件」页，替代原编辑模式
            // 提示胶囊「前往设置页添加组件」。
            topBarButton(
                systemImage: "plus.rectangle.on.rectangle",
                help: L("panel.help.addComponent"),
                action: actions.onAddComponent,
                tint: .white.opacity(0.65)
            )

            // 编辑模式隐藏钉住按钮，其槽位让给一键重排（添加组件按钮右边）；
            // 钉住状态保留，退出编辑后恢复显示——槽位固定，编辑/关闭按钮不跳动。
            if ui.isEditing {
                topBarButton(
                    systemImage: "arrow.down.forward.and.arrow.up.backward",
                    help: L("panel.help.tidy"),
                    action: actions.onReorderBlocks,
                    tint: .white.opacity(0.9)
                )
                .transition(.opacity)
            } else {
                topBarButton(
                    systemImage: ui.isPinned ? "pin.fill" : "pin",
                    help: ui.isPinned ? L("panel.help.unpin") : L("panel.help.pin"),
                    action: actions.onTogglePin,
                    tint: .white.opacity(0.65),
                    // 固定态常驻高亮（比悬停高亮亮一档，见 TopBarButton）。
                    isActive: ui.isPinned
                )
                .transition(.opacity)
            }

            topBarButton(
                systemImage: ui.isEditing ? "pencil.slash" : "pencil",
                help: ui.isEditing ? L("panel.help.doneEditing") : L("panel.help.editLayout"),
                action: actions.onToggleEdit,
                tint: .white.opacity(0.65),
                // 编辑态常驻高亮。
                isActive: ui.isEditing
            )

            topBarButton(
                systemImage: "chevron.down",
                help: L("panel.help.closeDrawer"),
                action: actions.onCollapse,
                tint: .white.opacity(0.65)
            )
        }
        .padding(.horizontal, 4)
    }

    /// 独立结构体而非视图方法：悬停高亮需要 `@State`，方法无法持有。
    private func topBarButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void,
        tint: Color,
        isActive: Bool = false
    ) -> some View {
        TopBarButton(
            systemImage: systemImage,
            help: help,
            tint: tint,
            isActive: isActive,
            action: action
        )
    }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ui.drawerElements) { element in
                blockContainer(for: element)
            }
            dropPlaceholder
        }
        .frame(
            width: ui.drawerContentSize.width,
            height: gridFrameHeight,
            alignment: .topLeading
        )
        .animation(DrawerAnimation.spring, value: ui.drawerElements.map(\.id))
        .animation(DrawerAnimation.spring, value: ui.drawerElements.map(\.placement))
        .animation(DrawerAnimation.spring, value: previewPositions)

    }

    /// 从设置面板拖入抽屉组件时的落点占位（虚线框）：位置与尺寸都用落点的
    /// 格子坐标算，与块容器同一套 gridX / gridY 公式（所见即所得）。
    @ViewBuilder
    private var dropPlaceholder: some View {
        if case let .drawer(column, row, columns, rows)? = ui.dropPreview?.zone,
           ui.dropPreview?.isCompact == false {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.5))
                )
                .frame(
                    width: gridWidth(columns: columns),
                    height: gridHeight(rows: rows)
                )
                .position(
                    x: gridX(column: column - ui.drawerGridLeftColumn)
                        + gridWidth(columns: columns) / 2,
                    y: gridY(row: row) + gridHeight(rows: rows) / 2
                )
                .allowsHitTesting(false)
        }
    }

    /// 单个抽屉块容器（含定位修饰）：独立成方法拆开类型检查表达式——
    /// 全部内联在 grid 里会超出编译器合理检查时间。
    private func blockContainer(for element: DrawerElement) -> some View {
        let origin = resolveOrigin(for: element)
        return DrawerBlockContainer(
            element: element,
            isEditing: ui.isEditing,
            isDragging: draggingPlacementID == element.id,
            hasSettings: element.hasSettings,
            previewColumns: resizingPlacementID == element.id ? resizePreviewColumns : nil,
            previewRows: resizingPlacementID == element.id ? resizePreviewRows : nil,
            onResizeChanged: { translation in
                handleResizeTranslate(translation, for: element)
            },
            onResizeCommit: { commitResize(for: element) },
            onRemove: { actions.onRemoveBlock(element.id) },
            onShowSettings: { anchorFrame in
                actions.onShowBlockSettings(
                    element.placement.pluginID,
                    element.id,
                    anchorFrame
                )
            },
            onDragChanged: { translation in
                draggingPlacementID = element.id
                let target = dragTarget(for: element, translation: translation)
                // 全量 origins 写入 previewPositions：其余块实时推挤，
                // 被拖块落点喂给占位框（预览即最终布局）。
                let origins = actions.onPreviewMove(element.id, target.0, target.1)
                guard let dragged = origins[element.id] else { return }
                previewPositions = origins
                actions.onUpdateReorderPreview(
                    dragged,
                    GridSpan(
                        columns: element.placement.widthColumns,
                        rows: element.placement.heightRows
                    )
                )
            },
            onDragEnded: { translation in
                let target = dragTarget(for: element, translation: translation)
                // `previewPositions` 同时服务拖动推挤与缩放预览，松手后
                // 不再需要（提交布局由 onCommitDrag 写入），这里无动画兜底
                // 清空——缩放/推挤遗留的预览不该在落位时闪一下。
                if !previewPositions.isEmpty { previewPositions = [:] }
                //
                // `draggingPlacementID = nil` 必须**早于** onCommitDrag：
                // 否则 `resolveOrigin` 那一帧仍走「拖动块排除」分支，块会
                // 先弹回原位再瞬移到落点。
                //
                // 落位动画本身无需额外代码：调用方（DrawerBlockContainer）
                // 已用**同一个** spring 常量把 dragOffset 归零，与
                // onCommitDrag 触发的 placement 变化在同一个 runloop tick
                // 起播；两者视觉位置相加（position + offset）即为「从光标
                // spring 飞到落点」的单条曲线。参数一旦漂移，合成曲线会
                // 折一下——这就是 DrawerAnimation 必须唯一的原因。
                draggingPlacementID = nil
                actions.onUpdateReorderPreview(nil, nil)
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
            x: gridX(column: origin.column - ui.drawerGridLeftColumn)
                + gridWidth(columns: element.placement.widthColumns) / 2,
            y: gridY(row: origin.row)
                + gridHeight(rows: element.placement.heightRows) / 2
        )
        // 落位飞行：新块先隐形，让跟手浮窗独占画面（避免一明一暗的重影）；
        // 飞行结束时同一次更新里清空，交接不留空帧。
        // 独立于方法之外、不内联回 grid —— 内联会让 SwiftUI 类型检查
        // 耗时显著回退（本方法的拆分就是为此）。
        .opacity(ui.landingPlacementID == element.id ? 0 : 1)
    }

    /// 网格高度 = 块实占行数（预览/非预览一律按块包围盒计）：预览可能把
    /// 块压到（或长到）提交布局之外，按预览最低行扩展（窗口由控制器同步
    /// 增高），避免预览块被 ScrollView 裁掉。正在缩放的块以预览行数计——
    /// 模型里的 heightRows 还是旧值，底层块长高时它是唯一增高来源。
    /// 不要与 drawerContentSize.height 取 max：它永远是**提交布局**的行高，
    /// 缩放/增删使行数减少时仍是旧的高值——网格内容被撑得比已收缩的可视区
    /// 高一截，ScrollView 随即亮起滚动条（内容其实滚不出这块“多出来”的区域，
    /// 净闪烁），松手后滚动条还会拖到提交动画末尾才消失。网格高度必须与
    /// 窗口高度（同源行数、同一 spring）同相收缩：内容 ≡ 可视区，滚动条
    /// 只在屏幕封顶截断内容（真正可滚）时出现。
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
        // 落点在末尾新行时也要撑开：否则占位框被 ScrollView 裁掉
        // （网格内容高度是滚动区的唯一来源）。
        let dropRows = dropPlaceholderBottomRow
        return NotchGridMetrics.contentHeight(rows: max(previewRows, dropRows, 1))
    }

    /// 拖入落点的最低占用行（无落点为 0）。
    private var dropPlaceholderBottomRow: Int {
        guard let preview = ui.dropPreview, !preview.isCompact,
              case let .drawer(_, row, _, rows) = preview.zone else { return 0 }
        return row + rows
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
        withAnimation(DrawerAnimation.spring) {
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

/// 抽屉顶栏按钮：24×24 圆角矩形底衬，悬停高亮 + 激活态常驻高亮。
/// 亮度分层（悬停比激活态暗一档）：常态 0.055 → 悬停 0.10 →
/// 激活 0.16 → 激活+悬停 0.20。
private struct TopBarButton: View {
    let systemImage: String
    let help: String
    let tint: Color
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    /// 背景填充不透明度：激活态优先于悬停态，二者叠加再亮一档。
    private var fillOpacity: Double {
        if isActive { return isHovering ? 0.20 : 0.16 }
        return isHovering ? 0.10 : 0.055
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(fillOpacity))
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .help(help)
        .accessibilityLabel(help)
    }
}
