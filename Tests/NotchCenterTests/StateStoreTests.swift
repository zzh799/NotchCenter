import Foundation
import XCTest
import NotchCenterKit

@MainActor
final class StateStoreTests: XCTestCase {
    private func makeStore() throws -> (StateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (StateStore(rootDirectory: directory), directory)
    }

    private func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDataRoundTripAndRemoval() throws {
        let (store, directory) = try makeStore()
        defer { cleanUp(directory) }

        XCTAssertNil(store.data(forKey: "missing"))

        let payload = Data("hello".utf8)
        try store.setData(payload, forKey: "payload.bin")
        XCTAssertEqual(store.data(forKey: "payload.bin"), payload)

        try store.setData(nil, forKey: "payload.bin")
        XCTAssertNil(store.data(forKey: "payload.bin"))
    }

    func testCodableRoundTrip() throws {
        struct Record: Codable, Equatable {
            let name: String
            let count: Int
        }

        let (store, directory) = try makeStore()
        defer { cleanUp(directory) }

        let record = Record(name: "notes", count: 3)
        try store.setObject(record, forKey: "record")
        XCTAssertEqual(store.object(Record.self, forKey: "record"), record)

        store.removeValue(forKey: "record")
        XCTAssertNil(store.object(Record.self, forKey: "record"))
    }

    func testPersistsAcrossInstances() throws {
        let (store, directory) = try makeStore()
        try store.setObject("value", forKey: "key")
        defer { cleanUp(directory) }

        let restored = StateStore(rootDirectory: directory)
        XCTAssertEqual(restored.object(String.self, forKey: "key"), "value")
    }

    func testKeysAreIsolatedPerStore() throws {
        let (storeA, directoryA) = try makeStore()
        let (storeB, directoryB) = try makeStore()
        defer {
            cleanUp(directoryA)
            cleanUp(directoryB)
        }

        try storeA.setObject("A", forKey: "shared-key")
        XCTAssertNil(storeB.object(String.self, forKey: "shared-key"))
    }

    func testInvalidKeysAreRejected() throws {
        let (store, directory) = try makeStore()
        defer { cleanUp(directory) }

        XCTAssertFalse(StateStore.isValidKey(""))
        XCTAssertFalse(StateStore.isValidKey(".."))
        XCTAssertFalse(StateStore.isValidKey("a/b"))
        XCTAssertFalse(StateStore.isValidKey("a b"))
        XCTAssertTrue(StateStore.isValidKey("notes.snapshot.v1"))

        XCTAssertThrowsError(try store.setData(Data(), forKey: "a/b"))
        XCTAssertThrowsError(try store.setObject(1, forKey: "../escape"))
        store.removeValue(forKey: "a/b")  // 不应崩溃
    }

    func testResourceDirectoryIsScopedUnderRoot() throws {
        let (store, directory) = try makeStore()
        defer { cleanUp(directory) }

        let images = try store.resourceDirectory(named: "Images")
        XCTAssertTrue(images.path.hasPrefix(directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.path))
        XCTAssertThrowsError(try store.resourceDirectory(named: "bad/name"))
    }
}