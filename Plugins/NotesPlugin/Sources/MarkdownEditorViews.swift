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
    /// 只读预览副本（宿主的滑动切页过渡）：不得认领编辑器交互状态。
    var isPreview: Bool = false

    private let toolbarHeight: CGFloat = 38
    private let separatorHeight: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            MarkdownNoteEditor(
                store: store,
                imageStore: imageStore,
                editorInteractionState: editorInteractionState,
                activeTabID: activeTabID,
                isPreview: isPreview
            )
            .frame(maxWidth: .infinity, minHeight: editorHeight, maxHeight: .infinity)

            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(width: size.width, height: separatorHeight)

            MarkdownShortcutToolbar(editorInteractionState: editorInteractionState)
                .frame(width: size.width, height: toolbarHeight)
                .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        }
        .frame(maxWidth: .infinity)
    }

    private var editorHeight: CGFloat {
        max(size.height - toolbarHeight - separatorHeight, 120)
    }
}

struct MarkdownShortcutToolbar: View {
    let editorInteractionState: EditorInteractionState

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
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
        .padding(.horizontal, 12)
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
    var isPreview: Bool = false
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
                onPasteImage: savePastedImage,
                onBuildContextMenu: buildContextMenu
            )
            .background {
                EditorFocusBinder(state: editorInteractionState, isPreview: isPreview)
            }

            if store.text(for: activeTabID).isEmpty {
                Text(L("notes.placeholder.startTyping"))
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

    /// 右键菜单：Format / Heading / Lists（MarkdownEngine 0.12.0 起引擎不再内置
    /// 菜单，构建责任移交 embedder；动作复用工具栏同一套 EditorInteractionState）。
    private func buildContextMenu(_ menu: NSMenu, selection: NSRange) -> NSMenu {
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            return item
        }
        func actionItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire), keyEquivalent: "")
            let target = MenuActionTarget { [weak editorInteractionState] in
                guard let editorInteractionState else { return }
                run()
            }
            item.target = target
            // NSMenuItem 对 target 的持有不保证强引用，挂一份在 representedObject 保命。
            item.representedObject = target
            return item
        }

        menu.addItem(submenu("Format", [
            actionItem("Bold") { editorInteractionState.applyMarkdownCommand(.bold) },
            actionItem("Italic") { editorInteractionState.applyMarkdownCommand(.italic) },
        ]))
        menu.addItem(submenu("Heading", (1...3).map { level in
            actionItem("H\(level)") { editorInteractionState.applyHeading(level) }
        }))
        menu.addItem(submenu("Lists", [
            actionItem("Bullet") { editorInteractionState.applyMarkdownCommand(.unorderedList) },
            actionItem("Numbered") { editorInteractionState.applyMarkdownCommand(.orderedList) },
        ]))
        return menu
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

/// 右键菜单项的动作桥接：NSMenuItem 需要 @objc target，闭包挂在这个壳上。
/// 引用由 item.representedObject 强持有（见 buildContextMenu）。
final class MenuActionTarget: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire() {
        run()
    }
}
