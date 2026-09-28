import XCTest
@testable import ScratchpadPlugin
import NotchCenterKit

/// `ScratchpadInstanceRegistry` 的持久化「已见 placementID」语义回归。
///
/// 背景：紧凑入口的计数与「清空」必须覆盖**本次会话尚未挂载**的实例（上次会话写过
/// 数据、这次还没开抽屉）。宿主管不到 placement 枚举，所以注册表自己把见过的 ID
/// 持久化下来。这里锁住三条：计数、清空、legacy 迁移不丢数据。
@MainActor
final class ScratchpadInstanceRegistryTests: XCTestCase {

    private func makeStateStore() -> StateStore {
        StateStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("scratchpad-registry-\(UUID().uuidString)")
        )
    }

    private func makeItem(_ path: String) -> FileShelfItem {
        FileShelfItem(url: URL(fileURLWithPath: path))
    }

    /// 未挂载 placement 的条目也要计入计数，并能在清空时被删掉（跨「进程」重来一次）。
    func testCountAndClearCoverUnmountedPlacements() {
        let stateStore = makeStateStore()

        let first = ScratchpadInstanceRegistry()
        first.attach(pluginStateStore: stateStore)
        XCTAssertEqual(first.totalItemCount, 0)

        // 模拟上一次会话：视图挂载过 placement-A 并加入一个文件。
        let storeA = first.store(placementID: "placement-A", stateStore: stateStore)
        XCTAssertEqual(storeA.add([URL(fileURLWithPath: "/tmp/scratchpad-a.txt")]), 1)
        XCTAssertEqual(first.totalItemCount, 1)

        // 「新进程」：从未挂载任何视图，凭持久化的已见 ID 仍要算出计数。
        let fresh = ScratchpadInstanceRegistry()
        fresh.attach(pluginStateStore: stateStore)
        XCTAssertEqual(fresh.totalItemCount, 1, "未挂载 placement 的磁盘数据也要计入")

        // 清空要落到未挂载实例的 placementScope，而不是只清内存。
        fresh.removeAll()
        XCTAssertEqual(fresh.totalItemCount, 0)

        let afterClear = ScratchpadInstanceRegistry()
        afterClear.attach(pluginStateStore: stateStore)
        XCTAssertEqual(afterClear.totalItemCount, 0, "清空必须落盘，重来一次不得复活")
    }

    /// 旧版插件级残留能被首个实例接管，且接管成功后删旧记录。
    func testLegacyItemsMigrateIntoFirstInstance() {
        let stateStore = makeStateStore()
        let legacy = [makeItem("/tmp/legacy-1.txt"), makeItem("/tmp/legacy-2.txt")]
        try? stateStore.setObject(legacy, forKey: ScratchpadStore.storageKey)

        let registry = ScratchpadInstanceRegistry()
        registry.attach(pluginStateStore: stateStore)
        XCTAssertEqual(registry.totalItemCount, 2, "未迁移前按插件级残留计数")

        let storeA = registry.store(placementID: "placement-A", stateStore: stateStore)
        XCTAssertEqual(storeA.items.count, 2, "首个实例接管旧数据")
        XCTAssertNil(
            stateStore.object([FileShelfItem].self, forKey: ScratchpadStore.storageKey),
            "接管成功后必须删除旧记录"
        )
    }

    /// 目标实例已有条目时不得删旧记录：那批旧数据应留给下一个空实例，而不是静默丢弃。
    func testLegacyItemsAreKeptWhenTargetNotEmpty() {
        let stateStore = makeStateStore()
        let occupied = stateStore.placementScope(placementID: "placement-A")!
        try? occupied.setObject([makeItem("/tmp/a-own.txt")], forKey: ScratchpadStore.storageKey)
        try? stateStore.setObject([makeItem("/tmp/legacy.txt")], forKey: ScratchpadStore.storageKey)

        let registry = ScratchpadInstanceRegistry()
        registry.attach(pluginStateStore: stateStore)

        let storeA = registry.store(placementID: "placement-A", stateStore: stateStore)
        XCTAssertEqual(storeA.items.count, 1, "已非空的实例不被旧数据覆盖")
        XCTAssertNotNil(
            stateStore.object([FileShelfItem].self, forKey: ScratchpadStore.storageKey),
            "未接管成功就不得删旧记录"
        )

        // 旧数据仍可被后续空实例接管，不丢。
        let storeB = registry.store(placementID: "placement-B", stateStore: stateStore)
        XCTAssertEqual(storeB.items.count, 1)
    }

    /// `placementWasRemoved` 走的 discard：删实例数据并同时清「已见 ID」，不再出现在计数里。
    func testDiscardRemovesPlacementDataAndSeenID() {
        let stateStore = makeStateStore()
        let registry = ScratchpadInstanceRegistry()
        registry.attach(pluginStateStore: stateStore)

        let storeA = registry.store(placementID: "placement-A", stateStore: stateStore)
        _ = storeA.add([URL(fileURLWithPath: "/tmp/scratchpad-a.txt")])
        XCTAssertEqual(registry.totalItemCount, 1)

        registry.discard(placementID: "placement-A")
        XCTAssertEqual(registry.totalItemCount, 0)

        let fresh = ScratchpadInstanceRegistry()
        fresh.attach(pluginStateStore: stateStore)
        XCTAssertEqual(fresh.totalItemCount, 0, "discard 后重来一次不得复活")
    }
}
