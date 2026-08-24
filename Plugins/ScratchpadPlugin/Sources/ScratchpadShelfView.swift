import AppKit
import NotchCenterKit
import SwiftUI

struct FileShelfView: View {
    @ObservedObject var store: ScratchpadStore
    @ObservedObject var workspaceState: ScratchpadWorkspaceState
    let size: CGSize
    @StateObject private var previewController = FileShelfPreviewController()
    @State private var selection = FileShelfSelection()
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var selectionRect: CGRect?
    @State private var selectionAtDragStart: Set<UUID> = []
    @State private var keyboardFocusGeneration = 0

    private let selectionCoordinateSpace = "file-shelf-selection"

    var body: some View {
        // 卡片壳（含拖入高亮态）统一走 Kit 的 BlockCard；阴影与高亮 spring
        // 动画留在本文件——它们是暂存区拖放交互的一部分。
        BlockCard(highlighted: workspaceState.isShelfDropTargeted) { _ in
            content
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: selectionCoordinateSpace)
        .shadow(
                color: .black.opacity(workspaceState.isShelfDropTargeted ? 0.24 : 0),
                radius: 18,
                y: 8
            )
            .animation(.spring(response: 0.30, dampingFraction: 0.84), value: workspaceState.isShelfDropTargeted)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.items)
            .onPreferenceChange(FileShelfItemFramePreferenceKey.self) { frames in
                Task { @MainActor in
                    itemFrames = frames
                }
            }
            .onChange(of: store.items.map(\.id)) { _, itemIDs in
                selection.retainValidIDs(itemIDs)
            }
            .onChange(of: workspaceState.isDraggingShelfItem) { _, isDragging in
                if isDragging {
                    cancelMarqueeSelection()
                }
            }
            .onChange(of: workspaceState.isShelfDropTargeted) { _, isTargeted in
                if isTargeted {
                    cancelMarqueeSelection()
                }
            }
            .onDisappear {
                cancelMarqueeSelection()
                previewController.close()
            }
            .contextMenu {
                removeAllMenuButton
            }
            .dropDestination(for: URL.self) { urls, _ in
                let didAccept = store.acceptDrop(urls)
                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                    workspaceState.isShelfDropTargeted = false
                }
                return didAccept
            } isTargeted: { isTargeted in
                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                    workspaceState.isShelfDropTargeted = isTargeted
                        && !workspaceState.isDraggingShelfItem
                }
            }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            keyboardFocusLayer
            shelfItemsLayer
            marqueeEdgeZones
                .allowsHitTesting(!workspaceState.isShelfDropTargeted)
            dropPromptLayer
            selectionRectLayer
        }
    }

    private var keyboardFocusLayer: some View {
        FileShelfKeyboardFocusView(
            focusGeneration: keyboardFocusGeneration,
            onSelectAll: selectAllItems,
            onPreview: { previewSelection() },
            onDelete: removeSelectedItems
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var shelfItemsLayer: some View {
        if !store.items.isEmpty {
            shelfItems
                .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private var dropPromptLayer: some View {
        if workspaceState.isShelfDropTargeted, store.items.isEmpty {
            dropPrompt
                .frame(
                    width: size.width,
                    height: size.height,
                    alignment: Alignment.center
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if store.items.isEmpty, !workspaceState.isShelfDropTargeted {
            // 空状态：显示暂存图标占位（设计规范 §9.6 FileShelfView）
            emptyPlaceholder
                .frame(
                    width: size.width,
                    height: size.height,
                    alignment: Alignment.center
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    @ViewBuilder
    private var selectionRectLayer: some View {
        if let selectionRect,
           selectionRect.width >= 3,
           selectionRect.height >= 3 {
            Rectangle()
                .fill(Color.white.opacity(0.055))
                .overlay {
                    Rectangle()
                        .stroke(Color.white.opacity(0.34), lineWidth: 1)
                }
                .frame(width: selectionRect.width, height: selectionRect.height)
                .offset(x: selectionRect.minX, y: selectionRect.minY)
                .allowsHitTesting(false)
        }
    }

    private var removeAllMenuButton: some View {
        Button(role: .destructive) {
            // Keep Quick Look consistent with removeSelectedItems(): the
            // panel must not keep showing files no longer on the shelf.
            previewController.close()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                store.removeAll()
            }
        } label: {
            Label(L("menu.removeAll.shelfItems"), systemImage: "xmark.circle")
        }
        .disabled(store.items.isEmpty)
    }

    private var dropPrompt: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 9, weight: .semibold))

            Text(L("drop.releaseToAdd"))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.white.opacity(0.58))
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))

            Text(L("shelf.empty.title"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        // .padding(16)
        // .background(
        //     RoundedRectangle(cornerRadius: 10, style: .continuous)
        //         .fill(.white.opacity(0.02))
        // )
        // .overlay {
        //     RoundedRectangle(cornerRadius: 10, style: .continuous)
        //         .stroke(.white.opacity(0.06), lineWidth: 1)
        // }
    }

    private var shelfItems: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        marqueeGap
                    }

                    FileShelfChip(
                        item: item,
                        store: store,
                        workspaceState: workspaceState,
                        isSelected: selection.selectedIDs.contains(item.id),
                        onSelect: { modifiers in
                            selectForMouseDown(item.id, modifiers: modifiers)
                        },
                        onSelectExclusive: {
                            selection.selectExclusively(item.id)
                        },
                        dragURLs: {
                            selectedURLs(startingAt: item.id)
                        },
                        onSelectAll: selectAllItems,
                        onPreview: {
                            previewSelection(preferredID: item.id)
                        },
                        onDeleteSelected: removeSelectedItems
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: FileShelfItemFramePreferenceKey.self,
                                value: [
                                    item.id: proxy.frame(
                                        in: .named(selectionCoordinateSpace)
                                    )
                                ]
                            )
                        }
                    }
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92))
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var marqueeGap: some View {
        Color.clear
            .frame(width: 5)
            .contentShape(Rectangle())
            .gesture(selectionGesture)
    }

    private var marqueeEdgeZones: some View {
        ZStack {
            VStack(spacing: 0) {
                marqueeStartSurface.frame(height: 6)
                Spacer(minLength: 0)
                marqueeStartSurface.frame(height: 6)
            }

            HStack(spacing: 0) {
                marqueeStartSurface.frame(width: 6)
                Spacer(minLength: 0)
                marqueeStartSurface.frame(width: 6)
            }
        }
    }

    private var marqueeStartSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(selectionGesture)
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(selectionCoordinateSpace))
            .onChanged { value in
                guard !workspaceState.isShelfDropTargeted else { return }

                if selectionRect == nil {
                    selectionAtDragStart = selection.selectedIDs
                    keyboardFocusGeneration += 1
                }

                let rect = CGRect(
                    x: value.startLocation.x,
                    y: value.startLocation.y,
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                ).standardized
                let enclosedIDs = Set(
                    itemFrames.compactMap { id, frame in
                        frame.intersects(rect) ? id : nil
                    }
                )
                selection.applyMarquee(
                    enclosedIDs: enclosedIDs,
                    initialSelection: selectionAtDragStart,
                    modifiers: NSEvent.modifierFlags
                )
                selectionRect = rect
            }
            .onEnded { _ in
                selectionRect = nil
                selectionAtDragStart = []
            }
    }

    private func selectForMouseDown(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        cancelMarqueeSelection()
        selection.selectForMouseDown(
            id,
            orderedIDs: store.items.map(\.id),
            modifiers: modifiers
        )
    }

    private func selectAllItems() {
        selection.selectAll(store.items.map(\.id))
    }

    private func removeSelectedItems() {
        guard !selection.isEmpty else { return }
        store.remove(ids: selection.selectedIDs)
        selection.clear()
        previewController.close()
    }

    private func selectedURLs(startingAt id: UUID? = nil) -> [URL] {
        let selectedIDs = selection.orderedSelection(
            from: store.items.map(\.id),
            startingAt: id
        )
        let itemByID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })

        return selectedIDs.compactMap { id in
            guard let item = itemByID[id], store.isAvailable(item) else { return nil }
            return store.resolvedURL(for: item)
        }
    }

    private func previewSelection(preferredID: UUID? = nil) {
        let urls = selectedURLs(startingAt: preferredID)
        guard !urls.isEmpty else { return }

        let preferredURL = preferredID.flatMap { id in
            store.items.first(where: { $0.id == id }).flatMap(store.resolvedURL)
        }
        previewController.toggle(urls: urls, preferredURL: preferredURL) { isVisible in
            workspaceState.isPreviewingShelfItem = isVisible
        }
    }

    private func cancelMarqueeSelection() {
        selectionRect = nil
        selectionAtDragStart = []
    }
}

private struct FileShelfItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}
