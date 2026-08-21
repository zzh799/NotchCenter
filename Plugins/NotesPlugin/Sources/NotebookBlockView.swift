import AppKit
import MarkdownEngine
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

struct TabPagerControl: View {
    @ObservedObject var store: NotesStore
    let activeTabID: UUID
    let editorInteractionState: EditorInteractionState
    let onSelectTab: (UUID) -> Void
    let availableWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            WrappingHStack(
                availableWidth: max(availableWidth - 34, 160),
                horizontalSpacing: 6,
                verticalSpacing: 4
            ) {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == activeTabID
                    Button {
                        rememberCurrentSelection()
                        withAnimation(tabSwitchAnimation) {
                            onSelectTab(tab.id)
                        }
                    } label: {
                        ZStack {
                            if isSelected {
                                Circle()
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 14, height: 14)
                            }

                            Circle()
                                .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.34))
                                .frame(width: isSelected ? 7 : 6, height: isSelected ? 7 : 6)
                                .shadow(color: .white.opacity(isSelected ? 0.42 : 0), radius: 3)
                        }
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                        .animation(tabSwitchAnimation, value: isSelected)
                    }
                    .buttonStyle(TabDotButtonStyle(isSelected: isSelected))
                    .help(store.title(for: tab.id))
                    .accessibilityLabel(
                        isSelected
                            ? "Current note: \(store.title(for: tab.id))"
                            : "Open note: \(store.title(for: tab.id))"
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            rememberCurrentSelection()
                            withAnimation(tabSwitchAnimation) {
                                store.removeTab(tab.id)
                            }
                        } label: {
                            Label("Delete This Note", systemImage: "trash")
                        }
                        .disabled(store.tabs.count <= 1)
                    }
                }
            }

            Button {
                rememberCurrentSelection()
                let newTabID = store.addTab()
                withAnimation(tabSwitchAnimation) {
                    onSelectTab(newTabID)
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabIconButtonStyle())
            .fixedSize()
            .help("New note")
            .accessibilityLabel("New note")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var tabSwitchAnimation: Animation {
        .spring(response: 0.26, dampingFraction: 0.82)
    }

    private func rememberCurrentSelection() {
        guard let range = editorInteractionState.currentSelectionRange() else { return }
        store.updateSelection(for: activeTabID, range: range)
    }
}

private struct WrappingHStack: Layout {
    let availableWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = layoutSubviews(in: availableWidth, subviews: subviews)
        return CGSize(width: availableWidth, height: result.size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layoutSubviews(in: min(bounds.width, availableWidth), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func layoutSubviews(
        in availableWidth: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            origins.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }

        return (
            CGSize(width: contentWidth, height: y + rowHeight),
            origins
        )
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

// MARK: - 按钮样式与光标

struct DarkIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 13, weight: .semibold),
            normalOpacity: 0.055,
            hoverOpacity: 0.085,
            pressedOpacity: 0.12,
            strokeOpacity: 0.06,
            foregroundOpacity: 0.76,
            pressedForegroundOpacity: 0.55
        )
    }
}

struct TabIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .bold),
            normalOpacity: 0,
            hoverOpacity: 0.065,
            pressedOpacity: 0.10,
            strokeOpacity: 0,
            foregroundOpacity: 0.72,
            pressedForegroundOpacity: 0.48
        )
    }
}

struct TabDotButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .semibold),
            normalOpacity: 0,
            hoverOpacity: isSelected ? 0.075 : 0.055,
            pressedOpacity: isSelected ? 0.10 : 0.08,
            strokeOpacity: 0,
            foregroundOpacity: 0.72,
            pressedForegroundOpacity: 0.58
        )
    }
}

struct MarkdownToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .semibold),
            normalOpacity: 0,
            hoverOpacity: 0.065,
            pressedOpacity: 0.10,
            strokeOpacity: 0,
            foregroundOpacity: 0.66,
            hoverForegroundOpacity: 0.84,
            pressedForegroundOpacity: 0.54
        )
    }
}

private struct RoundedHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let font: Font?
    let normalOpacity: CGFloat
    let hoverOpacity: CGFloat
    let pressedOpacity: CGFloat
    let strokeOpacity: CGFloat
    let foregroundOpacity: CGFloat
    let hoverForegroundOpacity: CGFloat
    let pressedForegroundOpacity: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(
        configuration: ButtonStyle.Configuration,
        font: Font?,
        normalOpacity: CGFloat,
        hoverOpacity: CGFloat,
        pressedOpacity: CGFloat,
        strokeOpacity: CGFloat,
        foregroundOpacity: CGFloat,
        hoverForegroundOpacity: CGFloat? = nil,
        pressedForegroundOpacity: CGFloat
    ) {
        self.configuration = configuration
        self.font = font
        self.normalOpacity = normalOpacity
        self.hoverOpacity = hoverOpacity
        self.pressedOpacity = pressedOpacity
        self.strokeOpacity = strokeOpacity
        self.foregroundOpacity = foregroundOpacity
        self.hoverForegroundOpacity = hoverForegroundOpacity ?? foregroundOpacity
        self.pressedForegroundOpacity = pressedForegroundOpacity
    }

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white.opacity(currentForegroundOpacity))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(currentBackgroundOpacity))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(strokeOpacity), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.10), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
            .pointingHandCursor(isEnabled: isEnabled)
    }

    private var currentBackgroundOpacity: CGFloat {
        guard isEnabled else { return 0 }
        if configuration.isPressed {
            return pressedOpacity
        }
        return isHovering ? hoverOpacity : normalOpacity
    }

    private var currentForegroundOpacity: CGFloat {
        guard isEnabled else { return 0.22 }
        if configuration.isPressed {
            return pressedForegroundOpacity
        }
        return isHovering ? hoverForegroundOpacity : foregroundOpacity
    }
}

private extension View {
    func pointingHandCursor(isEnabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isCursorActive = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, isEnabled, !isCursorActive {
                    NSCursor.pointingHand.push()
                    isCursorActive = true
                } else if (!hovering || !isEnabled), isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onDisappear {
                if isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
    }
}