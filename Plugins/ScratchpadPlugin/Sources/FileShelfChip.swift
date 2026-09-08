import AppKit
import NotchCenterKit
import SwiftUI
import UniformTypeIdentifiers

struct FileShelfChip: View {
    let item: FileShelfItem
    @ObservedObject var store: ScratchpadStore
    @ObservedObject var workspaceState: ScratchpadWorkspaceState
    let isSelected: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onSelectExclusive: () -> Void
    let dragURLs: () -> [URL]
    let onSelectAll: () -> Void
    let onPreview: () -> Void
    let onDeleteSelected: () -> Void
    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        draggableChip
            .task(id: item.fallbackPath) {
                await store.refreshAvailability(item)
            }
            .task(id: thumbnailTaskID) {
                thumbnail = nil
                guard let url, isAvailable, isImage else { return }
                let loadedData = await FileShelfThumbnailLoader.thumbnail(
                    for: url,
                    backingScale: NSScreen.main?.backingScaleFactor ?? 2
                )
                guard !Task.isCancelled else { return }
                thumbnail = loadedData
            }
    }

    @ViewBuilder
    private var draggableChip: some View {
        if let url, isAvailable {
            chip
                .overlay {
                    FileDragSourceView(
                        url: url,
                        displayName: displayName,
                        dragURLs: dragURLs,
                        onDragBegan: {
                            workspaceState.isDraggingShelfItem = true
                            workspaceState.isShelfDropTargeted = false
                        },
                        onDragEnded: {
                            workspaceState.isDraggingShelfItem = false
                            workspaceState.isShelfDropTargeted = false
                        },
                        onHoverChange: { isHovering = $0 },
                        onSelect: onSelect,
                        onSelectExclusive: onSelectExclusive,
                        onSelectAll: onSelectAll,
                        onPreview: onPreview,
                        onDeleteSelected: onDeleteSelected,
                        onOpen: open,
                        onReveal: revealInFinder,
                        onRemove: removeFromShelf
                    )
                }
        } else {
            chip.onHover { isHovering = $0 }
        }
    }

    private var chip: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    fileIdentityImage

                    if !isAvailable {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(NotchTokens.Text.system(9))
                            .foregroundStyle(NotchTokens.Semantic.unavailable)
                            .background(Circle().fill(Color.black))
                    }
                }

                Text(displayName)
                    .font(NotchTokens.Text.caption)
                    .foregroundStyle(
                        isAvailable
                            ? (isSelected ? NotchTokens.Foreground.body : NotchTokens.Foreground.muted)
                            : NotchTokens.Foreground.unavailable
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 52)
            }
            .frame(width: NotchTokens.Space.chipSize.width, height: NotchTokens.Space.chipSize.height)

            Button {
                removeFromShelf()
            } label: {
                Image(systemName: "xmark")
                    .font(NotchTokens.Text.system(7, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(ShelfRemoveButtonStyle())
            .help(L("chip.help.remove"))
            .offset(x: 1, y: -1)
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(isHovering ? 1 : 0.86)
            .allowsHitTesting(isHovering)
        }
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(
                    .white.opacity(
                        isSelected ? 0.12 : (isHovering ? 0.065 : 0)
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .stroke(.white.opacity(isSelected ? 0.20 : 0), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous))
        .animation(NotchTokens.Motion.hover, value: isHovering)
        .animation(NotchTokens.Motion.hover, value: isSelected)
        .help(
            isAvailable
                ? LF("chip.help.available", displayName, fileKind)
                : LF("chip.help.unavailable", displayName)
        )
        .accessibilityLabel(displayName)
    }

    private var url: URL? {
        store.resolvedURL(for: item)
    }

    private var isAvailable: Bool {
        store.isAvailable(item)
    }

    private var displayName: String {
        guard let url, isAvailable else { return item.originalName }
        return url.lastPathComponent
    }

    private var fileKind: String {
        if item.isDirectory == true {
            return L("fileKind.folder")
        }
        return effectiveFileExtension?.uppercased() ?? L("fileKind.file")
    }

    @ViewBuilder
    private var fileIdentityImage: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: NotchTokens.Space.thumbnailSize.width, height: NotchTokens.Space.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                        .stroke(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
                }
        } else {
            Image(nsImage: fileIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .opacity(isAvailable ? 1 : 0.34)
        }
    }

    private var isImage: Bool {
        guard item.isDirectory != true,
              let fileExtension = effectiveFileExtension,
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private var effectiveFileExtension: String? {
        if let fileExtension = item.fileExtension, !fileExtension.isEmpty {
            return fileExtension
        }
        guard let pathExtension = url?.pathExtension, !pathExtension.isEmpty else { return nil }
        return pathExtension
    }

    private var thumbnailTaskID: String {
        "\(item.fallbackPath)|\(isAvailable)|\(isImage)"
    }

    private var fileIcon: NSImage {
        let contentType: UTType
        if item.isDirectory == true {
            contentType = .folder
        } else if let fileExtension = effectiveFileExtension,
                  let resolvedType = UTType(filenameExtension: fileExtension) {
            contentType = resolvedType
        } else {
            contentType = .data
        }

        let icon = NSWorkspace.shared.icon(for: contentType)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }

    private func open() {
        guard let url, isAvailable else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url, isAvailable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func removeFromShelf() {
        withAnimation(NotchTokens.Motion.removal) {
            store.remove(item)
        }
    }
}

struct ShelfRemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.58 : 0.82))
            .background(
                Circle()
                    .fill(.black.opacity(configuration.isPressed ? 0.72 : 0.58))
            )
            .contentShape(Circle())
    }
}
