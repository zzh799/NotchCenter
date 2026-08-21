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
