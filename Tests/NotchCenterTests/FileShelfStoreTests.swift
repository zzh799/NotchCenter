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

    // MARK: 每实例独立暂存区（placementScope）

    private func makePluginEnvironment() throws -> (StateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileShelfStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (StateStore(rootDirectory: directory), directory)
    }

    func testPlacementStoresAreIsolatedPerInstance() throws {
        let (pluginStore, directory) = try makePluginEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ScratchpadInstanceRegistry()
        registry.attach(pluginStateStore: pluginStore)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolated-\(UUID().uuidString).txt")

        let first = registry.store(placementID: "placement-a", stateStore: pluginStore)
        let second = registry.store(placementID: "placement-b", stateStore: pluginStore)
        XCTAssertFalse(first === second)

        XCTAssertEqual(first.add([fileURL]), 1)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(second.items.count, 0)

        // 同一 placementID 返回缓存实例（多屏视图副本观察同一 ObservableObject）。
        XCTAssertTrue(registry.store(placementID: "placement-a", stateStore: pluginStore) === first)

        // 持久化互相隔离：各实例落在各自的 placements/<id>/ 子目录。
        let restoredFirst = ScratchpadStore(
            stateStore: pluginStore.placementScope(placementID: "placement-a")
        )
        XCTAssertEqual(restoredFirst.items.map(\.originalName), [fileURL.lastPathComponent])
        let restoredSecond = ScratchpadStore(
            stateStore: pluginStore.placementScope(placementID: "placement-b")
        )
        XCTAssertTrue(restoredSecond.items.isEmpty)
    }

    func testDiscardRemovesInstanceCacheAndPersistedItems() throws {
        let (pluginStore, directory) = try makePluginEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ScratchpadInstanceRegistry()
        registry.attach(pluginStateStore: pluginStore)
        let store = registry.store(placementID: "placement-a", stateStore: pluginStore)
        XCTAssertTrue(store.acceptDrop([FileManager.default.temporaryDirectory
            .appendingPathComponent("doomed-\(UUID().uuidString).txt")]))

        registry.discard(placementID: "placement-a")

        let recreated = registry.store(placementID: "placement-a", stateStore: pluginStore)
        XCTAssertTrue(recreated.items.isEmpty, "移除实例后重建应从空开始（持久化记录已删除）")
        XCTAssertFalse(recreated === store)
    }

    func testLegacyPluginLevelItemsMigrateIntoFirstPlacementOnlyOnce() throws {
        let (pluginStore, directory) = try makePluginEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyItem = FileShelfItem(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).txt"))
        try pluginStore.setObject([legacyItem], forKey: "shelf.items.v1")

        let registry = ScratchpadInstanceRegistry()
        registry.attach(pluginStateStore: pluginStore)

        let first = registry.store(placementID: "placement-a", stateStore: pluginStore)
        XCTAssertEqual(first.items.count, 1, "旧版插件级数据应迁入首个新实例")
        XCTAssertNil(pluginStore.data(forKey: "shelf.items.v1"), "迁移后旧记录应清除")

        // 第二个实例从空开始，不再重复拿到旧数据。
        let second = registry.store(placementID: "placement-b", stateStore: pluginStore)
        XCTAssertTrue(second.items.isEmpty)
    }

    func testRemoveAllClearsEveryInstanceAndLegacyResidue() throws {
        let (pluginStore, directory) = try makePluginEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyItem = FileShelfItem(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).txt"))
        try pluginStore.setObject([legacyItem], forKey: "shelf.items.v1")
        let registry = ScratchpadInstanceRegistry()
        registry.attach(pluginStateStore: pluginStore)

        // 尚无任何抽屉块在屏时，紧凑角标仍计入旧版残留。
        XCTAssertEqual(registry.totalItemCount, 1)
        registry.store(placementID: "placement-a", stateStore: pluginStore)
            .acceptDrop([FileManager.default.temporaryDirectory
                .appendingPathComponent("kept-\(UUID().uuidString).txt")])
        XCTAssertEqual(registry.totalItemCount, 2)

        registry.removeAll()

        XCTAssertEqual(registry.totalItemCount, 0)
        XCTAssertTrue(ScratchpadStore(
            stateStore: pluginStore.placementScope(placementID: "placement-a")
        ).items.isEmpty)
        XCTAssertNil(pluginStore.data(forKey: "shelf.items.v1"))
    }
}
