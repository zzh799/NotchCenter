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
    /// 块声明的横向滑动消费（滑动切页的让路判据，见 `BlockScrollUsage`）。
    let scrollUsage: BlockScrollUsage
    /// 插件是否提供设置界面（编辑模式左上角齿轮按钮的显隐条件）。
    let hasSettings: Bool

    var id: String { placement.placementID }
}

/// 抽屉顶栏与块上的 chrome / CRUD 动作。
///
/// 拖拽与缩放的引擎交互**不在这里**，走 `DrawerInteractionState.Bridge`——
/// 那部分有严格的时序契约（预览与提交同源、松手顺序），需要能被测试驱动。
struct DrawerActions {
    let onShowSettings: () -> Void
    let onTogglePin: () -> Void
    let onRemoveBlock: (String) -> Void
    /// 编辑模式块左上角设置按钮：(pluginID, placementID, 块全局 frame)，经
    /// SettingPopover 展示设置——优先块实例级视图，回退插件级。
    let onShowBlockSettings: (String, String, CGRect) -> Void
    /// 编辑模式一键重排：按阅读顺序紧密排布当前页的抽屉块。
    let onReorderBlocks: () -> Void
    /// 分页胶囊：切页 / 在指定侧新增 / 拖动排序到目标槽位 / 弹出页面设置
    ///（图标+名称浮窗，(page, 胶囊全局 frame)）/ 删除（连页内块）。
    let onSelectPage: (Int) -> Void
    let onAddPage: (DrawerPageSide) -> Void
    let onMovePage: (Int, Int) -> Void
    let onShowPageSettings: (Int, CGRect) -> Void
    let onRemovePage: (Int) -> Void
    /// 左右滑动切页的**拖拽**通路（网格背景手势）：只上报原始平移量，
    /// 方向、位移与落位判据由控制器按 `DrawerPageSwipe` 决定。松手回调
    /// 第二个参数是 `DragGesture` 的预测终点（速度判据折算了它）。
    let onSwipeDrag: (CGSize) -> Void
    let onSwipeDragEnded: (CGSize, CGSize) -> Void
}

struct DrawerPanelView: View {
    @ObservedObject var ui: PanelUIState
    /// 抽屉展开所在屏幕的几何（岛顶紧凑带、收起尺寸都按该屏刘海计算；
    /// 抽屉只会在 activePair 上展示，故用所属 pair 的布局）。
    var layout: NotchLayout
    /// 岛顶的紧凑区（刘海高度带）：随抽屉一起作为“岛体”展示，视觉融合。
    var compactView: CompactPanelView
    let actions: DrawerActions

    /// 拖拽 / 缩放的手势状态。**每屏一份**，不挂到控制器或 `PanelUIState`：
    /// `drawerWindowSize` 等跨屏共享量已经够多了，再把"谁在拖"扩散成全局
    /// 会让状态耦合失控。
    @StateObject private var interaction: DrawerInteractionState

    /// 抽屉内容淡入淡出（参考 codex-island 的 contentVisible 节奏：
    /// 展开后段淡入、收起时先淡出再缩形）。
    @State private var contentVisible = false

    /// 指针是否悬停在顶栏上：分页加号按钮的显示条件之一。
    @State private var isTopBarHovering = false

    private let cornerRadius: CGFloat = 18

    init(
        ui: PanelUIState,
        layout: NotchLayout,
        compactView: CompactPanelView,
        actions: DrawerActions,
        bridge: DrawerInteractionState.Bridge
    ) {
        self.ui = ui
        self.layout = layout
        self.compactView = compactView
        self.actions = actions
        // `StateObject(wrappedValue:)` 只在首次渲染求值一次；根视图由
        // `buildViewsIfNeeded` 在面板窗口不存在时才构造，故本对象生命周期
        // 与面板一致（等价于改动前挂在视图上的 @State）。
        _interaction = StateObject(wrappedValue: DrawerInteractionState(bridge: bridge))
    }

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
                // 手势状态随面板存活（content 退出布局但状态对象不释放）：
                // 不清的话残留的预览原点会让块在下次展开时停在旧预览位置。
                interaction.reset()
                // 顶栏悬停同理：收起那一刻指针可能还在顶栏内，视图直接退出
                // 层级收不到 hover 结束事件，残留的 true 会让加号凭空挂着。
                isTopBarHovering = false
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: NotchGridMetrics.drawerTopBarHeight)
                // 整条顶栏都是加号的悬停带：按钮之间的空隙本身不参与命中，
                // 不补 contentShape 的话指针落在空隙里加号就不出现。
                .contentShape(Rectangle())
                .onHover { isTopBarHovering = $0 }

            // 滚动指示条必须隐藏：抽屉是内容自适应面板，静止态内容 ≡ 可视区，
            // 滚动条没有存在意义；且内容高度与可视区高度是两个独立的 spring
            // 动画值，多行缩少行时二者逐帧量化差会让滚动条反复亮灭。屏幕
            // 封顶截断内容时滚轮滚动依旧可用（仅无指示条）。
            ScrollView(showsIndicators: false) {
                pageSlide
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

            // 一键重排仅在编辑模式可用，常驻设置按钮右侧。
            if ui.isEditing {
                topBarButton(
                    systemImage: "arrow.down.forward.and.arrow.up.backward",
                    help: L("panel.help.tidy"),
                    action: actions.onReorderBlocks,
                    tint: .white.opacity(0.9)
                )
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            // 分页胶囊行：顶栏居中，每页一颗独立胶囊、加号在胶囊外（详见 DrawerPageCapsule）。
            // 高亮层常驻标记选中页：静止钉在激活胶囊，滑动会话期随进度平移。
            DrawerPageCapsule(
                pages: ui.drawerPages,
                titles: ui.drawerPageTitles,
                icons: ui.drawerPageIcons,
                activePage: ui.drawerActivePage,
                isEditing: ui.isEditing,
                showsAddButtons: ui.isEditing && isTopBarHovering,
                swipe: ui.drawerSwipe,
                onSelect: actions.onSelectPage,
                onAdd: actions.onAddPage,
                onMove: actions.onMovePage,
                onShowSettings: actions.onShowPageSettings,
                onRemove: actions.onRemovePage
            )

            Spacer(minLength: 0)

            // 编辑模式隐藏钉住按钮，退出编辑后恢复显示——槽位固定，按钮不跳动。
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

    /// 滑动切页的两层容器：当前页与目标页预览层构成一条**刚性页带**（预览层
    /// 横坐标 = `offset + gap`，`gap` 在会话开始时冻结；两层之间隔一条页带
    /// 留白 = 两倍内容边距的背景带，看得出是两页），整体跟手平移、超出裁掉。
    /// 容器宽高跟随 `drawerContentSize`——会话期间该尺寸随滑动进度在起止两端间
    /// 插值（面板同步长大/缩小），页带本身保持刚性（两层间距恒 = 留白：
    /// 网格层宽度由 `grid` 冻结在`会话起点值`，预览层宽度 = 目标页宽，留白条
    /// 不随插值变宽）。容器高度 = 内容高度：内容 ≡ 可视区，ScrollView
    /// 才不闪滚动条（与 `gridFrameHeight` 同源教训；会话外二者恒等）。
    /// 预览层按 `isLanded` 就地撤除（落位帧两层像素重合，撤层不可见）——不能等
    /// 异步 animated 清理才撤：目标页更宽时它会探回裁剪框内，淡出成右侧重影。
    private var pageSlide: some View {
        let offset = ui.drawerSwipe?.offset ?? 0
        return ZStack(alignment: .topLeading) {
            grid
                .offset(x: offset)
            if let swipe = ui.drawerSwipe, !swipe.isLanded {
                previewGrid(swipe)
                    .offset(x: swipe.offset + swipe.gap)
                    .allowsHitTesting(false)
            }
        }
        .frame(
            width: ui.drawerContentSize.width,
            height: ui.drawerContentSize.height,
            alignment: .topLeading
        )
        .clipped()
    }

    /// 目标页预览层：只按格网摆放块视图（`isPreview` 只读副本），
    /// 无编辑 chrome、无手势——整层 `allowsHitTesting(false)`。
    private func previewGrid(_ swipe: PanelUIState.DrawerSwipe) -> some View {
        let previewGeometry = DrawerGridGeometry(
            metrics: GridMetrics.current,
            leftColumn: swipe.leftColumn,
            capacity: .max,
            // 全局下限、所有页共用：两层留白高度一致，落位交接那一帧才完全重合。
            minimumRows: ui.drawerGridMinRows,
            minimumColumns: ui.drawerGridMinColumns
        )
        let cells = swipe.elements.map { GridCell($0.placement) }
        return ZStack(alignment: .topLeading) {
            ForEach(swipe.elements) { element in
                let frame = previewGeometry.frame(GridCell(element.placement))
                element.view
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(
            width: swipe.contentSize.width,
            height: previewGeometry.contentHeight(covering: cells),
            alignment: .topLeading
        )
    }

    /// 网格层。两条跟随元素变化的 spring 在**滑动会话挂载期必须关闭**：
    /// 切页换的是整页元素身份，落位那一帧若让它参与动画，退场页会在 x=0 上
    /// 重影淡出、进场页再从反方向滑一遍（真机报告"目标页面直接淡出"的根因）。
    /// 会话期网格层宽度必须**冻结在会话起点值**：预览层按"会话起点页宽 + 留白"
    /// 起排，若本层 bounds 跟着插值收窄/变宽，两层之间的留白条就会偏离会话
    /// 冻结值——只有本层宽度不变，层间距才恒等于留白。
    private var grid: some View {
        let swipeActive = ui.drawerSwipe != nil
        let gridWidth = ui.drawerSwipe?.startContentSize.width ?? ui.drawerContentSize.width
        return ZStack(alignment: .topLeading) {
            ForEach(ui.drawerElements) { element in
                blockContainer(for: element)
            }
            dropPlaceholder
        }
        .frame(
            width: gridWidth,
            height: gridFrameHeight,
            alignment: .topLeading
        )
        .background { pageSwipeSurface }
        .animation(swipeActive ? nil : DrawerAnimation.spring, value: ui.drawerElements.map(\.id))
        .animation(swipeActive ? nil : DrawerAnimation.spring, value: ui.drawerElements.map(\.placement))
        .animation(DrawerAnimation.spring, value: interaction.previewOrigins)
    }

    /// 滑动切页的**拖拽**面：铺在网格背后的兄弟层。块无条件 `contentShape(Rectangle())`
    /// 认领自己的矩形（`DrawerBlockContainer`），所以这里只收得到块没盖住的空隙上的
    /// 按下——块内拖拽、笔记选字、文件架框选一概不受影响。用 `highPriorityGesture`
    /// 压过外层 ScrollView 对鼠标拖动的接管（与 `SettingsPages` 落点拖拽同一结论）。
    /// 视图只上报平移量、不动布局与尺寸，手势因此不会被中途 relayout 取消；
    /// 判据与会话都在控制器，与触控板通路共用同一份 `DrawerPageSwipe`。
    private var pageSwipeSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: DrawerPageSwipe.dragMinDistance)
                    .onChanged { actions.onSwipeDrag($0.translation) }
                    .onEnded { value in
                        // 第二个参数 = 预测终点：控制器据此折算松手速度判据。
                        actions.onSwipeDragEnded(value.translation, value.predictedEndTranslation)
                    }
            )
    }

    /// 从设置面板拖入抽屉组件时的落点占位（虚线框）：位置与尺寸都用落点的
    /// 格坐标算，与块容器共用 `geometry`（所见即所得）。
    @ViewBuilder
    private var dropPlaceholder: some View {
        if let cell = dropPlaceholderCell {
            let frame = geometry.frame(cell)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.5))
                )
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
        }
    }

    /// 从设置面板拖入时的落点格（无落点为 nil）：位置与尺寸都用格坐标算，
    /// 与块容器同一套换算（所见即所得）。
    private var dropPlaceholderCell: GridCell? {
        guard let preview = ui.dropPreview, !preview.isCompact,
              case let .drawer(column, row, columns, rows) = preview.zone else { return nil }
        return GridCell(column: column, row: row, columnSpan: columns, rowSpan: rows)
    }

    /// 网格渲染几何：列基准取 `drawerGridLeftColumn`（左扩时为负）。
    ///
    /// `capacity` 传 `.max`——视图只做渲染换算，落点夹紧由控制器侧的
    /// `drawerScreenMapper(for:)` 负责（那里能拿到 `effectiveMaxColumns`）。
    private var geometry: DrawerGridGeometry {
        DrawerGridGeometry(
            metrics: GridMetrics.current,
            leftColumn: ui.drawerGridLeftColumn,
            capacity: .max,
            minimumRows: ui.drawerGridMinRows,
            minimumColumns: ui.drawerGridMinColumns
        )
    }

    /// 单个抽屉块容器（含定位修饰）：独立成方法拆开类型检查表达式——
    /// 全部内联在 grid 里会超出编译器合理检查时间。
    private func blockContainer(for element: DrawerElement) -> some View {
        let origin = resolveOrigin(for: element)
        // 遗留布局数据的跨度可能为 0 或负：`max(_, 0)` 让 frame 退化为零
        // 尺寸（与改动前 `> 0 ? ... : 0` 的三元判断等价）。
        let blockFrame = geometry.frame(
            GridCell(
                column: origin.column,
                row: origin.row,
                columnSpan: max(element.placement.widthColumns, 0),
                rowSpan: max(element.placement.heightRows, 0)
            )
        )
        let previewSpan = interaction.previewSpan(for: element.id)
        return DrawerBlockContainer(
            element: element,
            isEditing: ui.isEditing,
            isDragging: interaction.draggingPlacementID == element.id,
            hasSettings: element.hasSettings,
            previewColumns: previewSpan?.columns,
            previewRows: previewSpan?.rows,
            onResizeChanged: { translation in
                interaction.updateResize(
                    element.id,
                    translation: translation,
                    placement: element.placement,
                    supportedSpans: element.supportedSpans,
                    metrics: GridMetrics.current
                )
            },
            onResizeCommit: { interaction.commitResize(element.id) },
            onRemove: { actions.onRemoveBlock(element.id) },
            onShowSettings: { anchorFrame in
                actions.onShowBlockSettings(
                    element.placement.pluginID,
                    element.id,
                    anchorFrame
                )
            },
            onDragChanged: { translation in
                interaction.beginDrag(element.id)
                let target = dragTarget(for: element, translation: translation)
                // 推挤预览与落点占位框都在这里更新（详见 DrawerInteractionState）。
                interaction.updateDrag(
                    element.id,
                    column: target.0,
                    row: target.1,
                    span: GridSpan(
                        columns: element.placement.widthColumns,
                        rows: element.placement.heightRows
                    )
                )
            },
            onDragEnded: { translation in
                let target = dragTarget(for: element, translation: translation)
                // 落位动画无需额外代码：调用方（DrawerBlockContainer）已用
                // **同一个** spring 常量把 dragOffset 归零，与提交触发的
                // placement 变化在同一个 runloop tick 起播；两者视觉位置相加
                // （position + offset）即为「从光标 spring 飞到落点」的单条
                // 曲线。参数一旦漂移，合成曲线会折一下——这就是
                // DrawerAnimation 必须唯一的原因。
                interaction.endDrag(element.id, column: target.0, row: target.1)
            }
        )
        .frame(width: blockFrame.width, height: blockFrame.height)
        .position(x: blockFrame.midX, y: blockFrame.midY)
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
        var cells: [GridCell] = ui.drawerElements.map { element in
            let origin = resolveOrigin(for: element)
            // 正在缩放的块以预览行数计——模型里的 heightRows 还是旧值，
            // 底层块长高时它是唯一增高来源。
            let rows = interaction.previewSpan(for: element.id)?.rows
                ?? element.placement.heightRows
            return GridCell(
                column: origin.column,
                row: origin.row,
                columnSpan: element.placement.widthColumns,
                rowSpan: rows
            )
        }
        // 落点在末尾新行时也要撑开：否则占位框被 ScrollView 裁掉
        // （网格内容高度是滚动区的唯一来源）。
        if let drop = dropPlaceholderCell {
            cells.append(drop)
        }
        return geometry.contentHeight(covering: cells)
    }

    private func resolveOrigin(for element: DrawerElement) -> LayoutEngine.GridOrigin {
        interaction.resolveOrigin(
            placementID: element.id,
            committed: LayoutEngine.GridOrigin(
                column: element.placement.originColumn,
                row: element.placement.originRow
            )
        )
    }

    private func dragTarget(
        for element: DrawerElement,
        translation: CGSize
    ) -> (Int, Int) {
        let target = DragTargetResolver.target(
            placement: element.placement,
            translation: translation,
            metrics: GridMetrics.current
        )
        return (target.column, target.row)
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
