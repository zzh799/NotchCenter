import AppKit
import SwiftUI

struct FileDragSourceView: NSViewRepresentable {
    let url: URL
    let displayName: String
    let dragURLs: () -> [URL]
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let onHoverChange: (Bool) -> Void
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onSelectExclusive: () -> Void
    let onSelectAll: () -> Void
    let onPreview: () -> Void
    let onDeleteSelected: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    func makeNSView(context: Context) -> FileDragSourceNSView {
        FileDragSourceNSView()
    }

    func updateNSView(_ nsView: FileDragSourceNSView, context: Context) {
        nsView.url = url
        nsView.displayName = displayName
        nsView.dragURLs = dragURLs
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.onHoverChange = onHoverChange
        nsView.onSelect = onSelect
        nsView.onSelectExclusive = onSelectExclusive
        nsView.onSelectAll = onSelectAll
        nsView.onPreview = onPreview
        nsView.onDeleteSelected = onDeleteSelected
        nsView.onOpen = onOpen
        nsView.onReveal = onReveal
        nsView.onRemove = onRemove
    }
}

@MainActor
final class FileDragSourceNSView: NSView, NSDraggingSource {
    var url: URL?
    var displayName = ""
    var dragURLs: (() -> [URL])?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onSelectExclusive: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onPreview: (() -> Void)?
    var onDeleteSelected: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?

    private var didStartDrag = false
    private var mouseDownLocation: NSPoint?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let removeButtonArea = NSRect(
            x: bounds.maxX - 20,
            y: bounds.maxY - 20,
            width: 20,
            height: 20
        )
        return removeButtonArea.contains(point) ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        onSelect?(event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        switch ShelfKeyAction(from: event) {
        case .selectAll: onSelectAll?()
        case .preview: onPreview?()
        case .delete: onDeleteSelected?()
        case nil: super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !didStartDrag,
              let mouseDownLocation,
              FileDragGesturePolicy.shouldBegin(from: mouseDownLocation, to: location),
              let url else {
            return
        }
        let urls = dragURLs?() ?? [url]
        guard !urls.isEmpty else { return }
        didStartDrag = true
        onHoverChange?(false)
        onDragBegan?()

        let draggingItems = urls.enumerated().map { index, draggedURL in
            let icon = NSWorkspace.shared.icon(forFile: draggedURL.path)
            icon.size = NSSize(width: 44, height: 44)
            let offset = CGFloat(min(index, 3)) * 3
            let draggingItem = NSDraggingItem(
                pasteboardWriter: FileDragPasteboard.writer(for: draggedURL)
            )
            draggingItem.setDraggingFrame(
                NSRect(
                    x: location.x - 22 + offset,
                    y: location.y - 22 - offset,
                    width: 44,
                    height: 44
                ),
                contents: icon
            )
            return draggingItem
        }

        let session = beginDraggingSession(
            with: draggingItems,
            event: event,
            source: self
        )
        if draggingItems.count > 1 {
            session.draggingFormation = .stack
        }
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !didStartDrag else { return }
        if event.modifierFlags.intersection([.command, .shift]).isEmpty {
            onSelectExclusive?()
        }
        if event.clickCount == 2 {
            onOpen?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        menu.addItem(menuItem(title: L("menu.open"), action: #selector(openItem)))
        menu.addItem(menuItem(title: L("menu.showInFinder"), action: #selector(revealItem)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: L("menu.removeFromShelf"), action: #selector(removeItem)))
        return menu
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        FileDragOperationPolicy.allowedOperations
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?()
        onHoverChange?(false)
        didStartDrag = false
        mouseDownLocation = nil
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openItem() {
        onOpen?()
    }

    @objc private func revealItem() {
        onReveal?()
    }

    @objc private func removeItem() {
        onRemove?()
    }
}
