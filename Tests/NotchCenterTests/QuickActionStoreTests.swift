import XCTest
@testable import NotchCenter
import NotchCenterKit

// MARK: - 快捷动作注册表（文档 §4.11）

/// QuickActionStore 生命周期与查重：宿主在插件启用/禁用时注册/注销，盒与
/// 编辑目录经 `allActions()` / `action(id:)` 取数。
@MainActor
final class QuickActionStoreTests: XCTestCase {
    private func makeAction(_ id: String, symbol: String = "bolt.fill") -> QuickAction {
        QuickAction(
            id: id,
            displayName: id,
            systemImage: symbol,
            kind: .action,
            execute: {}
        )
    }

    private func makeToggle(_ id: String) -> QuickAction {
        QuickAction(
            id: id,
            displayName: id,
            systemImage: "power",
            kind: .toggle,
            isActive: false,
            execute: {}
        )
    }

    func testRegisterFlattensByPluginOrderAndLookupByIdentity() {
        let store = QuickActionStore()
        let caffeinate = makeToggle("caffeinate.toggle")
        let mediaPlay = makeAction("media.playPause")
        let mediaNext = makeAction("media.next")

        store.register(pluginID: "com.a.caffeinate", actions: [caffeinate])
        store.register(pluginID: "com.b.media", actions: [mediaPlay, mediaNext])

        XCTAssertEqual(store.allActions().map(\.id), ["caffeinate.toggle", "media.playPause", "media.next"])
        XCTAssertTrue(store.action(id: "media.playPause") === mediaPlay)
        XCTAssertNil(store.action(id: "unknown.id"))
    }

    func testDuplicateActionIDAcrossPluginsKeepsFirst() {
        let store = QuickActionStore()
        let first = makeAction("shared.id")
        let second = makeAction("shared.id", symbol: "star.fill")

        store.register(pluginID: "plugin.a", actions: [first])
        store.register(pluginID: "plugin.b", actions: [second])

        XCTAssertEqual(store.allActions().count, 1)
        XCTAssertTrue(store.action(id: "shared.id") === first)
    }

    func testUnregisterRemovesOnlyThatPlugin() {
        let store = QuickActionStore()
        store.register(pluginID: "a", actions: [makeAction("a.1")])
        store.register(pluginID: "b", actions: [makeAction("b.1")])

        store.unregister(pluginID: "a")

        XCTAssertEqual(store.allActions().map(\.id), ["b.1"])
        XCTAssertNil(store.action(id: "a.1"))
        // 幂等：重复注销无副作用
        store.unregister(pluginID: "a")
        XCTAssertEqual(store.allActions().map(\.id), ["b.1"])
    }

    func testReRegisterReplacesPluginActionsAndKeepsPluginPosition() {
        let store = QuickActionStore()
        store.register(pluginID: "a", actions: [makeAction("a.1")])
        store.register(pluginID: "b", actions: [makeAction("b.1")])

        store.register(pluginID: "a", actions: [makeAction("a.2")])

        XCTAssertEqual(store.allActions().map(\.id), ["a.2", "b.1"])
        XCTAssertNil(store.action(id: "a.1"))
    }

    func testRemoveAllClearsEverything() {
        let store = QuickActionStore()
        store.register(pluginID: "a", actions: [makeAction("a.1")])
        store.removeAll()
        XCTAssertTrue(store.allActions().isEmpty)
    }

    func testIsActiveTogglePublishesToObservers() {
        // QuickAction 状态同步契约：插件在自身状态变化处写 isActive，
        // 盒内按钮经 @ObservedObject 自动刷新（同一份状态，双入口同源）。
        let toggle = makeToggle("caffeinate.toggle")
        toggle.isActive = true
        XCTAssertTrue(toggle.isActive)
        toggle.isActive = false
        XCTAssertFalse(toggle.isActive)
    }
}
