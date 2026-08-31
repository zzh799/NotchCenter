import AppKit
import SwiftUI

enum MarkdownCommand: CaseIterable, Identifiable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case quote
    case unorderedList
    case orderedList
    case todoList

    var id: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "inlineCode"
        case .link: return "link"
        case .quote: return "quote"
        case .unorderedList: return "unorderedList"
        case .orderedList: return "orderedList"
        case .todoList: return "todoList"
        }
    }

    // 编辑器工具栏按钮的 help 提示，走插件本地化表。
    var help: String {
        switch self {
        case .bold: return L("notes.editor.bold")
        case .italic: return L("notes.editor.italic")
        case .strikethrough: return L("notes.editor.strikethrough")
        case .inlineCode: return L("notes.editor.inlineCode")
        case .link: return L("notes.editor.link")
        case .quote: return L("notes.editor.quote")
        case .unorderedList: return L("notes.editor.bulletedList")
        case .orderedList: return L("notes.editor.numberedList")
        case .todoList: return L("notes.editor.todoList")
        }
    }
}

@MainActor
final class EditorInteractionState: ObservableObject {
    @Published private(set) var isDraggingSelection = false
    var onSelectionChange: ((NSRange) -> Void)?

    private weak var textView: NSTextView?
    private weak var containerView: NSView?
    private weak var observedSelectionTextView: NSTextView?
    private var selectionObserver: NSObjectProtocol?
    private var didStartInEditor = false
    private var pendingFocus = false
    private var pendingSelectionRange: NSRange?
    private var focusAttemptsRemaining = 0
    private var layoutRefreshGeneration = 0
    private var selectionRestoreGeneration = 0

    func bind(containerView: NSView?, textView: NSTextView?) {
        FocusProbe.log("bind textViewWindow=\(describeWindow(of: textView)) containerWindow=\(describeWindow(of: containerView)) pendingFocus=\(pendingFocus)")
        // 抽屉视图树在每块屏各挂一份且共享本状态：只允许“在屏窗口”里的
        // 实例接管引用。隐藏屏实例的 bind 若最后落地，后续焦点/命令会打
        // 到隐藏窗口——makeKeyAndOrderFront 会把已收起的抽屉重新拉上屏
        // （“新建笔记多出一块面板”）。当前引用不在屏（或为空）时仍允许
        // 隐藏实例接管：窗口重新上屏时不一定再触发 bind，引用不能永远
        // 钉死在旧树。
        let candidateVisible = (textView?.window ?? containerView?.window)?.isVisible ?? false
        let currentVisible = (self.textView?.window ?? self.containerView?.window)?.isVisible ?? false
        if !candidateVisible && currentVisible {
            FocusProbe.log("bind REJECTED (hidden candidate, current visible)")
            return
        }

        // Keep the container around so markdown commands can rediscover a
        // fresh text view after SwiftUI rebuilds the editor hierarchy.
        if let containerView {
            self.containerView = containerView
        }

        if let textView {
            self.textView = textView
            observeSelectionChanges(in: textView)
            applyPendingSelectionRestore()
        }

        if pendingFocus {
            focusEditor()
        }
    }

    func requestFocus(searchingIn rootView: NSView?) {
        refreshTextView(searchingIn: rootView)
        pendingFocus = true
        focusAttemptsRemaining = 8

        retryFocus(searchingIn: rootView ?? containerView)
    }

    /// 延迟焦点请求：不立即查找 textView，只挂起标记，等编辑器视图经
    /// `EditorFocusBinder` bind 时自动聚焦。适用于“点击紧凑图标 → 展开
    /// 抽屉 → 视图重建”的场景——此刻编辑器还不存在，轮询会超时落空。
    func scheduleDeferredFocus() {
        pendingFocus = true
    }

    func restoreSelection(
        _ range: NSRange,
        searchingIn rootView: NSView? = nil,
        reveal: Bool = true
    ) {
        pendingSelectionRange = range
        if let rootView {
            refreshTextView(searchingIn: rootView)
        }

        selectionRestoreGeneration += 1
        let generation = selectionRestoreGeneration
        scheduleSelectionRestore(
            range: range,
            generation: generation,
            remainingPasses: 4,
            searchingIn: rootView,
            reveal: reveal
        )
    }

    func requestLayoutRefresh(searchingIn rootView: NSView? = nil, resetScroll: Bool = false) {
        if let rootView {
            refreshTextView(searchingIn: rootView)
        }

        layoutRefreshGeneration += 1
        let generation = layoutRefreshGeneration
        scheduleLayoutRefresh(generation: generation, remainingPasses: 4, searchingIn: rootView, resetScroll: resetScroll)
    }

    func currentSelectionRange() -> NSRange? {
        guard let textView else { return nil }
        return safeSelectedRange(in: textView)
    }

    func hasKeyboardFocus() -> Bool {
        guard let textView, let window = textView.window else { return false }
        return window.firstResponder === textView
    }

    func applyMarkdownCommand(_ command: MarkdownCommand) {
        // A SwiftUI rebuild can leave our stale reference dangling until the
        // next binder pass; re-scan once so toolbar clicks are not dropped.
        refreshTextView(searchingIn: containerView)

        guard let textView else { return }

        focusEditor()

        switch command {
        case .bold:
            wrapSelection(prefix: "**", suffix: "**", placeholder: "bold", in: textView)
        case .italic:
            wrapSelection(prefix: "*", suffix: "*", placeholder: "italic", in: textView)
        case .strikethrough:
            wrapSelection(prefix: "~~", suffix: "~~", placeholder: "strikethrough", in: textView)
        case .inlineCode:
            wrapSelection(prefix: "`", suffix: "`", placeholder: "code", in: textView)
        case .link:
            applyLink(in: textView)
        case .quote:
            prefixSelectedLines(with: "> ", in: textView)
        case .unorderedList:
            prefixSelectedLines(with: "- ", in: textView)
        case .orderedList:
            prefixSelectedLines(in: textView) { index in "\(index + 1). " }
        case .todoList:
            prefixSelectedLines(with: "- [ ] ", in: textView)
        }

        requestLayoutRefresh()
    }

    func handleMouseEvent(_ event: NSEvent, searchingIn rootView: NSView?) {
        switch event.type {
        case .leftMouseDown:
            refreshTextView(searchingIn: rootView)
            didStartInEditor = contains(event)
            isDraggingSelection = false
            if didStartInEditor {
                focusEditor()
            }
        case .leftMouseDragged:
            noteMouseDragged()
        case .leftMouseUp:
            resetDragState()
        default:
            break
        }
    }

    func noteGlobalMouseDragged() {
        noteMouseDragged()
    }

    func noteGlobalMouseUp() {
        resetDragState()
    }

    private func noteMouseDragged() {
        guard didStartInEditor else { return }
        isDraggingSelection = true
    }

    private func focusEditor() {
        guard let textView else {
            return
        }
        // 兜底：聚焦绝不能把已收起的抽屉窗口拉回屏幕（多屏下另一块屏的
        // 抽屉会“复活”成第二块面板）。引用落在隐藏窗口时放弃本次聚焦，
        // pendingFocus 保留给下一次可见实例的 bind。
        guard let window = textView.window, window.isVisible else {
            FocusProbe.log("focusEditor SKIPPED (window hidden) \(describeWindow(of: textView))")
            return
        }
        FocusProbe.log("focusEditor window=\(describeWindow(of: textView))")

        pendingFocus = false
        focusAttemptsRemaining = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func observeSelectionChanges(in textView: NSTextView) {
        guard observedSelectionTextView !== textView else { return }

        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }

        observedSelectionTextView = textView
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let range = self.currentSelectionRange() else { return }
                self.onSelectionChange?(range)
            }
        }
    }

    private func applyPendingSelectionRestore() {
        guard let pendingSelectionRange else { return }
        applySelection(pendingSelectionRange, reveal: false)
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String, in textView: NSTextView) {
        let range = safeSelectedRange(in: textView)
        let selectedText = (textView.string as NSString).substring(with: range)
        let content = selectedText.isEmpty ? placeholder : selectedText
        let replacement = prefix + content + suffix
        let selection = NSRange(location: range.location + prefix.utf16.count, length: content.utf16.count)
        replaceText(in: textView, range: range, with: replacement, selectionAfter: selection)
    }

    private func applyLink(in textView: NSTextView) {
        let range = safeSelectedRange(in: textView)
        let selectedText = (textView.string as NSString).substring(with: range)
        let label = selectedText.isEmpty ? "link text" : selectedText
        let replacement = "[\(label)](url)"
        let selection: NSRange

        if selectedText.isEmpty {
            selection = NSRange(location: range.location + 1, length: label.utf16.count)
        } else {
            selection = NSRange(location: range.location + label.utf16.count + 3, length: 3)
        }

        replaceText(in: textView, range: range, with: replacement, selectionAfter: selection)
    }

    private func prefixSelectedLines(with prefix: String, in textView: NSTextView) {
        prefixSelectedLines(in: textView) { _ in prefix }
    }

    private func prefixSelectedLines(in textView: NSTextView, prefixForLine: (Int) -> String) {
        let nsString = textView.string as NSString
        let selectedRange = safeSelectedRange(in: textView)
        let lineRange = nsString.lineRange(for: selectedRange)
        let original = nsString.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")

        if hasTrailingNewline {
            lines.removeLast()
        }

        if lines.isEmpty {
            lines = [""]
        }

        let replacementBody = lines.enumerated()
            .map { index, line in prefixForLine(index) + line }
            .joined(separator: "\n")
        let replacement = replacementBody + (hasTrailingNewline ? "\n" : "")
        let selection = NSRange(location: lineRange.location, length: replacement.utf16.count)
        replaceText(in: textView, range: lineRange, with: replacement, selectionAfter: selection)
    }

    private func replaceText(in textView: NSTextView, range: NSRange, with replacement: String, selectionAfter: NSRange) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(selectionAfter)
    }

    private func safeSelectedRange(in textView: NSTextView) -> NSRange {
        clampedRange(textView.selectedRange(), length: (textView.string as NSString).length)
    }

    private func scheduleSelectionRestore(
        range: NSRange,
        generation: Int,
        remainingPasses: Int,
        searchingIn rootView: NSView?,
        reveal: Bool
    ) {
        let delay: TimeInterval = remainingPasses == 4 ? 0.02 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak rootView] in
            guard let self, self.selectionRestoreGeneration == generation else { return }
            if let rootView {
                self.refreshTextView(searchingIn: rootView)
            }
            self.applySelection(range, reveal: reveal && remainingPasses == 1)

            guard remainingPasses > 1 else {
                self.pendingSelectionRange = nil
                return
            }

            self.scheduleSelectionRestore(
                range: range,
                generation: generation,
                remainingPasses: remainingPasses - 1,
                searchingIn: rootView,
                reveal: reveal
            )
        }
    }

    private func applySelection(_ range: NSRange, reveal: Bool) {
        guard let textView else { return }
        let safeRange = clampedRange(range, length: (textView.string as NSString).length)
        let preservedScrollOrigin = reveal
            ? nil
            : textView.enclosingScrollView?.contentView.bounds.origin
        textView.setSelectedRange(safeRange)
        if reveal {
            textView.scrollRangeToVisible(safeRange)
        } else if let scrollView = textView.enclosingScrollView,
                  let preservedScrollOrigin {
            scrollView.contentView.scroll(to: preservedScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Clamps a range against `fullLength` so TextKit never sees an
    /// out-of-bounds location/length (mutation APIs crash on those).
    private func clampedRange(_ range: NSRange, length fullLength: Int) -> NSRange {
        let location = min(max(range.location, 0), fullLength)
        let length = min(max(range.length, 0), fullLength - location)
        return NSRange(location: location, length: length)
    }

    private func scheduleLayoutRefresh(
        generation: Int,
        remainingPasses: Int,
        searchingIn rootView: NSView?,
        resetScroll: Bool
    ) {
        let delay: TimeInterval = remainingPasses == 4 ? 0.02 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak rootView] in
            guard let self, self.layoutRefreshGeneration == generation else { return }
            if let rootView {
                self.refreshTextView(searchingIn: rootView)
            }
            self.applyLayoutRefresh(resetScroll: resetScroll && remainingPasses == 4)

            guard remainingPasses > 1 else { return }
            self.scheduleLayoutRefresh(
                generation: generation,
                remainingPasses: remainingPasses - 1,
                searchingIn: rootView,
                resetScroll: false
            )
        }
    }

    private func applyLayoutRefresh(resetScroll: Bool) {
        guard let textView else { return }

        textView.layoutSubtreeIfNeeded()

        if let textLayoutManager = textView.textLayoutManager {
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

            let documentEnd = textLayoutManager.documentRange.endLocation
            textLayoutManager.ensureLayout(for: NSTextRange(location: documentEnd))
        }

        if let scrollView = textView.enclosingScrollView {
            if resetScroll {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.needsDisplay = true
        }

        textView.needsDisplay = true
        textView.setNeedsDisplay(textView.visibleRect)
        textView.window?.displayIfNeeded()
    }

    private func retryFocus(searchingIn rootView: NSView?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak rootView] in
            guard let self, self.pendingFocus else { return }
            self.refreshTextView(searchingIn: rootView)

            if self.textView != nil {
                self.focusEditor()
                return
            }

            self.focusAttemptsRemaining -= 1
            guard self.focusAttemptsRemaining > 0 else {
                self.pendingFocus = false
                return
            }

            self.retryFocus(searchingIn: rootView)
        }
    }

    private func refreshTextView(searchingIn rootView: NSView?) {
        guard let rootView,
              let freshTextView = rootView.firstDescendant(ofType: NSTextView.self) else {
            return
        }

        textView = freshTextView
    }

    func resetDragState() {
        didStartInEditor = false
        isDraggingSelection = false
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard let textView,
              let window = textView.window,
              event.window === window else {
            return false
        }

        let location = textView.convert(event.locationInWindow, from: nil)
        return textView.bounds.contains(location)
    }

}

/// 诊断探针：NOTCHCENTER_GHOST_PROBE=1 时输出编辑器焦点/绑定决策日志。
enum FocusProbe {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["NOTCHCENTER_GHOST_PROBE"] == "1" }
    static func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("[focus] \(message)")
    }
}

@MainActor
private func describeWindow(of view: NSView?) -> String {
    guard let view, let window = view.window else { return "nil" }
    return "\(Unmanaged.passUnretained(window).toOpaque()) visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame))"
}

struct EditorFocusBinder: NSViewRepresentable {
    let state: EditorInteractionState
    /// 只读预览副本：完全不参与 bind。必须挡在 binder 侧而不是 `state.bind` 里——
    /// bind 由 `makeNSView`/`updateNSView` 无条件异步触发，而预览层随时整层消失；
    /// 它的 bind 一旦后落地，在屏实例的 weak `textView`/`containerView` 就成了悬空引用。
    var isPreview: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        bind(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        bind(from: view)
    }

    private func bind(from view: NSView) {
        guard !isPreview else { return }
        DispatchQueue.main.async {
            let container = view.superview
            let textView = container?.firstDescendant(ofType: NSTextView.self)
                ?? view.firstAncestorDescendant(ofType: NSTextView.self)
            state.bind(containerView: container, textView: textView)
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func firstAncestorDescendant<T: NSView>(ofType type: T.Type) -> T? {
        var current: NSView? = self

        while let view = current {
            if let match = view.firstDescendant(ofType: type) {
                return match
            }
            current = view.superview
        }

        return nil
    }
}
