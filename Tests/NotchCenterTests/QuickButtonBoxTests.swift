import XCTest
@testable import QuickButtonBoxPlugin
import NotchCenterKit

// MARK: - 快捷按钮盒实例模型（文档 §4.11）

/// 盒实例动作集的持久化/去重/容量策略：placement 作用域存储有序 ID 数组，
/// 装填超容量即拒绝；多实例互不干扰。
@MainActor
final class QuickButtonBoxTests: XCTestCase {
    private func makeStore() -> StateStore {
        StateStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickButtonBoxTests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func makeSpan(columns: Int, rows: Int) -> GridSpan {
        GridSpan(columns: columns, rows: rows)
    }

    func testAppendDedupeAndCapacityRejection() {
        let store = makeStore()
        let model = BoxInstanceModel(placementID: "p.1", stateStore: store)
        let capacity = QuickButtonBoxLayout.capacity(for: makeSpan(columns: 2, rows: 2))

        // 先放满到容量（10），重复 ID 不占位。
        for index in 0..<capacity {
            XCTAssertTrue(model.append(actionID: "a.\(index)", capacity: capacity))
        }
        XCTAssertTrue(model.contains("a.0"))
        XCTAssertTrue(model.append(actionID: "a.0", capacity: capacity), "重复动作应幂等接受")
        XCTAssertFalse(model.append(actionID: "overflow", capacity: capacity), "超容量应拒绝")
        XCTAssertEqual(model.actionIDs.count, capacity)
    }

    func testPersistenceRoundtripThroughPlacementScope() {
        let store = makeStore()
        let first = BoxInstanceModel(placementID: "p.roundtrip", stateStore: store)
        _ = first.append(actionID: "media.next", capacity: 16)
        _ = first.append(actionID: "caffeinate.toggle", capacity: 16)

        // 新模型（模拟重建/重启后）从同一 scope 读到同一份顺序。
        let second = BoxInstanceModel(placementID: "p.roundtrip", stateStore: store)
        XCTAssertEqual(second.actionIDs, ["media.next", "caffeinate.toggle"])

        second.remove(actionID: "media.next")
        let third = BoxInstanceModel(placementID: "p.roundtrip", stateStore: store)
        XCTAssertEqual(third.actionIDs, ["caffeinate.toggle"])
        third.discardStorage()
    }

    func testMoveAndRemoveOrdering() {
        let store = makeStore()
        let model = BoxInstanceModel(placementID: "p.move", stateStore: store)
        _ = model.append(actionID: "a", capacity: 16)
        _ = model.append(actionID: "b", capacity: 16)
        _ = model.append(actionID: "c", capacity: 16)

        model.move(from: 0, by: 1) // b, a, c
        XCTAssertEqual(model.actionIDs, ["b", "a", "c"])
        model.move(from: 2, by: -1) // b, c, a
        XCTAssertEqual(model.actionIDs, ["b", "c", "a"])
        model.move(from: 0, by: -1) // 越界上移不动
        XCTAssertEqual(model.actionIDs, ["b", "c", "a"])
        model.remove(actionID: "c")
        XCTAssertEqual(model.actionIDs, ["b", "a"])
        model.discardStorage()
    }

    func testRegistrySharesModelPerPlacement() {
        let store = makeStore()
        let one = BoxInstanceRegistry.shared.model(placementID: "p.shared", stateStore: store)
        let two = BoxInstanceRegistry.shared.model(placementID: "p.shared", stateStore: store)
        XCTAssertTrue(one === two)

        BoxInstanceRegistry.shared.discard(placementID: "p.shared")
        let three = BoxInstanceRegistry.shared.model(placementID: "p.shared", stateStore: store)
        XCTAssertFalse(one === three, "discard 后应重建（模拟实例移除）")
        three.discardStorage()
    }

    func testLayoutCapacityTable() {
        XCTAssertEqual(QuickButtonBoxLayout.capacity(for: makeSpan(columns: 2, rows: 2)), 10)
        XCTAssertEqual(QuickButtonBoxLayout.capacity(for: makeSpan(columns: 4, rows: 2)), 16)
        XCTAssertEqual(QuickButtonBoxLayout.capacity(for: makeSpan(columns: 1, rows: 1)), 2)
    }
}
