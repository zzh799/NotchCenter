import SwiftUI

@MainActor
final class DrawerState: ObservableObject {
    @Published var isExpanded = false
    @Published var revealProgress: CGFloat = 0
}

struct NotebookView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var settingsStore: AppSettingsStore
    let imageStore: LocalImageStore
    @ObservedObject var fileShelfStore: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    @ObservedObject var drawerState: DrawerState
    @ObservedObject var editorInteractionState: EditorInteractionState
    let layout: NotchLayout

    var body: some View {
        drawer
            .dropDestination(for: URL.self) { urls, _ in
                guard !workspaceState.isDraggingShelfItem else {
                    workspaceState.isShelfDropTargeted = false
                    return false
                }
                return receiveDroppedFiles(urls)
            } isTargeted: { isTargeted in
                withAnimation(shelfAnimation) {
                    workspaceState.isShelfDropTargeted = isTargeted
                        && !workspaceState.isDraggingShelfItem
                }
            }
            .environment(\.colorScheme, .dark)
    }

    private var drawer: some View {
        expandedContent
            .frame(width: layout.expandedSize.width, height: layout.expandedSize.height)
            // revealProgress 在 0.42→0.76 区间线性映射为内容不透明度：展开前段只
            // 露背景，避免内容随 mask 边缘变形出现半透明残影。
            .opacity(expandedContentOpacity)
            .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
            .mask(alignment: .top) {
                TopAttachedRoundedShape(radius: cornerRadius)
                    .frame(width: revealWidth, height: revealHeight)
            }
            .overlay(alignment: .top) {
                TopAttachedRoundedShape(radius: cornerRadius)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
                    .frame(width: revealWidth, height: revealHeight)
            }
            .contentShape(Rectangle())
            .allowsHitTesting(drawerState.isExpanded)
    }

    private var expandedContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: editorSpacing) {
                TabPagerControl(
                    store: store,
                    editorInteractionState: editorInteractionState,
                    availableWidth: tabControlWidth
                )
                .frame(
                    width: tabControlWidth,
                    height: tabControlHeight,
                    alignment: .topLeading
                )
                .frame(height: toolbarHeight, alignment: .top)

                VStack(spacing: shelfSpacing) {
                    MarkdownEditorPanel(
                        store: store,
                        settingsStore: settingsStore,
                        imageStore: imageStore,
                        editorInteractionState: editorInteractionState,
                        size: noteEditorSize
                    )
                    // The panel already fixes every child to `size`; an outer
                    // .frame would just restate it.
                    .background(Color(red: 0.06, green: 0.06, blue: 0.07))

                    if isFileShelfVisible {
                        FileShelfView(
                            store: fileShelfStore,
                            workspaceState: workspaceState,
                            size: fileShelfSize
                        )
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.97, anchor: .bottom))
                        )
                    }
                }
                .animation(shelfAnimation, value: isFileShelfVisible)
            }
        }
        .padding(.top, toolbarTopPadding)
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.bottom, contentBottomPadding)
        .onAppear {
            editorInteractionState.onSelectionChange = { [weak store] range in
                guard let store else { return }
                store.updateSelection(for: store.activeTabID, range: range)
            }
            editorInteractionState.restoreSelection(store.selectionRange(for: store.activeTabID))
        }
        .onChange(of: store.activeTabID) { _, newTabID in
            editorInteractionState.restoreSelection(
                store.selectionRange(for: newTabID),
                reveal: false
            )
        }
        .onDisappear {
            workspaceState.isShelfDropTargeted = false
            workspaceState.isDraggingShelfItem = false
        }
    }

    private var revealWidth: CGFloat {
        interpolate(from: layout.compactSize.width, to: layout.expandedSize.width)
    }

    private var revealHeight: CGFloat {
        interpolate(from: layout.compactSize.height, to: layout.expandedSize.height)
    }

    private var cornerRadius: CGFloat {
        // Compact state must match the physical notch corner (~12pt); expanded
        // grows to a softer panel radius (18pt) as the drawer reveals.
        interpolate(from: 12, to: 18)
    }

    private var expandedContentOpacity: CGFloat {
        let progress = drawerState.revealProgress
        return min(max((progress - 0.42) / 0.34, 0), 1)
    }

    private var noteEditorSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            // 180pt floor keeps a usable typing surface on short displays;
            // NotchGeometry guarantees expandedHeight >= 408 so the fixed
            // chrome above/below never exceeds the available space.
            height: max(
                layout.expandedSize.height
                    - toolbarTopPadding
                    - contentBottomPadding
                    - toolbarHeight
                    - editorSpacing
                    - (isFileShelfVisible ? fileShelfHeight + shelfSpacing : 0),
                180
            )
        )
    }

    private var fileShelfSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            height: fileShelfHeight
        )
    }

    private var toolbarTopPadding: CGFloat {
        layout.compactSize.height + 2
    }

    private var contentHorizontalPadding: CGFloat {
        18
    }

    private var contentBottomPadding: CGFloat {
        12
    }

    private var tabControlWidth: CGFloat {
        max(layout.expandedSize.width - contentHorizontalPadding * 2, 220)
    }

    private var tabControlHeight: CGFloat {
        CGFloat(tabRowCount) * TabDotMetrics.itemHeight
            + CGFloat(max(tabRowCount - 1, 0)) * TabDotMetrics.verticalSpacing
            + TabDotMetrics.verticalPadding
    }

    private var toolbarHeight: CGFloat {
        max(tabControlHeight, 28)
    }

    private var tabRowCount: Int {
        let availableWidth = max(
            tabControlWidth - TabDotMetrics.plusButtonReservedWidth,
            TabDotMetrics.minWrapWidth
        )
        var rows = 1
        var currentRowWidth: CGFloat = 0

        for _ in store.tabs {
            let proposedWidth = currentRowWidth == 0
                ? TabDotMetrics.itemWidth
                : currentRowWidth + TabDotMetrics.horizontalSpacing + TabDotMetrics.itemWidth
            if currentRowWidth > 0, proposedWidth > availableWidth {
                rows += 1
                currentRowWidth = TabDotMetrics.itemWidth
            } else {
                currentRowWidth = proposedWidth
            }
        }

        return rows
    }

    private var editorSpacing: CGFloat {
        8
    }

    private var fileShelfHeight: CGFloat {
        72
    }

    private var shelfSpacing: CGFloat {
        8
    }

    private var isFileShelfVisible: Bool {
        workspaceState.isShelfDropTargeted || !fileShelfStore.items.isEmpty
    }

    private var shelfAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.84)
    }

    private func interpolate(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * drawerState.revealProgress
    }

    private func receiveDroppedFiles(_ urls: [URL]) -> Bool {
        let didAcceptDrop = fileShelfStore.acceptDrop(urls)
        workspaceState.isShelfDropTargeted = false
        return didAcceptDrop
    }
}

/// Rounded rect whose corners attach to the top edge, matching how the notch
/// panel hangs below the menu bar.
struct TopAttachedRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}
