import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - 编辑器面板

struct MarkdownEditorPanel: View {
    @ObservedObject var store: NotesStore
    let imageStore: NotesImageStore
    let editorInteractionState: EditorInteractionState
    let activeTabID: UUID
    let size: CGSize

    private let toolbarHeight: CGFloat = 38
    private let separatorHeight: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            MarkdownNoteEditor(
                store: store,
                imageStore: imageStore,
                editorInteractionState: editorInteractionState,
                activeTabID: activeTabID
            )
            .frame(width: size.width, height: editorHeight)

            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(width: size.width, height: separatorHeight)

            MarkdownShortcutToolbar(editorInteractionState: editorInteractionState)
                .frame(width: size.width, height: toolbarHeight)
                .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        }
    }

    private var editorHeight: CGFloat {
        max(size.height - toolbarHeight - separatorHeight, 120)
    }
}

struct MarkdownShortcutToolbar: View {
    let editorInteractionState: EditorInteractionState

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(MarkdownCommand.allCases) { command in
                Button {
                    editorInteractionState.applyMarkdownCommand(command)
                } label: {
                    MarkdownCommandLabel(command: command)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MarkdownToolbarButtonStyle())
                .help(command.help)
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 10)
    }
}

struct MarkdownCommandLabel: View {
    let command: MarkdownCommand

    var body: some View {
        switch command {
        case .bold:
            Image(systemName: "bold")
        case .italic:
            Image(systemName: "italic")
        case .strikethrough:
            Image(systemName: "strikethrough")
        case .inlineCode:
            Text("`")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        case .link:
            Image(systemName: "link")
        case .quote:
            Image(systemName: "quote.opening")
        case .unorderedList:
            Image(systemName: "list.bullet")
        case .orderedList:
            Image(systemName: "list.number")
        case .todoList:
            Image(systemName: "checklist")
        }
    }
}

// MARK: - Markdown 编辑器（TextKit 2，vendored MarkdownEngine）

struct MarkdownNoteEditor: View {
    @ObservedObject var store: NotesStore
    let imageStore: NotesImageStore
    let editorInteractionState: EditorInteractionState
    let activeTabID: UUID
    @State private var isWikiLinkActive = false
    @State private var pendingInlineReplacement: InlineReplacementRequest?

    var body: some View {
        ZStack(alignment: .topLeading) {
            NativeTextViewWrapper(
                text: Binding(
                    get: { store.text(for: activeTabID) },
                    set: { store.updateText($0, for: activeTabID) }
                ),
                isWikiLinkActive: $isWikiLinkActive,
                pendingInlineReplacement: $pendingInlineReplacement,
                configuration: configuration,
                fontName: "SF Pro",
                fontSize: 15,
                documentId: activeTabID.uuidString,
                isEditable: true,
                onPasteImage: savePastedImage
            )
            .background {
                EditorFocusBinder(state: editorInteractionState)
            }

            if store.text(for: activeTabID).isEmpty {
                Text("Start typing…")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.24))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private func savePastedImage(_ pasteboard: NSPasteboard) -> String? {
        imageStore.saveImage(from: pasteboard)
    }

    private var configuration: MarkdownEditorConfiguration {
        let theme = MarkdownEditorTheme(
            bodyText: NSColor(white: 0.92, alpha: 1),
            mutedText: NSColor(white: 0.58, alpha: 1),
            disabledText: NSColor(white: 0.38, alpha: 1),
            headingMarker: NSColor(white: 0.44, alpha: 1),
            link: NSColor.systemBlue,
            incompleteLink: NSColor.systemBlue.withAlphaComponent(0.75),
            findMatchHighlight: NSColor.systemYellow.withAlphaComponent(0.55),
            findCurrentMatchHighlight: NSColor.systemYellow,
            latexLightModeText: .white,
            latexDarkModeText: .white,
            strikethroughColor: NSColor(white: 0.62, alpha: 1)
        )

        let services = MarkdownEditorServices(images: imageStore)

        return MarkdownEditorConfiguration(
            theme: theme,
            services: services,
            lists: ListStyle(indentPerLevel: 18, extraLineHeight: 1),
            imageEmbed: ImageEmbedStyle(fallbackMaxWidth: 440, paragraphSpacing: 6, imageGap: 6),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0),
            dragSelection: DragSelectionPolicy(movementThreshold: 8, edgeTriggerDistance: 8, scrollStepPerTick: 4, ticksPerSecond: 30),
            scrollers: .vertical,
            textInsets: TextInsets(horizontal: 12, vertical: 12)
        )
    }
}
