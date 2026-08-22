import AppKit
import SwiftUI

struct FileShelfKeyboardFocusView: NSViewRepresentable {
    let focusGeneration: Int
    let onSelectAll: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> FileShelfKeyboardNSView {
        FileShelfKeyboardNSView()
    }

    func updateNSView(_ nsView: FileShelfKeyboardNSView, context: Context) {
        nsView.onSelectAll = onSelectAll
        nsView.onPreview = onPreview
        nsView.onDelete = onDelete

        guard nsView.focusGeneration != focusGeneration else { return }
        nsView.focusGeneration = focusGeneration
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

@MainActor
final class FileShelfKeyboardNSView: NSView {
    var focusGeneration = 0
    var onSelectAll: (() -> Void)?
    var onPreview: (() -> Void)?
    var onDelete: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        switch ShelfKeyAction(from: event) {
        case .selectAll: onSelectAll?()
        case .preview: onPreview?()
        case .delete: onDelete?()
        case nil: super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }
}

/// Shared key dispatch for shelf views: Cmd+A select-all, Space preview,
/// Delete/Forward-Delete remove. Both keyboard surfaces must stay in sync.
enum ShelfKeyAction {
    case selectAll
    case preview
    case delete

    init?(from event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            self = .selectAll
        } else if event.keyCode == 49 {
            self = .preview
        } else if event.keyCode == 51 || event.keyCode == 117 {
            self = .delete
        } else {
            return nil
        }
    }
}
