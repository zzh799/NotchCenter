import Foundation
import NotchCenterKit
import XCTest
@testable import ScratchpadPlugin

@MainActor
final class FileShelfStoreTests: XCTestCase {
    private func makeEnvironment() throws -> (ScratchpadStore, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileShelfStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sample.txt")
        try Data("temporary shelf item".utf8).write(to: fileURL)
        let store = ScratchpadStore(stateStore: StateStore(rootDirectory: directory))
        return (store, directory, fileURL)
    }

    func testShelfDeduplicatesPersistsAndNeverDeletesOriginalFile() throws {
        let (store, directory, fileURL) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(store.add([fileURL, fileURL]), 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNil(store.items.first?.bookmarkData)

        let restoredStore = ScratchpadStore(stateStore: StateStore(rootDirectory: directory))
        let restoredItem = try XCTUnwrap(restoredStore.items.first)
        XCTAssertEqual(restoredStore.resolvedURL(for: restoredItem)?.path, fileURL.path)
        XCTAssertTrue(restoredStore.isAvailable(restoredItem))

        restoredStore.remove(restoredItem)
        XCTAssertTrue(restoredStore.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testShelfAcceptsUnavailablePathsWithoutBlockingDrop() throws {
        let (store, directory, _) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unavailableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")

        XCTAssertEqual(store.add([unavailableURL]), 1)
        XCTAssertEqual(store.items.first?.fallbackPath, unavailableURL.path)
        XCTAssertNil(store.items.first?.bookmarkData)
    }

    func testShelfRemovesSelectedItemsAsOneOperation() throws {
        let (store, directory, _) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["first.txt", "second.txt", "third.txt"].map {
            FileManager.default.temporaryDirectory.appendingPathComponent($0)
        }
        XCTAssertEqual(store.add(urls), 3)

        store.remove(ids: Set([store.items[0].id, store.items[2].id]))
        XCTAssertEqual(store.items.map(\.originalName), ["second.txt"])
        let restored = ScratchpadStore(stateStore: StateStore(rootDirectory: directory))
        XCTAssertEqual(restored.items.map(\.originalName), ["second.txt"])
    }

    func testDropIsHandledWhenFileAlreadyExistsOnShelf() throws {
        let (store, directory, fileURL) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(store.acceptDrop([fileURL]))
        XCTAssertTrue(store.acceptDrop([fileURL]))
        XCTAssertEqual(store.items.count, 1)
    }
}
