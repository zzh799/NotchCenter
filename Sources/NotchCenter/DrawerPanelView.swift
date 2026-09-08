import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉面板（文档 §5.3 / §5.5）

/// 抽屉网格元素：已放置块 + 视图 + 尺寸盒（插件声明的最小/最大档）。
struct DrawerElement: Identifiable {
    let placement: PlacedBlock
    let view: AnyView
    /// 允许矩形盒的下角（来自块声明的 minSize；缩放预览/提交据此逐轴夹紧）。
    let minSize: GridSpan
    /// 允许矩形盒的上角（来自块声明的 maxSize）。
    let maxSize: GridSpan
    /// 当前已提交的跨度（与 placement 一致；布局遗留数据可能为 nil）。
    let currentSpan: GridSpan?
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

    /// 胶囊排序进行中（聚合至 `isDrawerInteractionActive`）。
    @State private var isCapsuleDragging = false

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
            // 带宽随当前紧凑图标数 + 活动摘要带宽伸缩（与热区窗口同源
            // `PanelUIState.compactStrip`：摘要可见性/让位一处判定）。
            compactView
                .frame(
                    width: ui.compactStrip(layout: layout, slotCount: ui.compactCount).windowWidth,
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
                .fill(NotchTokens.Surface.drawer)
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
        .onAppear {
            syncInteractionActive()
        }
        .onChange(of: interaction.phase) { _, _ in
            syncInteractionActive()
        }
        .onChange(of: isCapsuleDragging) { _, _ in
            syncInteractionActive()
        }
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
                // 拖动胶囊排序进行中隐藏加号：指针必然压在顶栏上，加号常亮会
                // 干扰拖动预览；隐藏只是 opacity 0，槽位占位不变、行宽恒定。
                showsAddButtons: ui.isEditing && isTopBarHovering && !isCapsuleDragging,
                swipe: ui.drawerSwipe,
                onSelect: actions.onSelectPage,
                onAdd: actions.onAddPage,
                onMove: actions.onMovePage,
                onShowSettings: actions.onShowPageSettings,
                onRemove: actions.onRemovePage,
                onDraggingChanged: { isCapsuleDragging = $0 }
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

    /// 滑动切页的**单一常驻页带**：一个 ForEach 同时承载稳态页与滑动会话，
    /// 元素源见 `bandItems`。会话期 = 原点页（随 `offset` 平移）+ 目标页
    /// **真实例**（随 `offset + gap` 平移、整层禁命中）构成一条**刚性页带**
    /// （两层之间隔一条页带留白 = 两倍内容边距的背景带，看得出是两页），
    /// 整体跟手平移、超出裁掉。前进/落位拍把 `drawerElements := 会话 elements`
    /// 且激活页切到目标页：目标页子视图在**同一个 ForEach 里身份保持**、
    /// 旧原点页在视口外卸载——交接零重挂载。旧"网格层 + 预览层"两层 ZStack
    /// 的病根：同一视图值换个结构位必被 SwiftUI 整批重挂，暂存区缩略图
    /// 归零回退图标、监控重挂探针的落位闪烁由此而来。
    /// 容器宽高跟随 `drawerContentSize`——会话期间该尺寸随滑动进度在起止两端间
    /// 插值（面板同步长大/缩小），页带本身保持刚性（两层间距恒 = 留白）。
    /// 容器高度 = 内容高度：内容 ≡ 可视区，ScrollView
    /// 才不闪滚动条（与 `gridFrameHeight` 同源教训；会话外二者恒等）。
    private var pageSlide: some View {
        let swipe = ui.drawerSwipe
        // 会话期条带宽冻结在会话起点值（拖拽面/占位框不随插值伸缩），稳态 = 内容宽。
        let bandWidth = swipe?.startContentSize.width ?? ui.drawerContentSize.width
        let zStack = ZStack(alignment: .topLeading) {
            ForEach(bandItems) { item in
                bandBlockContainer(for: item)
            }
            dropPlaceholder
                .offset(x: swipe?.offset ?? 0)
        }
        .frame(
            width: bandWidth,
            height: gridFrameHeight,
            alignment: .topLeading
        )
        .background {
            // 编辑态仅空隙可切页（块拖拽优先），非编辑态整面可切页由
            // pageSlide 的 simultaneousGesture 承载，避免空隙与整面双重触发。
            if ui.isEditing {
                pageSwipeSurface
            }
        }
        // 两条跟随元素变化的 spring 在**滑动会话挂载期必须关闭**：落位帧
        // 原点页子视图成批卸载，spring 参与就会在 x=0 上重影淡出（真机报告
        // "目标页面直接淡出"的根因）。
        .animation(swipe == nil ? DrawerAnimation.spring : nil, value: bandItems.map(\.id))
        .animation(swipe == nil ? DrawerAnimation.spring : nil, value: bandItems.map(\.element.placement))
        .animation(DrawerAnimation.spring, value: interaction.previewOrigins)
        .frame(
            width: ui.drawerContentSize.width,
            height: ui.drawerContentSize.height,
            alignment: .topLeading
        )
        .clipped()
        // 非编辑态整面可拖动切页（含块上方），编辑态仅空隙可切页（块拖拽优先，由页带背景层承载）。
        // 手势用 .global 坐标：面板宽度在跟手期插值，.local 原点随视图平移会导致 translation 逐帧回跳、形成原/目标尺寸的自激振荡（与缩放握把同源）。
        // 用 simultaneousGesture 而非 highPriority：让路时块的横向滚动仍可与切页手势并发识别，yield 后块自己处理滚动；外层纵向 ScrollView 与横向切页方向正交，不冲突。
        if ui.isEditing {
            return AnyView(zStack)
        } else {
            return AnyView(
                zStack
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: DrawerPageSwipe.dragMinDistance, coordinateSpace: .global)
                            .onChanged { actions.onSwipeDrag($0.translation) }
                            .onEnded { value in
                                actions.onSwipeDragEnded(value.translation, value.predictedEndTranslation)
                            }
                    )
            )
        }
    }

    /// 页带元素：稳态页或会话目标页的一个块 + 它在页带里的渲染参数。
    /// 身份 = placementID（跨页全局唯一）：落位拍目标页从"会话贡献"转为
    /// "稳态元素"时 id 不变，ForEach 据此保持子视图身份（零重挂载的关键）。
    private struct DrawerBandItem: Identifiable {
        let element: DrawerElement
        /// 渲染几何：稳态/原点页用激活页左列，会话目标页用目标页左列。
        let renderGeometry: DrawerGridGeometry
        /// 条带位移（视觉平移）：原点页 = `swipe.offset`，目标页 = `offset + gap`，稳态 = 0。
        let bandOffset: CGFloat
        /// 会话目标页在滑动中整层禁命中。
        let isInteractive: Bool

        var id: String { element.id }
    }

    /// 页带元素源：稳态 = `drawerElements`；会话挂载期 = 原点页（`drawerElements`）
    /// + 目标页（`swipe.elements`，目标页尚未转正时）。前进/落位拍把
    /// `drawerElements` 赋为会话 elements 且激活页切到目标页——两份来源在
    /// 同一事务里交接，ForEach 按 placementID 差分：目标页子视图保留、旧
    /// 原点页子视图卸载（此时已在视口外，卸载不可见）；回弹拍目标页滑出
    /// 视口后随会话清除而卸载，原点页子视图全程未动。会话目标页的渲染
    /// 几何按目标页左列起排（原点页几何仍是激活页的），交接帧
    /// `drawerGridLeftColumn` 已切到目标页、两套几何数值相等，frame 无缝衔接。
    /// 门控 = `targetPage != activePage`：目标页一旦转正（前进连页 / 落位收尾，
    /// 激活页同帧切换）就必须停止把它叠进页带，否则同一 placement 会以重复
    /// id 在 ForEach 里出现两份。
    private var bandItems: [DrawerBandItem] {
        var items: [DrawerBandItem] = []
        let swipe = ui.drawerSwipe
        let originOffset = swipe?.offset ?? 0
        for element in ui.drawerElements {
            items.append(DrawerBandItem(
                element: element,
                renderGeometry: geometry,
                bandOffset: originOffset,
                isInteractive: true
            ))
        }
        if let swipe, swipe.targetPage != ui.drawerActivePage {
            let targetGeometry = DrawerGridGeometry(
                metrics: GridMetrics.current,
                leftColumn: swipe.leftColumn,
                capacity: .max,
                // 全局下限、所有页共用：两层留白高度一致，落位交接那一帧才完全重合。
                minimumRows: ui.drawerGridMinRows,
                minimumColumns: ui.drawerGridMinColumns
            )
            for element in swipe.elements {
                items.append(DrawerBandItem(
                    element: element,
                    renderGeometry: targetGeometry,
                    bandOffset: swipe.offset + swipe.gap,
                    isInteractive: false
                ))
            }
        }
        return items
    }

    /// 页带块容器：与稳态网格同一渲染路径（编辑壳/角标/手势全同，编辑态
    /// 视觉与旧预览壳逐值一致，"预览素面 → 落位后突然压暗"不会复现），只是
    /// 渲染几何与条带位移按元素来源注入；会话目标页整层禁命中。**单一构建
    /// 路径**是身份保持的前提——同一子视图从"会话目标页"转正为"稳态元素"
    /// 时修饰符链结构不变，SwiftUI 只做值更新、不重挂。
    private func bandBlockContainer(for item: DrawerBandItem) -> some View {
        blockContainer(for: item.element, in: item.renderGeometry)
            .offset(x: item.bandOffset)
            .allowsHitTesting(item.isInteractive)
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
                DragGesture(minimumDistance: DrawerPageSwipe.dragMinDistance, coordinateSpace: .global)
                    .onChanged { actions.onSwipeDrag($0.translation) }
                    .onEnded { value in
                        // 第二个参数 = 预测终点：控制器据此折算松手速度判据。
                        // 坐标系必须用 .global：面板宽度在跟手期插值，.local 原点随视图平移会导致 translation 逐帧回跳、形成原/目标尺寸的自激振荡（与缩放握把同源）。
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
    /// 全部内联在页带里会超出编译器合理检查时间。`in renderGeometry` 注入
    /// 渲染几何：稳态/原点页传 `geometry`（激活页左列），会话目标页传目标页
    /// 左列的几何（见 `bandItems`）——`layoutInfo.frame` 喂插件的仍是引擎的
    /// 绝对列坐标，与本渲染几何无涉。
    private func blockContainer(
        for element: DrawerElement,
        in renderGeometry: DrawerGridGeometry
    ) -> some View {
        let origin = resolveOrigin(for: element)
        // 遗留布局数据的跨度可能为 0 或负：`max(_, 0)` 让 frame 退化为零
        // 尺寸（与改动前 `> 0 ? ... : 0` 的三元判断等价）。
        let blockFrame = renderGeometry.frame(
            GridCell(
                column: origin.column,
                row: origin.row,
                columnSpan: max(element.placement.widthColumns, 0),
                rowSpan: max(element.placement.heightRows, 0)
            )
        )
        let previewSpan = interaction.previewSpan(for: element.id)
        let isSwipeActive = ui.drawerSwipe != nil
        return DrawerBlockContainer(
            element: element,
            isEditing: ui.isEditing,
            isDragging: interaction.draggingPlacementID == element.id,
            hasSettings: element.hasSettings,
            isSwipeActive: isSwipeActive,
            previewColumns: previewSpan?.columns,
            previewRows: previewSpan?.rows,
            onResizeChanged: { translation in
                interaction.updateResize(
                    element.id,
                    translation: translation,
                    placement: element.placement,
                    minSize: element.minSize,
                    maxSize: element.maxSize,
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
                // 跨页拖拽：拖动中指针压上分页胶囊驻留即切页（命中与计时
                // 在 interaction；坐标必须取全局屏幕点，手势 translation
                // 只对块局部有意义）。
                interaction.updateCapsuleDwell(
                    at: NSEvent.mouseLocation,
                    activePage: ui.drawerActivePage
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

    /// 聚合块/胶囊拖动态写入 `isDrawerInteractionActive`。
    private func syncInteractionActive() {
        ui.isDrawerInteractionActive = interaction.phase != .idle || isCapsuleDragging
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
                .font(NotchTokens.Text.system(11, weight: .semibold))
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
