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
    let onSelect: (Int) -> Void
    let onAdd: (DrawerPageSide) -> Void
    let onMove: (Int, Int) -> Void
    let onRename: (Int, String) -> Void
    let onRemove: (Int) -> Void

    /// 拖动中的被拖页与它当前的目标槽位（松手提交后清空）。
    @State private var draggedPage: Int?
    @State private var targetIndex: Int?

    var body: some View {
        HStack(spacing: DrawerPagePillLayout.addSpacing) {
            addButton(.left)

            HStack(spacing: DrawerPagePillLayout.pillSpacing) {
                ForEach(Array(pages.enumerated()), id: \.element) { slot, page in
                    pill(page: page, slot: slot)
                }
            }

            addButton(.right)
        }
        .frame(height: DrawerPagePillLayout.rowHeight)
        // 行上不得挂 `.animation(value:)`：`targetIndex` 每越过半格边界变一次，
        // 行级隐式动画会把同一帧里被拖胶囊的跟手位移一起 spring 化，胶囊就成了
        // "追赶光标"（与 `updateDrawerSwipe` 的"跟手不加动画"同源）。让位动画
        // 由各胶囊自己的 `.animation(value: shift)` 负责。
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
            isActive: page == activePage,
            isEditing: isEditing,
            shift: shift,
            onSelect: { onSelect(page) },
            onDragTargetChanged: { target in
                draggedPage = page
                targetIndex = target
            },
            onDragCommit: { target in
                // 先提交（内容重建到新顺序）再清预览：反了会先跳回旧顺序、
                // 再动画到新位置，肉眼是一次回弹。
                onMove(page, target)
                // 清预览必须显式带上与换序同一条 spring：基座位移动画来自
                // `rebuildContent(animated:)`，而 `shift → 0` 是这次写入触发的，
                // 两者不同曲线就会在松手帧错开一整格。
                withAnimation(DrawerAnimation.spring) {
                    draggedPage = nil
                    targetIndex = nil
                }
            },
            onRename: { title in onRename(page, title) },
            onRemove: { onRemove(page) }
        )
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

// MARK: - 单颗页面胶囊

/// 独立结构体而非视图方法：悬停高亮、拖动位移与就地重命名都要持 `@State`。
private struct DrawerPagePill: View {
    let page: Int
    let slot: Int
    let count: Int
    /// 胶囊文字（空串 = 画主页房子图标）。
    let label: String
    let help: String
    let isActive: Bool
    let isEditing: Bool
    /// 让位预览的槽位偏移（被拖者恒为 0——它跟手靠 `dragOffset`）。
    let shift: Int
    let onSelect: () -> Void
    let onDragTargetChanged: (Int) -> Void
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
        // 让位平移 + 跟手位移都只作用在渲染层（布局槽位始终钉死在原位）。
        .offset(x: CGFloat(shift) * DrawerPagePillLayout.step + (isDragging ? dragOffset : 0))
        .scaleEffect(isDragging ? 1.06 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.45 : 0), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(DrawerAnimation.spring, value: isDragging)
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
        if label.isEmpty {
            Image(systemName: "house.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.45))
        } else {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
        }
    }

    /// 亮度分层沿用顶栏按钮的四级层次。
    private var fillOpacity: Double {
        if isActive { return isHovering ? 0.20 : 0.16 }
        return isHovering ? 0.10 : 0.055
    }

    private var capsuleFill: some View {
        Capsule(style: .continuous).fill(.white.opacity(fillOpacity))
    }

    private var capsuleStroke: some View {
        Capsule(style: .continuous)
            .strokeBorder(.white.opacity(isActive ? 0.16 : 0.06), lineWidth: 1)
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
