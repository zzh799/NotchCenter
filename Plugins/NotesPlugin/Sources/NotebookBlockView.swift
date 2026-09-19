import AppKit
import NotchCenterKit
import SwiftUI

/// 笔记抽屉块视图（官方 NotesPlugin）。
/// 由 NotchNotes 的 NotebookView 重构而来：不再依赖刘海几何、抽屉遮罩动画或内置暂存区；
/// 填充宿主分配的网格区域（文档 §4.2：视图自适应块尺寸）。
///
/// 多实例语义（文档 §4.3）：同一块类型可放置多次，每个放置实例（placementID）
/// 显示自己的标签页，但标签页数据由共享的 NotesStore 维护（增删改同步）。
struct NotesBlockView: View {
    @ObservedObject var store: NotesStore
    let imageStore: NotesImageStore
    @ObservedObject var editorInteractionState: EditorInteractionState
    let placementID: String
    /// 本实例在抽屉网格中的位置（用于“最上方实例”定位，紧凑图标新建入口）。
    let gridRow: Int
    let gridHeightRows: Int
    /// 只读预览副本：为真时本实例不写任何跨实例共享状态（契约见 `BlockLayoutInfo.isPreview`）。
    let isPreview: Bool

    /// 抽屉展开态。温存让 `onDisappear` 不再代表"用户看不到了"，而"最上方实例"
    /// 登记若在收起后残留，紧凑图标新建入口会去聚焦一个看不见的编辑器。
    @Environment(\.isDrawerPresented) private var isDrawerPresented

    @State private var activeTabID: UUID

    /// 指针是否悬停在本块上：右上角悬浮新建角标的浮出条件（角标恒落在块矩形内，
    /// 指针移到角标上不会翻回 false）。
    @State private var isHovering = false

    private let contentHorizontalPadding: CGFloat = 10
    private let contentVerticalPadding: CGFloat = 10
    private let toolbarHeight: CGFloat = 34
    private let editorSpacing: CGFloat = 8
    /// 右上角悬浮新建角标相对块边缘的内缩：与宿主编辑角标同一环
    /// （`DrawerBlockContainer` 的 `padding(6)`，同 ClipboardHistory / Camera /
    /// Scheduler 的块内角标）。角标直径 22 + 内缩 6×2 = 34pt 见方，**恰好落在
    /// 顶部分页条那 34pt 带内**，不侵入 `notes.textArea` 探针区。
    private let controlInset: CGFloat = 6
    /// 分页条要为角标让出的横向槽位（= 角标占位 22 + 内缩 6×2）：
    /// 角标只在悬浮时出现，槽位恒留，圆点才不会被浮动角标压住。
    private var controlSlot: CGFloat { 22 + controlInset * 2 }

    init(
        store: NotesStore,
        imageStore: NotesImageStore,
        editorInteractionState: EditorInteractionState,
        placementID: String,
        gridRow: Int = 0,
        gridHeightRows: Int = 1,
        isPreview: Bool = false
    ) {
        self.store = store
        self.imageStore = imageStore
        self.editorInteractionState = editorInteractionState
        self.placementID = placementID
        self.gridRow = gridRow
        self.gridHeightRows = gridHeightRows
        self.isPreview = isPreview
        _activeTabID = State(
            initialValue: NotesModel.shared.activeTab(for: placementID) ?? store.activeTabID
        )
    }

    var body: some View {
        // 卡片壳统一走 Kit 的 BlockCard：笔记本块与其他抽屉块共享底色与
        // 发丝描边（hoverEffect 默认关，编辑区不做悬停反馈）。
        BlockCard { _ in
            editorContent
        }
        .environment(\.colorScheme, .dark)
        // 新建笔记入口：与 ClipboardHistory / Camera / Scheduler 的块内角标同一套
        // 交互——默认隐藏，指针悬浮本块才浮出，落位与宿主编辑角标同一环
        // （`padding(6)` 的右上角，样式走 Kit `IconCircleButton`）。
        .overlay(alignment: .topTrailing) {
            if isHovering {
                addNoteButton
                    .padding(controlInset)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(NotchTokens.Motion.hover, value: isHovering)
    }

    /// 右上角「+」：Kit `IconCircleButton`（直径 22、自带悬停增亮 / 手型光标 /
    /// help / a11y）。过渡副本护栏：滑动切页的预览副本不得真的新建（同 Camera）。
    private var addNoteButton: some View {
        IconCircleButton(
            systemImage: "plus",
            helpText: L("notes.newNote")
        ) {
            createNote()
        }
        .disabled(isPreview)
    }

    private var editorContent: some View {
        GeometryReader { proxy in
            VStack(spacing: editorSpacing) {
                TabPagerControl(
                    store: store,
                    activeTabID: activeTabID,
                    editorInteractionState: editorInteractionState,
                    onSelectTab: { tabID in
                        activeTabID = tabID
                        editorInteractionState.restoreSelection(
                            store.selectionRange(for: tabID),
                            reveal: false
                        )
                    },
                    availableWidth: max(
                        proxy.size.width - contentHorizontalPadding * 2 - controlSlot,
                        160
                    )
                )
                .frame(height: toolbarHeight, alignment: .topLeading)

                MarkdownEditorPanel(
                    store: store,
                    imageStore: imageStore,
                    editorInteractionState: editorInteractionState,
                    activeTabID: activeTabID,
                    size: editorSize(proxy.size),
                    isPreview: isPreview
                )
            }
            // .padding(.horizontal, contentHorizontalPadding)
            // .padding(.vertical, contentVerticalPadding)
            // 水平与垂直内边距一致（均为 10），保证块内下方空间与侧边空间视觉
            // 一致；视图本身已通过外层 GeometryReader 撑满容器分配的全部宽高。
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { syncPlacementPresence(presented: isDrawerPresented) }
            .onDisappear { syncPlacementPresence(presented: false) }
            .onChange(of: isDrawerPresented) { _, presented in
                syncPlacementPresence(presented: presented)
            }
            .onChange(of: activeTabID) { _, newTabID in
                guard !isPreview else { return }
                NotesModel.shared.rememberActiveTab(newTabID, for: placementID)
                editorInteractionState.restoreSelection(
                    store.selectionRange(for: newTabID),
                    reveal: false
                )
            }
            .onChange(of: store.tabs.map(\.id)) { _, tabIDs in
                // 预览副本不得跟随（`requestFocus` 会抢走在屏实例的第一响应者）。
                guard !isPreview else { return }
                // 其他实例删除标签页时保持本地选择有效。
                if !tabIDs.contains(activeTabID) {
                    activeTabID = store.activeTabID
                    return
                }
                // 外部入口（紧凑图标/状态栏菜单）新建笔记：跟随持久化的
                // 激活标签并聚焦编辑器。本地入口（块内右上角「+」）与本地切换
                // 都在改本地状态前/同步把记忆写成目标值，本分支只会被外部入口
                // 触发，不依赖两个 onChange 的触发顺序。
                if let remembered = NotesModel.shared.activeTab(for: placementID),
                   remembered != activeTabID {
                    activeTabID = remembered
                    editorInteractionState.requestFocus(searchingIn: nil)
                }
            }
        }
    }

    /// 按真实可见性登记/注销"最上方实例"。幂等：收起与卸载会各触发一次卸载分支，
    /// 重新展开则整份登记重放（与无温存时"每次展开重新 onAppear"的语义一致）。
    private func syncPlacementPresence(presented: Bool) {
        guard !isPreview else { return }
        guard presented else {
            editorInteractionState.resetDragState()
            NotesModel.shared.unregisterPlacement(placementID)
            return
        }
        editorInteractionState.onSelectionChange = { [weak store] range in
            guard let store else { return }
            store.updateSelection(for: activeTabID, range: range)
        }
        // 登记网格位置：紧凑图标“新建笔记”据此定位最上方实例。
        NotesModel.shared.registerPlacement(placementID, row: gridRow, heightRows: gridHeightRows)
        editorInteractionState.restoreSelection(store.selectionRange(for: activeTabID))
        NotesModel.shared.rememberActiveTab(activeTabID, for: placementID)
    }

    /// 新增一篇笔记并切到它。块内唯一新建入口 = 右上角悬浮「+」（分页条右侧
    /// 不再常驻按钮），写序与紧凑入口 `createNoteInTopmostPlacement` 一致。
    private func createNote() {
        // 先收尾当前标签的选区：离开前不写回，切回来时选区落在文档开头。
        editorInteractionState.commitSelection(to: store, tabID: activeTabID)
        let newTabID = store.addTab()
        // 必须在任何 onChange 触发前同步写记忆（与紧凑入口
        // createNoteInTopmostPlacement 的写序一致）：标签跟随 onChange 可能先于
        // activeTabID 的 onChange 触发，读到旧记忆会把本实例的选择弹回旧笔记。
        NotesModel.shared.rememberActiveTab(newTabID, for: placementID)
        // 挂起焦点：新标签触发 documentId 变化、编辑器重建，bind 时自动聚焦本
        // 实例的新编辑器。
        editorInteractionState.scheduleDeferredFocus()
        withAnimation(NotchTokens.Motion.tabSwitch) {
            activeTabID = newTabID
            editorInteractionState.restoreSelection(
                store.selectionRange(for: newTabID),
                reveal: false
            )
        }
    }

    private func editorSize(_ total: CGSize) -> CGSize {
        CGSize(
            width: total.width,
            height: max(
                total.height
                    - contentVerticalPadding * 2
                    - toolbarHeight
                    - editorSpacing,
                120
            )
        )
    }
}
