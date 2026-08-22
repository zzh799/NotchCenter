import AppKit
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

    @State private var activeTabID: UUID

    private let contentHorizontalPadding: CGFloat = 14
    private let contentVerticalPadding: CGFloat = 12
    private let toolbarHeight: CGFloat = 34
    private let editorSpacing: CGFloat = 8

    init(
        store: NotesStore,
        imageStore: NotesImageStore,
        editorInteractionState: EditorInteractionState,
        placementID: String
    ) {
        self.store = store
        self.imageStore = imageStore
        self.editorInteractionState = editorInteractionState
        self.placementID = placementID
        _activeTabID = State(
            initialValue: NotesModel.shared.activeTab(for: placementID) ?? store.activeTabID
        )
    }

    var body: some View {
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
                    availableWidth: proxy.size.width - contentHorizontalPadding * 2
                )
                .frame(height: toolbarHeight, alignment: .topLeading)

                MarkdownEditorPanel(
                    store: store,
                    imageStore: imageStore,
                    editorInteractionState: editorInteractionState,
                    activeTabID: activeTabID,
                    size: editorSize(proxy.size)
                )
            }
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.vertical, contentVerticalPadding)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                editorInteractionState.onSelectionChange = { [weak store] range in
                    guard let store else { return }
                    store.updateSelection(for: activeTabID, range: range)
                }
                editorInteractionState.restoreSelection(store.selectionRange(for: activeTabID))
                NotesModel.shared.rememberActiveTab(activeTabID, for: placementID)
            }
            .onChange(of: activeTabID) { _, newTabID in
                NotesModel.shared.rememberActiveTab(newTabID, for: placementID)
                editorInteractionState.restoreSelection(
                    store.selectionRange(for: newTabID),
                    reveal: false
                )
            }
            .onChange(of: store.tabs.map(\.id)) { _, tabIDs in
                // 其他实例新增/删除标签页时保持本地选择有效。
                guard !tabIDs.contains(activeTabID) else { return }
                activeTabID = store.activeTabID
            }
            .onDisappear {
                editorInteractionState.resetDragState()
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func editorSize(_ total: CGSize) -> CGSize {
        CGSize(
            width: total.width - contentHorizontalPadding * 2,
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
