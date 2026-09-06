import Foundation
import NotchCenterKit

/// 面板 UI 状态（ObservableObject）：由控制器更新、SwiftUI 视图直接观察。
///
/// 面板内容不再通过重新赋值 `NSHostingView.rootView` 刷新——在透明无边框的
/// `NSPanel` 上该路径不能保证立即重绘（表现为按钮图标等要等下次窗口操作才更新），
/// 改为 `@Published` 驱动 SwiftUI 自身的刷新管线。宿主视图只在创建时设置一次 root。
@MainActor
final class PanelUIState: ObservableObject {
    @Published var isPinned = false
    @Published var isEditing = false

    /// 设置窗口是否可见（经控制器 computed 转发；抽屉顶栏提示标签据此显隐）。
    @Published var isSettingsPresented = false

    /// 可见面板尺寸（参考 codex-island 的 model.size：唯一动画真源）：
    /// 收起 = 紧凑带尺寸（宽=带、高=0 内容），展开 = 完整抽屉。一切尺寸
    /// 变化都在 withAnimation 里发生，容器 frame 直接绑定它做 spring 变形
    /// ——窗口 frame 永不参与动画（固定满高窗口）。
    @Published var drawerWindowSize: CGSize = .zero

    /// 抽屉是否展开（内容存在性与命中测试开关）。
    @Published var isDrawerExpanded = false

    /// 紧凑区元素（随屏幕切换/布局编辑变化）。紧凑带几何（刘海尺寸、
    /// 槽位布局）不在这里——它按屏幕各异，由各面板以 `layout` 参数持有
    /// （热区/抽屉视图用所属 pair 的几何，不共享主屏几何）。
    @Published var compactElements: [CompactElement] = []
    /// 当前紧凑图标数：紧凑带宽度随其动态伸缩（视图侧槽位几何 =
    /// layout.compactStrip(slotCount: compactCount)）。控制器在每次内容
    /// 重建时同步。
    @Published var compactCount = 0
    @Published var showsClickModeHint = false

    /// 抽屉网格内容。
    /// 可见面板尺寸见上方 `drawerWindowSize`（唯一动画真源）。
    @Published var drawerContentSize: CGSize = .zero
    /// 格网内容最左列（列双向扩大：左侧拖出时可为负）：块渲染横坐标 =
    /// (originColumn − 该值) × 步长，使左扩时内容整体右移、面板绕刘海对称增宽。
    @Published var drawerGridLeftColumn = 0
    /// 网格行/列下限的布局镜像：视图拿不到 `LayoutEngine`，只能经这里下发给
    /// `DrawerGridGeometry` 构造点（夹紧语义见 `DrawerGridGeometry.minimumRows`）。
    @Published var drawerGridMinRows = LayoutModel.defaultMinRows
    @Published var drawerGridMinColumns = LayoutModel.defaultMinColumns
    @Published var drawerElements: [DrawerElement] = []

    /// 页面显示序列 / 自定义标题与图标：layout.json 的镜像，经 `rebuildContent` 同步。
    /// 激活页是运行时状态，不落盘。
    @Published var drawerPages: [Int] = [0]
    @Published var drawerActivePage = 0
    @Published var drawerPageTitles: [String: String] = [:]
    @Published var drawerPageIcons: [String: String] = [:]

    /// 拖拽/缩放或胶囊排序进行中（供 `canSwipeDrawerPage` 让路），由 DrawerPanelView 聚合写入。
    @Published var isDrawerInteractionActive = false

    /// 一次左右滑动会话（非空 = 正在滑动，目标页正从侧面滑入）。
    /// 跟手期只有 `offset` 与**派生尺寸**在动（`drawerWindowSize` /
    /// `drawerContentSize` 随滑动进度在其起止两端间插值，见
    /// `NotchPanelContent.updateDrawerSwipe`）——注意尺寸插值的两端、
    /// 位移上限都在会话里冻结，`rebuildContent` 仍是提交后尺寸的唯一出口。
    @Published var drawerSwipe: DrawerSwipe?

    /// 滑动会话快照：`elements` 是目标页的**真实例**（`isPreview: false`，走
    /// 正常缓存键并回写视图缓存），前进/落位时直接转正为 `drawerElements`。
    /// 条带模型：一次会话 = 原点页 + 一侧邻居构成的"两层页带"在视口里跟手移动，
    /// `offset` 是带符号**条带位移**（原点 = `originPage`）。位移穿越原点（死区外）
    /// 时整条带换绑到另一侧邻居（`rebind`）——方向、目标与条带层都变，唯独
    /// 原点锚（起点两尺寸）恒不动；推过目标页覆盖点时原点**前进**到目标页并
    /// 换绑更远邻居（连页，`NotchPanelContent.advanceDrawerSwipe`）。会话全程
    /// 可被新手势接管（自驱弹簧的状态值即表现值，取消驱动器即接管，零瞬移）。
    struct DrawerSwipe {
        /// 会话身份：自驱弹簧驱动器与收尾拍按它核对"仍是这一次会话"——
        /// 换绑/前进保留同一身份（同一次手势的延续），新建/清场换新。
        let id = UUID()
        /// 会话原点页（= 建会时的激活页，**覆盖点前进时推进到新原点**）：
        /// 中途反手换绑的邻居始终以它为基准解析；尺寸插值的起点永远钉在
        /// 它的尺寸上——反手换绑绝不再冻结起点（旧实现把中间插值值当新
        /// 起点，回退终点变成中间值，抽屉尺寸卡死）。
        var originPage: Int
        /// 当前条带方向（换绑后更新，不再恒定）。
        var side: DrawerPageSide
        /// 当前目标页（+ 其真实例层与尺寸，换绑时整体刷新）。
        var targetPage: Int
        var elements: [DrawerElement]
        /// 目标页内容尺寸（条带层宽度；尺寸插值的终点之一）。
        var contentSize: CGSize
        /// 目标页窗口尺寸（屏幕封顶后；尺寸插值的终点之一）。
        var targetWindowSize: CGSize
        /// 目标页格网最左列，与 `drawerGridLeftColumn` 同义。
        var leftColumn: Int
        /// 目标页层与原点页层的带符号间距（相邻页宽 + 页带留白，换绑时重算；
        /// 留白 = `DrawerPageSwipe.bandSpacing`，两倍内容边距）。
        var gap: CGFloat
        /// 会话开始时的内容尺寸（网格层宽度在会话期冻结为此值；尺寸插值起点，
        /// **反手换绑不更新**——唯一例外是覆盖点前进：前进帧条带正好停在目标
        /// 页全覆盖（p=1），起点重冻结在插值终点值上自洽，见
        /// `NotchPanelContent.advanceDrawerSwipe`）。
        var startContentSize: CGSize
        /// 会话开始时的窗口尺寸（尺寸插值起点；更新例外同上）。
        var startWindowSize: CGSize
        /// 当前条带的位移上限（橡皮筋与落位门槛按它取 = |gap|：右侧束带 =
        /// 原点页宽 + 留白、左侧束带 = 目标页宽 + 留白，换绑时更新）。
        var limit: CGFloat
        /// 当前位移（pt，带符号；与手指同向）。自驱弹簧在飞时本字段每帧被
        /// 写成屏幕表现值——接管（grab）以它为种子，零瞬移。
        var offset: CGFloat
        /// 输入重锚状态（覆盖点前进 / 动画接管时重置）：`gestureSeed` 是重锚
        /// 时的条带位移（band pt），`gestureAnchor` 是拖拽通路的重锚屏幕输入
        /// 位（`translation.width`；触控板通路的锚在 `DrawerPageScrollTracker
        /// .anchor`）。跟手位移 = 种子 + 锚后增量 × 屏幕换算比。建会时双零。
        var gestureSeed: CGFloat = 0
        var gestureAnchor: CGFloat = 0

        /// 滑动进度 p ∈ [0,1]（位移 / 落位全程）：面板尺寸插值与胶囊高亮层
        /// 都从这一份进度派生——跟手、落位 spring 与回弹天然同曲线。
        var progress: CGFloat { DrawerPageSwipe.progress(offset: offset, gap: gap) }

        /// 换绑到另一侧邻居：只换条带量（方向/目标/条带层/尺寸/间距/上限），
        /// 原点锚（起点两尺寸）与位移保持不动。换绑只发生在 |offset| ≈ 死区：
        /// 旧目标页层已整层移出视口、新目标页层整层还在视口外，这一帧的层替换
        /// 不可见（与落位交接同一条"像素重合"原理）。
        mutating func rebind(
            side: DrawerPageSide,
            targetPage: Int,
            elements: [DrawerElement],
            contentSize: CGSize,
            targetWindowSize: CGSize,
            leftColumn: Int,
            gap: CGFloat,
            limit: CGFloat
        ) {
            self.side = side
            self.targetPage = targetPage
            self.elements = elements
            self.contentSize = contentSize
            self.targetWindowSize = targetWindowSize
            self.leftColumn = leftColumn
            self.gap = gap
            self.limit = limit
        }
    }

    /// 从设置面板拖拽组件时的落点预览（抽屉网格虚线占位 / 快速区插入指示）。
    /// 仅在拖拽会话期间非空，由 `BlockDragCoordinator` 经控制器写入。
    @Published var dropPreview: DropPreview?

    /// 落位飞行期间**被隐藏**的块（目前只有从设置面板拖入的新块）。
    ///
    /// 非空时该块以 `opacity(0)` 渲染——飞行全程屏幕上只有跟手浮窗一份
    /// 内容，避免重影；飞行结束后在同一次更新里清空，交接不留空帧。
    /// 这是一个纯视觉状态，任何异常路径都必须无条件清掉它，
    /// 否则块会永久隐形（见 `DragPreviewLanding.cancel`）。
    @Published var landingPlacementID: String?

    /// 活动摘要序列（插件活动状态的紧凑带展示，按提交顺序维护，新提交追加在
    /// 尾；同 id 覆盖更新、不改变新旧次序）。由控制器经 HostController
    /// showActivitySummary / removeActivitySummary 维护；展示排布（每侧一条、
    /// 最新优先、抽屉展开期间让位）见 `ActivitySummaryDisplay.visiblePair`。
    @Published var activitySummaries: [ActivitySummary] = []
    /// 左侧摘要芯片宽度（控制器按摘要文案估算的镜像；无摘要/抽屉展开期间为 0）。
    @Published var summaryLeftWidth: CGFloat = 0
    /// 右侧摘要芯片宽度（同上）。
    @Published var summaryRightWidth: CGFloat = 0

    /// 当前应展示的左右摘要（含抽屉展开让位规则）。
    var visibleSummaryPair: (left: ActivitySummary?, right: ActivitySummary?) {
        ActivitySummaryDisplay.visiblePair(
            from: activitySummaries,
            drawerExpanded: isDrawerExpanded
        )
    }

    /// 布局生效的左侧摘要宽度（让位/无摘要时为 0）。
    var effectiveSummaryLeftWidth: CGFloat {
        visibleSummaryPair.left == nil ? 0 : summaryLeftWidth
    }

    /// 布局生效的右侧摘要宽度（让位/无摘要时为 0）。
    var effectiveSummaryRightWidth: CGFloat {
        visibleSummaryPair.right == nil ? 0 : summaryRightWidth
    }

    /// 按本状态构建紧凑条带几何：视图与命中测试都从这一处取（不直读引擎）。
    func compactStrip(layout: NotchLayout, slotCount: Int) -> CompactStripLayout {
        layout.compactStrip(
            slotCount: slotCount,
            leftSummaryWidth: effectiveSummaryLeftWidth,
            rightSummaryWidth: effectiveSummaryRightWidth
        )
    }

    struct DropPreview: Equatable {
        let zone: BlockDragCoordinator.DropZone
        /// 被拖的是快捷按钮（紧凑块）：快速区画插入指示，不画网格占位。
        let isCompact: Bool
        let title: String
        /// 光标横坐标（紧凑带内容坐标）：插入指示线据此跟随光标——快速区为空
        /// （没有槽位可参照）时，指示线不能只画在刘海中心。
        let compactPointerX: CGFloat?
        /// 编辑模式内部重排时被拖图标的数组下标（从设置面板拖入为 nil）。
        /// 非空时视图按“插入后的屏幕顺序”给每个图标算显示槽位——
        /// 拖动过程中其余图标平滑让位。
        let draggingSlotIndex: Int?
        /// 落点来自**抽屉内重排**（区别于从设置面板拖入）。
        /// 两种来源共用同一份虚线占位框绘制，此标记只用于判等与调试——
        /// 拖动目标跨来源切换时必须算作「目标变了」，否则占位框会卡在
        /// 上一个来源的位置。
        let isDrawerReorder: Bool

        init(
            zone: BlockDragCoordinator.DropZone,
            isCompact: Bool,
            title: String,
            compactPointerX: CGFloat? = nil,
            draggingSlotIndex: Int? = nil,
            isDrawerReorder: Bool = false
        ) {
            self.zone = zone
            self.isCompact = isCompact
            self.title = title
            self.compactPointerX = compactPointerX
            self.draggingSlotIndex = draggingSlotIndex
            self.isDrawerReorder = isDrawerReorder
        }

        /// 拖动目标是否与另一份预览一致（忽略逐帧变化的光标坐标）：
        /// 仅目标变化时才带动画更新，否则每帧都会重启动画。
        func matchesTarget(of other: DropPreview) -> Bool {
            zone == other.zone
                && isCompact == other.isCompact
                && draggingSlotIndex == other.draggingSlotIndex
                && isDrawerReorder == other.isDrawerReorder
        }
    }
}
