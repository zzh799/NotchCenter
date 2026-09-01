import SwiftUI

// MARK: - 纯几何：胶囊行槽位与拖动落点

/// 分页胶囊行的槽位数学（值类型、无视图依赖，可在单测里逐分支重放）。
///
/// 前提是胶囊**定宽等距**：槽位原点 = 槽位 × `step`，因此拖动落点只需位移量、
/// 不必测量任何 frame。
enum DrawerPagePillLayout {
    static let pillWidth: CGFloat = 34
    static let pillHeight: CGFloat = 22
    /// 每颗胶囊的**命中/悬停框**高度：比胶囊高一档，顶角的重命名与删除角标才
    /// 落在自己的框内——角标若探出框外，指针一移过去 `onHover` 就翻回 false，
    /// 角标当场消失、永远点不到。
    static let rowHeight: CGFloat = 28
    static let pillSpacing: CGFloat = 4
    /// 加号在胶囊**外**，不参与排序数学。
    static let addSpacing: CGFloat = 6
    static let badgeSide: CGFloat = 12
    /// 就地重命名时编辑框宽度：34pt 装不下几个字，让它向两侧探出邻位。
    static let editorWidth: CGFloat = 68
    /// 按压位移超过该值才认定是拖动（否则视同点击切页）。
    static let dragPickupDistance: CGFloat = 4

    static var step: CGFloat { pillWidth + pillSpacing }

    /// 高亮层左缘横坐标：激活槽位 → 目标槽位的线性插值（槽距 = `step`，
    /// 胶囊定宽等距，两侧终点即两颗胶囊各自的左缘）。进度的来源是滑动
    /// 会话的 offset/gap——跟手、落位 spring 与回弹共用同一份进度。
    static func highlightX(fromSlot: Int, toSlot: Int, progress: CGFloat) -> CGFloat {
        let p = min(max(progress, 0), 1)
        return (CGFloat(fromSlot) + (CGFloat(toSlot) - CGFloat(fromSlot)) * p) * step
    }

    static func targetIndex(draggedIndex: Int, translation: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let shifted = draggedIndex + Int((translation / step).rounded())
        return min(max(shifted, 0), count - 1)
    }

    /// 预览期某槽位的内容应显示在哪个槽位：被拖者**留在原槽位**（基座钉死，
    /// 跟手只靠 offset），其余在被跨越的区间内整体平移一位。
    ///
    /// 必须与 `LayoutEngine.moveDrawerPage`（remove + insert）逐位同解，
    /// 否则松手瞬间会看到一次回弹。
    static func displayIndex(slot: Int, draggedIndex: Int, targetIndex: Int) -> Int {
        if slot == draggedIndex { return draggedIndex }
        if draggedIndex < targetIndex, slot > draggedIndex, slot <= targetIndex {
            return slot - 1
        }
        if draggedIndex > targetIndex, slot >= targetIndex, slot < draggedIndex {
            return slot + 1
        }
        return slot
    }
}

// MARK: - 外观参数：胶囊底衬与悬浮高光

/// 分页胶囊与滑动高光（`PagePillHighlight`）的全部**视觉常量**（不透明度分层、
/// 投影），与 `DrawerPagePillLayout`（几何与槽位数学）职责分离：
/// 调视觉不碰几何、调几何不碰视觉。
enum DrawerPagePillAppearance {
    /// 底衬填充：胶囊只有「本身 × 悬停」两档——选中态不落在胶囊上，
    /// 由**常驻高光层**（`PagePillHighlight`）表示（常驻 = 不消失、不变淡）。
    static let hovering: Double = 0.10
    static let normal: Double = 0.055
    /// 底衬描边：单档（悬停不加重；选中态归高光层）。
    static let strokeOpacity: Double = 0.06

    /// 悬浮高光（`PagePillHighlight`）的填充/描边不透明度。比胶囊底衬（0.055/0.06）
    /// 明显更实——高光在行内是**悬浮组件**：更实的填充盖住底下胶囊底衬
    /// （不叠加刺眼）、亮描边压过底衬细边、阴影提供空间层次；移动过程中
    /// 底下底衬的明暗变化（间隙/胶囊交界）被高光自身亮度吞掉，衔接自然。
    static let highlightFillOpacity: Double = 0.24
    static let highlightStrokeOpacity: Double = 0.24
    /// 悬浮高光的投影：把高光从胶囊底衬平面"抬起"一层（不放这个就还是
    /// 同平面的第二颗胶囊，观感发闷）。
    static let highlightShadowOpacity: Double = 0.30
    static let highlightShadowRadius: CGFloat = 5
    static let highlightShadowY: CGFloat = 2
}

// MARK: - 抽屉分页胶囊行（顶栏中间）

/// 抽屉多页面导航：**每个页面一颗独立胶囊**，行首与行尾各一颗**胶囊外的加号**。
///
/// - 胶囊内容：自定义标题优先，否则显示它在显示序列里的 1-based 序号；
///   主页无标题时画房子图标。
/// - 加号只在 `showsAddButtons`（编辑模式 + 指针悬停顶栏）时出现。
/// - 编辑模式悬停胶囊：左上齿轮（就地重命名）、右上删除（连页内块，
///   非空页由控制器二次确认）；主页不给删除，横向可拖动排序。
/// - 点击与拖动共用一条按压机势（见 `DrawerPagePill.pressGesture`）：非编辑模式
///   只认点击，越阈的横向位移不会被判成拖动。
struct DrawerPageCapsule: View {
    let pages: [Int]
    let titles: [String: String]
    let activePage: Int
    let isEditing: Bool
    /// 两颗加号的显隐（编辑模式且指针悬停在顶栏上）。
    let showsAddButtons: Bool
    /// 滑动切页会话（nil = 静止）：高亮层**常驻**——静止时落在激活页
    /// 胶囊上；会话期从激活胶囊向目标胶囊随滑动进度平移（跟手逐帧、落位
    /// spring）。胶囊本身只分「本身/悬停」两档，选中态完全归高光层。
    let swipe: PanelUIState.DrawerSwipe?
    let onSelect: (Int) -> Void
    let onAdd: (DrawerPageSide) -> Void
    let onMove: (Int, Int) -> Void
    let onRename: (Int, String) -> Void
    let onRemove: (Int) -> Void

    /// 拖动中的被拖页与它当前的目标槽位（松手提交后清空）。
    @State private var draggedPage: Int?
    @State private var targetIndex: Int?
    /// 被拖胶囊的实时跟手位移（与胶囊内部 `dragOffset` 同源，经
    /// `onDragOffsetChanged` 逐帧收上来的镜像）：激活页被拖时高光层要跟着
    /// 这颗胶囊走（基座钉原槽、位移跟手），松手提交后一并清空。
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: DrawerPagePillLayout.addSpacing) {
            addButton(.left)

            // 高亮层与胶囊行同处一个 ZStack：**常驻**的"悬浮"选中标记——
            // 静止时钉在激活页胶囊上，滑动切页时随进度在激活/目标之间平移
            //（见 `PagePillHighlight`）。
            ZStack(alignment: .topLeading) {
                PagePillHighlight(
                    pages: pages,
                    activePage: activePage,
                    swipe: swipe,
                    draggedPage: draggedPage,
                    targetIndex: targetIndex,
                    dragOffset: dragOffset
                )
                HStack(spacing: DrawerPagePillLayout.pillSpacing) {
                    ForEach(Array(pages.enumerated()), id: \.element) { slot, page in
                        pill(page: page, slot: slot)
                    }
                }
            }

            addButton(.right)
        }
        .frame(height: DrawerPagePillLayout.rowHeight)
        // 行上不得挂 `.animation(value:)`：`targetIndex` 每越过半格边界变一次，
        // 行级隐式动画会把同一帧里被拖胶囊的跟手位移一起 spring 化，胶囊就成了
        // "追赶光标"（与 `updateDrawerSwipe` 的"跟手不加动画"同源）。让位动画
        // 由各胶囊自己的 `.animation(value: shift)` 负责。高亮层同理：它的位置
        // 由会话进度派生，跟手期直接渲染、落位期由控制器那条 spring 驱动，
        // 任何行级动画都会让它与位移脱钩。
    }

    // MARK: 胶囊

    private func pill(page: Int, slot: Int) -> some View {
        let shift: Int
        if let draggedPage,
           let draggedIndex = pages.firstIndex(of: draggedPage),
           let targetIndex {
            shift = DrawerPagePillLayout.displayIndex(
                slot: slot,
                draggedIndex: draggedIndex,
                targetIndex: targetIndex
            ) - slot
        } else {
            shift = 0
        }
        return DrawerPagePill(
            page: page,
            slot: slot,
            count: pages.count,
            label: label(for: page, slot: slot),
            help: LayoutModel.pageDisplayName(in: pages, page: page, titles: titles),
            // 胶囊壳不承载选中态（只有本身/悬停两档）；内容（图标/文本）亮度
            // 保留随激活与滑动进度的变化，作为常驻高光层的"内的呼应"。
            contentActivation: activationWeight(page: page, slot: slot),
            isEditing: isEditing,
            shift: shift,
            onSelect: { onSelect(page) },
            onDragTargetChanged: { target in
                draggedPage = page
                targetIndex = target
            },
            onDragOffsetChanged: { offset in
                dragOffset = offset
            },
            onDragCommit: { target in
                // 先提交（内容重建到新顺序）再清预览：反了会先跳回旧顺序、
                // 再动画到新位置，肉眼是一次回弹。
                onMove(page, target)
                // 清预览必须显式带上与换序同一条 spring：基座位移动画来自
                // `rebuildContent(animated:)`，而 `shift → 0` 是这次写入触发的，
                // 两者不同曲线就会在松手帧错开一整格。`dragOffset` 一并清空
                //（高光的跟手位移只存续于拖拽期）。
                withAnimation(DrawerAnimation.spring) {
                    draggedPage = nil
                    targetIndex = nil
                    dragOffset = 0
                }
            },
            onRename: { title in onRename(page, title) },
            onRemove: { onRemove(page) }
        )
    }

    /// 胶囊内容（图标/文本）的激活程度（0…1），与 `swipe.progress` 同源：
    /// - 无会话：激活页为 1、其余为 0（静态）；
    /// - 会话期：激活槽位按 (1 − p) 渐暗、目标页按 p 渐亮、其余恒 0——
    ///   与常驻高光层的移动互补（高光层是"面的高亮"，内容亮度是"内的呼应"），
    ///   落位/回弹随同一条 spring 收敛。胶囊壳只有本身/悬停两档，选中区分
    ///   由高光层承担，这里只保留内容的亮度呼应。
    private func activationWeight(page: Int, slot: Int) -> CGFloat {
        guard let swipe else { return page == activePage ? 1 : 0 }
        let p = swipe.progress
        if pages.firstIndex(of: activePage) == slot { return 1 - p }
        if swipe.targetPage == page { return p }
        return 0
    }

    /// 胶囊上的文字：自定义标题 → 序号；主页无标题时留空（画房子图标）。
    private func label(for page: Int, slot: Int) -> String {
        if let title = titles[String(page)], !title.isEmpty { return title }
        return page == LayoutModel.homePage ? "" : String(slot + 1)
    }

    // MARK: 加号（胶囊外）

    /// 行首/行尾加号：在对应侧新增页面。只在编辑模式且指针悬停顶栏时出现；
    /// 隐藏时保留槽位（否则胶囊行会跟着位移）且不吞点击。封顶后同样隐形。
    private func addButton(_ side: DrawerPageSide) -> some View {
        let isEnabled = pages.count < LayoutModel.maxDrawerPageCount
        let isVisible = showsAddButtons && isEnabled
        let help = side == .left
            ? L("panel.help.page.addLeft")
            : L("panel.help.page.addRight")
        return EditCircleButton(
            systemImage: "plus",
            helpText: help,
            diameter: 20,
            action: { onAdd(side) }
        )
        .accessibilityLabel(help)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        // 动画只挂在加号自身：胶囊行整体不得挂 `.animation(value:)`（见 `body`）。
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

// MARK: - 常驻悬浮高光（选中态的唯一表示）

/// 行内**常驻**的"悬浮"白色胶囊：选中态的唯一表示，从不消失、从不淡出。
///
/// - 静止（`swipe == nil`）：落在激活页胶囊上（`x = 激活槽 × step`），
///   全程满不透明度——胶囊壳只有本身/悬停两档，选中区分完全由这颗高光承担；
/// - 滑动会话期：从激活槽位向目标槽位线性平移（`DrawerPagePillLayout.highlightX`
///   与 `swipe.progress` 同源），跟手逐帧、落位/回弹随控制器那条 spring，
///   移动全程不淡出；会话清除后目标页即新激活页，高光恰好停在新激活槽，
///   零跳变、无淡入淡出；
/// - 编辑模式拖动排序预览期：跟随激活页的**显示槽位**（与胶囊让位共用
///   `displayIndex` 槽位数学），不会悬在空槽或邻居胶囊上。
///
/// 悬浮语义（为什么观感自然）：
/// - 胶囊底衬（0.055/0.06）画在高光之下——高光 0.24 的实填充盖住底下
///   底衬，经过胶囊/间隙交界时明暗变化被高光自身亮度吞掉，没有
///   "边框叠加 / 半路断裂"的衔接问题；
/// - 内容（图标/文本）画在高光之上，亮度随 `contentActivation` 呼应进度；
/// - 无动画修饰：跟手逐帧渲染，落位/回弹随控制器那条 spring，绝不加
///   行级/自身动画（见 `DrawerPageCapsule.body` 禁例）。
///
/// ⚠️ 必须用 `.offset` 定位、**不能用 `.position`**：`.position` 的布局
/// 尺寸恒等于父容器提案（greedy），会把胶囊行 ZStack 撑满整行宽度，
/// 而 ZStack 的 `.topLeading` 对齐又把胶囊 HStack 钉在行首——高光一
/// 挂载整行胶囊就贴到容器左边（真机报告）。`.offset` 不参与布局，
/// ZStack 继续贴合胶囊，高光只是视觉挪位。
private struct PagePillHighlight: View {
    let pages: [Int]
    let activePage: Int
    /// 滑动会话（nil = 静止，高光钉在激活页）。
    let swipe: PanelUIState.DrawerSwipe?
    /// 编辑模式拖动排序预览：被拖页与目标槽位（与 `shift` 同源）——非空时
    /// 高光跟随激活页的显示槽位，否则静止时钉在激活槽。
    let draggedPage: Int?
    let targetIndex: Int?
    /// 被拖胶囊的实时跟手位移（父级从 `onDragOffsetChanged` 收上来的镜像）：
    /// 被拖的就是激活页时，高光随胶囊一起走（基座钉原槽、位移跟手）。
    let dragOffset: CGFloat

    var body: some View {
        let y = (DrawerPagePillLayout.rowHeight - DrawerPagePillLayout.pillHeight) / 2
        return Capsule(style: .continuous)
            .fill(.white.opacity(DrawerPagePillAppearance.highlightFillOpacity))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        .white.opacity(DrawerPagePillAppearance.highlightStrokeOpacity),
                        lineWidth: 1
                    )
            }
            .frame(
                width: DrawerPagePillLayout.pillWidth,
                height: DrawerPagePillLayout.pillHeight
            )
            // 悬浮的最后一笔：投影把高光从底衬平面"抬起"（见常量注释）。
            .shadow(
                color: .black.opacity(DrawerPagePillAppearance.highlightShadowOpacity),
                radius: DrawerPagePillAppearance.highlightShadowRadius,
                y: DrawerPagePillAppearance.highlightShadowY
            )
            .offset(x: highlightX, y: y)
            // 高光自己的弹簧**只挂在离散槽位（animationKey）上**：编辑拖动排序期
            // target 越界时与胶囊 `shift` 的 spring 同帧同曲线；滑动会话期恒 -1
            // 不触发——位置逐帧直渲、落位/回弹由控制器那条 spring 驱动，
            // 遵循"跟手不加动画"（见 `animationKey` 注释）。
            .animation(DrawerAnimation.spring, value: animationKey)
            .allowsHitTesting(false)
    }

    /// 高光左缘横坐标（pt）。有会话走进度插值；无会话落在激活页胶囊上
    ///（`anchoredSlot × step`）；激活页被拖时再叠加胶囊的跟手位移——
    /// 基座钉原槽、位移一致，高光始终贴在被拖的激活胶囊上。
    private var highlightX: CGFloat {
        if let swipe {
            let fromSlot = pages.firstIndex(of: activePage) ?? 0
            let toSlot = LayoutModel.neighborPage(in: pages, active: activePage, side: swipe.side)
                .flatMap { pages.firstIndex(of: $0) }
                ?? fromSlot
            return DrawerPagePillLayout.highlightX(
                fromSlot: fromSlot,
                toSlot: toSlot,
                progress: swipe.progress
            )
        }
        let base = CGFloat(anchoredSlot) * DrawerPagePillLayout.step
        if let draggedPage, draggedPage == activePage {
            return base + dragOffset
        }
        return base
    }

    /// 无会话分支高光锚定的**槽位**：编辑拖动排序预览期 = 激活页的显示槽位
    ///（与胶囊让位共用 `displayIndex`，被拖页自身对 `displayIndex` 返回原槽——
    /// 基座钉死，跟手位移另走 `dragOffset`）；否则 = 激活槽。
    private var anchoredSlot: Int {
        var slot = pages.firstIndex(of: activePage) ?? 0
        if let draggedPage,
           let draggedIndex = pages.firstIndex(of: draggedPage),
           let targetIndex {
            slot = DrawerPagePillLayout.displayIndex(
                slot: slot,
                draggedIndex: draggedIndex,
                targetIndex: targetIndex
            )
        }
        return slot
    }

    /// 高光自身动画的**触发键**（离散槽位，不是连续位移）：编辑拖动排序期
    /// target 越界时 `anchoredSlot` 变一次，高光与胶囊的 `shift` spring
    ///（同用 `DrawerAnimation.spring`、同一位移量）同帧起滑——杜绝"胶囊在滑、
    /// 高光瞬跳"的不同步；**滑动会话期恒为 -1 不触发**：位置由会话进度派生，
    /// 逐帧直渲，落位/回弹由控制器那条 spring 驱动，任何行级/自身动画都会
    /// 让它与位移脱钩（见 `DrawerPageCapsule.body` 禁例），会话起止帧
    /// animationKey 跨越 -1 时 x 不变（进度=0 / 已落位），无可见动画。
    private var animationKey: Int {
        swipe == nil ? anchoredSlot : -1
    }
}

// MARK: - 单颗页面胶囊

/// 独立结构体而非视图方法：悬停高亮、拖动位移与就地重命名都要持 `@State`。
private struct DrawerPagePill: View {
    let page: Int
    let slot: Int
    let count: Int
    /// 胶囊文字（空串 = 画主页房子图标）。
    let label: String
    let help: String
    /// 胶囊内容（图标/文本）的"激活程度"（0…1）：决定内容亮度——
    /// 0 = 非激活档、1 = 激活档。滑动会话期由同一份 `progress` 驱动：
    /// 激活胶囊按 (1 − p) 渐暗、目标胶囊按 p 渐亮——内容变暗变亮与高亮层、
    /// 面板尺寸同步（跟手逐帧、落位/回弹随 spring）。无会话时 = 激活页 1、
    /// 其余 0。
    let contentActivation: CGFloat
    let isEditing: Bool
    /// 让位预览的槽位偏移（被拖者恒为 0——它跟手靠 `dragOffset`）。
    let shift: Int
    let onSelect: () -> Void
    let onDragTargetChanged: (Int) -> Void
    /// 跟手位移逐帧上报（**没有** target 越界也要报）：父级镜像这份位移，
    /// 供高光层在激活页被拖时随胶囊跟手（`DisplayIndex` 只覆盖槽位数学，
    /// 跟手位移是胶囊内部状态，父级拿不到就无从跟随）。
    let onDragOffsetChanged: (CGFloat) -> Void
    let onDragCommit: (Int) -> Void
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// 已上报的目标槽位：只在槽位真的变了时才通知父级（逐帧写 @State 会让
    /// 让位动画每次都被重启）。
    @State private var reportedTarget: Int?
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isEditorFocused: Bool

    private var isHome: Bool { page == LayoutModel.homePage }

    /// 编辑模式、且不在重命名中才允许拖动（重命名期手势要让位给文本选择）。
    private var canDrag: Bool { isEditing && !isRenaming }

    var body: some View {
        ZStack {
            if isRenaming {
                editor
            } else {
                pressSurface
            }
        }
        .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.rowHeight)
        .overlay(alignment: .top) { badgeCluster }
        // 拾取弹簧（scale/shadow）只作用于内层子树；位移层必须排在它**后**——
        // 否则 `isDragging` 翻转那一帧，offset 因 `dragOffset` 首次出现而跳变，
        // 会被同一条拾取 spring 化：胶囊滞后于光标，而高光的位移是直渲的，
        // 两者错位（真机长距离快速拖动复现）。跟手（`dragOffset`）必须直渲。
        .scaleEffect(isDragging ? 1.06 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.45 : 0), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(DrawerAnimation.spring, value: isDragging)
        // 位移层（渲染层位移，布局槽位始终钉死在原位）：与高光层的位移表达式
        // 严格同源——跟手位移直渲、只允许「让位/落位」（shift）走 spring。
        .offset(x: CGFloat(shift) * DrawerPagePillLayout.step + (isDragging ? dragOffset : 0))
        .animation(DrawerAnimation.spring, value: shift)
        .onHover { isHovering = $0 }
    }

    /// 胶囊的按压面：**不能是 `Button`**——按钮在 AppKit 层接管按下，鼠标拖动
    /// 的中间事件直到松手才回流给祖先手势，真机上表现为整行只在松开那一瞬才动
    ///（紧凑带图标能实时跟手，正因为它的图标不是按钮）。因此点击与拖动都由
    /// `pressGesture` 这一条手势分类，与 Kit 的 `blockPopoverTrigger` 同一结论。
    /// 手势挂在这一层（角标在更晚的 `overlay` 上）：落在角标上的按下归角标按钮。
    private var pressSurface: some View {
        content
            .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.pillHeight)
            .background(capsuleFill)
            .overlay(capsuleStroke)
            .frame(height: DrawerPagePillLayout.rowHeight)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .gesture(pressGesture)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            // 内容亮度随 `contentActivation` 在非激活档与激活档之间线性插值
            //（滑动进度同步；直接渲染不加动画，跟手逐帧更新）。
            if label.isEmpty {
                Image(systemName: "house.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45 + 0.5 * Double(contentActivation)))
            } else {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5 + 0.45 * Double(contentActivation)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
            }
        }
        // 内容换字（拖动排序提交后的序号重排）走**淡入淡出**：
        // `.id(label)` 换身份 + `.transition(.opacity)`——旧字淡出、新字淡入，
        // 不做随行平移（另一颗被排序胶囊在提交帧不位移，只有文字变化，
        // 瞬时替换刺眼；这也与"内容亮度跟手直渲"解耦——label 只在提交变，
        // 会话期 label 恒不变，不会波及滑动期的逐帧亮度）。
        .id(label)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: label)
    }


    /// 底衬填充不透明度：只有「本身 × 悬停」两档（见 `DrawerPagePillAppearance`）——
    /// 胶囊不承载选中态，选中区分由常驻高光层表示。
    private var fillOpacity: Double {
        isHovering
            ? DrawerPagePillAppearance.hovering
            : DrawerPagePillAppearance.normal
    }

    private var capsuleFill: some View {
        Capsule(style: .continuous)
            .fill(.white.opacity(fillOpacity))
    }

    private var capsuleStroke: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                .white.opacity(DrawerPagePillAppearance.strokeOpacity),
                lineWidth: 1
            )
    }

    // MARK: 编辑模式角标（齿轮重命名 / 删除页面）

    /// 顶角两条角标，落在胶囊自身的命中框内（见 `rowHeight` 注释），外观与
    /// 紧凑区角标同为 `EditGlyphButton`。齿轮是本页的命名入口（动作仍是
    /// 就地重命名）。
    @ViewBuilder
    private var badgeCluster: some View {
        if isEditing && isHovering && !isRenaming {
            HStack(spacing: 0) {
                EditGlyphButton(
                    systemImage: "gearshape.fill",
                    helpText: L("panel.help.page.rename"),
                    side: DrawerPagePillLayout.badgeSide
                ) {
                    beginRename()
                }
                Spacer(minLength: 0)
                if !isHome {
                    EditGlyphButton(
                        systemImage: "xmark.circle.fill",
                        helpText: L("panel.help.page.delete"),
                        side: DrawerPagePillLayout.badgeSide,
                        action: onRemove
                    )
                }
            }
            .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.badgeSide)
        }
    }

    // MARK: 就地重命名

    private var editor: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
            .multilineTextAlignment(.center)
            .frame(width: DrawerPagePillLayout.editorWidth)
            .padding(.horizontal, 4)
            .frame(height: DrawerPagePillLayout.pillHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.55))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                    )
            )
            .focused($isEditorFocused)
            .onExitCommand { cancelRename() }
            .onSubmit { commitRename() }
            .onChange(of: isEditorFocused) { _, focused in
                if !focused { commitRename() }
            }
    }

    private func beginRename() {
        draft = label
        isRenaming = true
        // 视图换成 TextField 之后才有可聚焦的对象，下一轮才拿得到焦点。
        DispatchQueue.main.async { isEditorFocused = true }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        isEditorFocused = false
        onRename(draft)
    }

    private func cancelRename() {
        isRenaming = false
        isEditorFocused = false
    }

    // MARK: 按压：点击切页 / 拖动排序

    /// 一条手势管两种意图（`minimumDistance: 0` 才能从按下那一刻起持续收到事件）：
    /// 横向位移越过 `dragPickupDistance` = 拖动，此后逐事件跟手 + 让位预览，松手
    /// 提交；始终未越阈 = 点击，走 `onSelect` 切页（编辑期也靠胶囊切页，不能只
    /// 剩拖动）。
    private var pressGesture: some Gesture {
        // **平移量必须在稳定坐标系度量**：默认 `.local` 空间挂在胶囊自己身上，
        // 胶囊一旦被 `.offset` 推动，下一次事件的 `translation` 就被这份位移扣掉，
        // 逐事件形成"前跳一整步 / 后退半格"的锯齿（实测 off 4.9→1.6→7.4→5.3→9.6，
        // 相邻两值之和才单调递增），表现为不跟手 + 闪烁。`.global` 在 NSHostingView
        // 里即宿主窗口坐标，抽屉窗口满尺寸固定、拖动期间不动（与缩放握把同一结论）。
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    guard canDrag else { return }
                    guard abs(value.translation.width) > DrawerPagePillLayout.dragPickupDistance else { return }
                    isDragging = true
                    reportedTarget = nil
                }
                dragOffset = value.translation.width
                // 逐帧上报（与 target 上报解耦）：位移用于高光跟随，越界才换槽。
                onDragOffsetChanged(dragOffset)
                let target = target(for: value.translation.width)
                guard target != reportedTarget else { return }
                reportedTarget = target
                onDragTargetChanged(target)
            }
            .onEnded { value in
                if isDragging {
                    let target = target(for: value.translation.width)
                    withAnimation(DrawerAnimation.spring) {
                        dragOffset = 0
                        isDragging = false
                    }
                    reportedTarget = nil
                    onDragCommit(target)
                    return
                }
                // 未进拖动还要位移没越阈才算点击：非编辑模式压根不认拖动，
                // 按下后拖一把再松手不该切页。
                guard hypot(value.translation.width, value.translation.height)
                        <= DrawerPagePillLayout.dragPickupDistance else { return }
                onSelect()
            }
    }

    private func target(for translation: CGFloat) -> Int {
        DrawerPagePillLayout.targetIndex(draggedIndex: slot, translation: translation, count: count)
    }
}
