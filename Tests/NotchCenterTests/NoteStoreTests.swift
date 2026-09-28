import Foundation
import NotchCenterKit
import XCTest
@testable import NotesPlugin

@MainActor
final class NoteStoreTests: XCTestCase {
    private func makeStore(directory: URL) -> NotesStore {
        NotesStore(stateStore: StateStore(rootDirectory: directory))
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testPersistsNotesSelectionAndReadableTitles() {
        let directory = makeRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        store.updateText("# Project log\nFirst entry")
        store.updateSelection(
            for: store.activeTabID,
            range: NSRange(location: 4, length: 3)
        )
        XCTAssertEqual(store.title(for: store.activeTabID), "Project log")

        let firstTabID = store.activeTabID
        store.addTab()
        store.updateText("- [ ] Follow up")
        store.flush()

        let restored = makeStore(directory: directory)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.text, "- [ ] Follow up")
        XCTAssertEqual(restored.title(for: firstTabID), "Project log")
        XCTAssertEqual(
            restored.selectionRange(for: firstTabID),
            NSRange(location: 4, length: 3)
        )
    }

    /// 连续输入期间必须落盘：旧实现每次输入都取消上一个待执行保存并重排，
    /// 只要两次输入的间隔一直短于去抖窗口，待执行保存被无限推迟、整段零落盘，
    /// 进程被强退即丢稿。此用例按 0.05s 间隔连打 10 次（每次都 < 0.18s 去抖窗口），
    /// 在输入尚未停止时读取落盘快照，断言非空。
    func testContinuousTypingPersistsBeforeInputStops() async throws {
        let directory = makeRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateStore = StateStore(rootDirectory: directory)
        let store = NotesStore(stateStore: stateStore)

        var typed = ""
        for _ in 0..<10 {
            typed += "x"
            store.updateText(typed)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // 此刻仍处于「连续输入」语义内：末次输入后的 0.18s 去抖窗口尚未走完。
        // 新实现的首次保存已在 ~0.18s 处落盘；旧实现要到输入停止后才写。
        let midway = NotesStore(stateStore: stateStore)
        XCTAssertFalse(
            midway.text.isEmpty,
            "连续输入期间应有保存落盘（旧实现会把待执行保存一直推迟到输入停止）"
        )

        // 等待末次输入的保存窗口结束，确认最终内容完整落盘。
        try await Task.sleep(nanoseconds: 300_000_000)
        let restored = NotesStore(stateStore: stateStore)
        XCTAssertEqual(restored.text, typed)
    }

    func testDeletedNoteCanBeRestoredWithoutLosingContent() {
        let directory = makeRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        store.updateText("Keep this note")
        let originalID = store.activeTabID
        store.addTab()

        store.selectTab(originalID)
        store.removeActiveTab()
        XCTAssertTrue(store.canRestoreDeletedNote)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == originalID }))

        store.restoreLastDeletedTab()
        XCTAssertFalse(store.canRestoreDeletedNote)
        XCTAssertEqual(store.activeTabID, originalID)
        XCTAssertEqual(store.text, "Keep this note")
    }

    func testDeletingInactiveNoteKeepsCurrentNoteActive() {
        let directory = makeRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let firstID = store.activeTabID
        store.addTab()
        let activeID = store.activeTabID

        store.removeTab(firstID)

        XCTAssertEqual(store.activeTabID, activeID)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == firstID }))
        XCTAssertTrue(store.canRestoreDeletedNote)
    }

    func testNewStoreStartsWithOneEmptyTabWhenNothingPersisted() {
        let directory = makeRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertTrue(store.text.isEmpty)
    }
}
