import Combine
import Foundation
import NotchCenterKit

struct NoteTab: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var selectionLocation: Int?
    var selectionLength: Int?

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        selectionLocation = 0
        selectionLength = 0
    }
}

/// 笔记数据层（官方 NotesPlugin）。
/// 多标签 Markdown 笔记；状态经 StateStore 持久化（文档 §4.6，键值单快照）。
/// 保存去抖 0.18s，且连续编辑至多 0.18s 必落盘一次；需要可靠落盘时调用 `flush()`。
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var tabs: [NoteTab]
    @Published private(set) var activeTabID: UUID

    private static let storageKey = "notes.snapshot.v1"
    private static let saveDelay: TimeInterval = 0.18

    private struct PersistedNotes: Codable {
        let tabs: [NoteTab]
        let activeTabID: UUID
        let savedAt: Date
    }

    private struct DeletedNote {
        let tab: NoteTab
        let index: Int
    }

    private let stateStore: StateStore
    private var pendingSave: DispatchWorkItem?
    private var recentlyDeletedNote: DeletedNote?

    init(stateStore: StateStore) {
        self.stateStore = stateStore

        let snapshot = stateStore.object(PersistedNotes.self, forKey: Self.storageKey)
        let initialTabs: [NoteTab]
        if let snapshot, !snapshot.tabs.isEmpty {
            initialTabs = snapshot.tabs
        } else {
            initialTabs = [NoteTab()]
        }
        tabs = initialTabs

        let preferredActiveID = snapshot?.activeTabID
        activeTabID = preferredActiveID.flatMap { activeID in
            initialTabs.contains(where: { $0.id == activeID }) ? activeID : nil
        } ?? initialTabs[0].id

        persistNow()
    }

    var text: String {
        tabs[activeIndex].text
    }

    /// 指定标签页的文本（多实例显示不同标签页时使用）。
    func text(for id: UUID) -> String {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return "" }
        return tabs[index].text
    }

    func updateText(_ nextText: String) {
        updateText(nextText, for: activeTabID)
    }

    /// 更新指定标签页的文本（多个块实例各自显示不同标签页时使用；数据仍是同一份）。
    func updateText(_ nextText: String, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].text != nextText else { return }
        tabs[index].text = nextText
        clampSelection(for: id)
        scheduleSave()
    }

    func clear() {
        updateText("")
        updateSelection(for: activeTabID, range: NSRange(location: 0, length: 0))
    }

    /// 新建标签页并返回其 ID。
    @discardableResult
    func addTab() -> UUID {
        let tab = NoteTab()
        tabs.append(tab)
        activeTabID = tab.id
        scheduleSave()
        return tab.id
    }

    func removeActiveTab() {
        removeTab(activeTabID)
    }

    func removeTab(_ id: UUID) {
        guard tabs.count > 1,
              let removedIndex = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let wasActive = id == activeTabID
        recentlyDeletedNote = DeletedNote(tab: tabs.remove(at: removedIndex), index: removedIndex)
        if wasActive {
            let nextIndex = min(removedIndex, tabs.count - 1)
            activeTabID = tabs[nextIndex].id
        }
        scheduleSave()
    }

    func restoreLastDeletedTab() {
        guard let recentlyDeletedNote else { return }
        let insertionIndex = min(max(recentlyDeletedNote.index, 0), tabs.count)
        tabs.insert(recentlyDeletedNote.tab, at: insertionIndex)
        activeTabID = recentlyDeletedNote.tab.id
        self.recentlyDeletedNote = nil
        scheduleSave()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard activeTabID != id else { return }
        activeTabID = id
        scheduleSave()
    }

    func updateSelection(for id: UUID, range: NSRange) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clamped = clampedRange(range, text: tabs[index].text)
        guard tabs[index].selectionLocation != clamped.location
                || tabs[index].selectionLength != clamped.length else {
            return
        }
        tabs[index].selectionLocation = clamped.location
        tabs[index].selectionLength = clamped.length
        scheduleSave()
    }

    func selectionRange(for id: UUID) -> NSRange {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return NSRange(location: 0, length: 0)
        }

        return clampedRange(
            NSRange(location: tab.selectionLocation ?? 0, length: tab.selectionLength ?? 0),
            text: tab.text
        )
    }

    func title(for id: UUID) -> String {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return "Untitled"
        }

        var title = firstMeaningfulLine(in: tabs[index].text) ?? ""

        while let prefix = ["# ", "## ", "### ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "> "]
            .first(where: { title.hasPrefix($0) }) {
            title.removeFirst(prefix.count)
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return LF("notes.untitled", index + 1) }
        return title.count > 42 ? String(title.prefix(41)) + "…" : title
    }

    var canRestoreDeletedNote: Bool {
        recentlyDeletedNote != nil
    }

    /// 立即落盘（宿主退出或插件禁用时调用）。
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        persistNow()
    }

    private var activeIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    private func clampSelection(for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let range = NSRange(location: tabs[index].selectionLocation ?? 0, length: tabs[index].selectionLength ?? 0)
        let clamped = clampedRange(range, text: tabs[index].text)
        tabs[index].selectionLocation = clamped.location
        tabs[index].selectionLength = clamped.length
    }

    private func clampedRange(_ range: NSRange, text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let selectionLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: selectionLength)
    }

    /// 去抖 0.18s，且连续编辑至多 0.18s 必落盘一次。
    /// 已有待执行保存时直接返回（不取消重排）：若像传统去抖那样每次取消重排，
    /// 连续打字期间保存会被无限推迟而几乎不落盘；此处的合并窗口仅吸收 0.18s 内的抖动。
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let save = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.persistNow()
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: save)
    }

    private func persistNow() {
        let snapshot = PersistedNotes(
            tabs: tabs,
            activeTabID: activeTabID,
            savedAt: Date()
        )
        try? stateStore.setObject(snapshot, forKey: Self.storageKey)
    }

    private func firstMeaningfulLine(in text: String) -> String? {
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                return line
            }

            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }

        return nil
    }
}