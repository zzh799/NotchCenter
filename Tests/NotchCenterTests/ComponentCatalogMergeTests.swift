import XCTest
@testable import NotchCenter
import NotchCenterKit

// MARK: - 组件目录合一（文档 §4.11：块卡与快捷动作合成一张卡）

/// 块卡 ↔ 动作合一规则回归：`sourceBlockID` 指向本插件某块的动作并入块卡
/// （双身份，拖到盒上装填），未被吸收的动作作为独立「盒用动作」卡单列。
/// 这是「快捷按钮盒收快捷按钮、目录不出现同一入口两份」的纯逻辑层。
@MainActor
final class ComponentCatalogMergeTests: XCTestCase {
    private func makeAction(
        id: String,
        sourceBlockID: String? = nil
    ) -> QuickAction {
        QuickAction(
            id: id,
            displayName: id,
            systemImage: "circle",
            kind: .action,
            sourceBlockID: sourceBlockID,
            execute: {}
        )
    }

    // MARK: actionID(for:in:)

    func testActionIDMatchesBlockWhenSourcePointsAtIt() {
        let actions = [
            makeAction(id: "caffeinate.toggle", sourceBlockID: "caffeinate.toggle"),
            makeAction(id: "media.next"),
        ]
        XCTAssertEqual(
            ComponentCatalogMerger.actionID(for: "caffeinate.toggle", in: actions),
            "caffeinate.toggle"
        )
        XCTAssertNil(ComponentCatalogMerger.actionID(for: "media.controls", in: actions))
        XCTAssertNil(ComponentCatalogMerger.actionID(for: "unknown.block", in: actions))
    }

    func testActionIDIgnoresUnrelatedSourceBlock() {
        let actions = [makeAction(id: "a.b", sourceBlockID: "other.block")]
        XCTAssertNil(ComponentCatalogMerger.actionID(for: "a.b", in: actions))
    }

    func testActionIDIgnoresActionsWithoutSourceBlock() {
        let actions = [makeAction(id: "a.b")]
        XCTAssertNil(ComponentCatalogMerger.actionID(for: "a.b", in: actions))
    }

    // MARK: standaloneActions(_:blockIDs:)

    func testStandaloneKeepsActionsWithoutSourceBlock() {
        let actions = [makeAction(id: "media.next"), makeAction(id: "clipboard.clear")]
        let standalone = ComponentCatalogMerger.standaloneActions(
            actions,
            blockIDs: ["media.controls", "clipboard.tray", "clipboard.history"]
        )
        XCTAssertEqual(standalone.map(\.id), ["media.next", "clipboard.clear"])
    }

    func testStandaloneExcludesActionsAbsorbedByKnownBlocks() {
        let actions = [
            makeAction(id: "caffeinate.toggle", sourceBlockID: "caffeinate.toggle"),
            makeAction(id: "media.next"),
        ]
        let standalone = ComponentCatalogMerger.standaloneActions(
            actions,
            blockIDs: ["caffeinate.toggle", "media.controls"]
        )
        XCTAssertEqual(standalone.map(\.id), ["media.next"])
    }

    func testStandaloneFallsBackToStandaloneWhenBlockMissing() {
        // 防御：动作仍指向 sourceBlockID 但插件已不注册该块 → 按独立动作展示，
        // 不让入口凭空消失。
        let actions = [makeAction(id: "legacy.toggle", sourceBlockID: "legacy.block")]
        let standalone = ComponentCatalogMerger.standaloneActions(
            actions,
            blockIDs: [] // 该插件当前没有任何块
        )
        XCTAssertEqual(standalone.map(\.id), ["legacy.toggle"])
    }

    // MARK: QuickAction.sourceBlockID 默认值

    func testSourceBlockIDDefaultsToNil() {
        let action = QuickAction(
            id: "plain.action",
            displayName: "Plain",
            systemImage: "circle",
            kind: .action,
            execute: {}
        )
        XCTAssertNil(action.sourceBlockID)
    }
}
