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
/// - 编辑模式悬停胶囊：左上铅笔（就地重命名）、右上删除（连页内块，
///   非空页由控制器二次确认）；主页不给删除，横向可拖动排序。
/// - 与紧凑带图标同一门禁：非编辑模式 `including: .subviews` 等价于不挂手势。
struct DrawerPageCapsule: View {
    let pages: [Int]
    let titles: [String: String]
    let activePage: Int
    let isEditing: Bool
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
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: draggedPage)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: targetIndex)
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
                draggedPage = nil
                targetIndex = nil
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

    /// 行首/行尾常驻加号：在对应侧新增页面。封顶后隐形且不吞点击。
    private func addButton(_ side: DrawerPageSide) -> some View {
        let isEnabled = pages.count < LayoutModel.maxDrawerPageCount
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
        .opacity(isEnabled ? 1 : 0)
        .allowsHitTesting(isEnabled)
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
                button
            }
        }
        .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.rowHeight)
        .overlay(alignment: .top) { badgeCluster }
        // 让位平移 + 跟手位移都只作用在渲染层（布局槽位始终钉死在原位）。
        .offset(
            x: CGFloat(shift) * DrawerPagePillLayout.step
                + (isDragging ? dragOffset : 0)
        )
        .scaleEffect(isDragging ? 1.06 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.45 : 0), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isDragging)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: shift)
        .onHover { isHovering = $0 }
        // mask 必须是 `.all`：`.gesture` 会连带排除子视图手势，角标按钮就点不动了
        //（与紧凑带同一结论）。拖动仍由 DragGesture 超 4pt 位移后接管。
        .gesture(reorderGesture, including: canDrag ? .all : .subviews)
    }

    private var button: some View {
        Button(action: onSelect) {
            content
                .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.pillHeight)
                .background(capsuleFill)
                .overlay(capsuleStroke)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help)
        .accessibilityLabel(help)
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

    // MARK: 编辑模式角标（铅笔重命名 / 删除页面）

    /// 顶角两条角标，落在胶囊自身的命中框内（见 `rowHeight` 注释）。
    @ViewBuilder
    private var badgeCluster: some View {
        if isEditing && isHovering && !isRenaming {
            HStack(spacing: 0) {
                badge(systemImage: "pencil", help: L("panel.help.page.rename")) {
                    beginRename()
                }
                Spacer(minLength: 0)
                if !isHome {
                    badge(systemImage: "xmark.circle.fill", help: L("panel.help.page.delete"), action: onRemove)
                }
            }
            .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.badgeSide)
        }
    }

    private func badge(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: DrawerPagePillLayout.badgeSide, height: DrawerPagePillLayout.badgeSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBrighten()
        .help(help)
        .accessibilityLabel(help)
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

    // MARK: 拖动排序

    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDragging {
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
                let target = target(for: value.translation.width)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    dragOffset = 0
                    isDragging = false
                }
                reportedTarget = nil
                onDragCommit(target)
            }
    }

    private func target(for translation: CGFloat) -> Int {
        DrawerPagePillLayout.targetIndex(draggedIndex: slot, translation: translation, count: count)
    }
}
