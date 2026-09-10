import CoreGraphics
import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

/// `NotchBlock.placement`（添加落点偏好）的行为门禁。
///
/// 关键不变量：**声明只影响"添加那一刻"落在哪一页**。落位之后该块与任何其它
/// 抽屉块完全同权——可拖动、可缩放、可跨页搬移、可参与重排、可与任意块同页共存。
/// 见 Agent Note 2026-09-10-drop-exclusive-page-blocks。
@MainActor
final class BlockPlacementPreferenceTests: XCTestCase {
    private var registry: [String: NotchBlock] = [:]

    nonisolated override func setUp() {
        super.setUp()
        pinGridMetricsToFixtureDefaults()
    }

    private func makeEngine(userMaxColumns: Int = 4) throws -> LayoutEngine {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockPlacementPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = LayoutEngine(
            fileURL: directory.appendingPathComponent("layout.json"),
            blockResolver: { [weak self] pluginID, blockID in
                self?.registry["\(pluginID)|\(blockID)"]
            }
        )
        engine.setUserMaxColumns(userMaxColumns)
        var model = engine.modelForTesting
        model.minRows = 1
        model.minColumns = 1
        engine.modelForTesting = model
        return engine
    }

    /// 注册一个抽屉块；`span` = 推荐格跨（夹具格子 150×120，见 `fixtureCellWidth`）。
    private func register(
        _ blockID: String,
        span: GridSpan = GridSpan(columns: 1, rows: 1),
        placement: BlockPlacement = .autoGrid
    ) {
        let pixels = BlockPixelSize(
            width: CGFloat(span.columns) * 150,
            height: CGFloat(span.rows) * 120
        )
        registry["com.test.plugin|\(blockID)"] = NotchBlock(
            id: blockID,
            displayName: blockID,
            kind: .drawer,
            minSize: pixels,
            maxSize: pixels,
            recommendedSize: pixels,
            placement: placement,
            makeView: { _ in AnyView(EmptyView()) }
        )
    }

    // MARK: 声明默认值

    func testPlacementDefaultsToAutoGrid() {
        register("plain")
        let block = try? XCTUnwrap(registry["com.test.plugin|plain"])
        XCTAssertEqual(block?.placement, .autoGrid, "不声明 placement 的块必须保持现状：自动寻空位")
    }

    func testCompactBlockIgnoresPlacement() throws {
        registry["com.test.plugin|tiny"] = NotchBlock(
            id: "tiny",
            displayName: "tiny",
            kind: .compact,
            makeView: { _ in AnyView(EmptyView()) }
        )
        let block = try XCTUnwrap(registry["com.test.plugin|tiny"])
        XCTAssertEqual(block.placement, .autoGrid, "紧凑块没有落点偏好这回事，恒为默认值")
    }

    // MARK: 空页就地占用

    func testNewPageWhenOccupiedUsesVacantCurrentPageInPlace() throws {
        register("big", span: GridSpan(columns: 2, rows: 2), placement: .newPageWhenOccupied)
        let engine = try makeEngine()

        let outcome = engine.addDrawerBlock(
            pluginID: "com.test.plugin",
            blockID: "big",
            page: 0
        )

        guard case let .placed(_, page) = outcome else {
            return XCTFail("空页必须能放下，实际 \(outcome)")
        }
        XCTAssertEqual(page, 0, "当前页为空 → 就地占用，不新开页")
        XCTAssertEqual(engine.model.drawerPages, [0], "不该凭空多出页面")
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).count, 1)
    }

    // MARK: 非空页 → 新开一页

    func testNewPageWhenOccupiedOpensNewPageWhenCurrentPageIsOccupied() throws {
        register("plain")
        register("big", span: GridSpan(columns: 2, rows: 2), placement: .newPageWhenOccupied)
        let engine = try makeEngine()

        _ = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "plain", page: 0)
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).count, 1)

        let outcome = engine.addDrawerBlock(
            pluginID: "com.test.plugin",
            blockID: "big",
            page: 0
        )

        guard case let .placed(_, page) = outcome else {
            return XCTFail("应当新开一页放下，实际 \(outcome)")
        }
        XCTAssertNotEqual(page, 0, "当前页已被占用 → 另开一页")
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).count, 1, "原页内容不受影响")
        XCTAssertEqual(engine.drawerBlocks(onPage: page).count, 1)
    }

    func testNewPageWhenOccupiedSeedPageIdentity() throws {
        register("plain")
        register("big", span: GridSpan(columns: 2, rows: 2), placement: .newPageWhenOccupied)
        let engine = try makeEngine()
        _ = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "plain", page: 0)

        let outcome = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "big", page: 0)
        guard case let .placed(_, page) = outcome else { return XCTFail("应当放下") }

        XCTAssertEqual(engine.drawerPageTitle(page), "big", "落位时为新页补一次默认标题")
    }

    // MARK: 页满 → 失败并提示（不自动清理）

    func testNewPageWhenOccupiedFailsWhenPageLimitReached() throws {
        register("plain")
        register("big", span: GridSpan(columns: 2, rows: 2), placement: .newPageWhenOccupied)
        let engine = try makeEngine()

        // 填满页数上限，且当前页非空。
        var model = engine.modelForTesting
        model.drawerPages = Array(0..<LayoutModel.maxDrawerPageCount)
        engine.modelForTesting = model
        _ = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "plain", page: 0)

        let outcome = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "big", page: 0)

        XCTAssertEqual(outcome, .noPageCapacity)
        XCTAssertEqual(
            engine.model.drawerPages.count,
            LayoutModel.maxDrawerPageCount,
            "失败时不自动清理任何页"
        )
    }

    /// 页数已达上限时的口径：**只看当前页**是否为空。
    ///
    /// 当前页非空 → `.noPageCapacity`（哪怕别处还有空页也不去搜刮：落点偏好是
    /// "用户此刻想要一页"，不是"全局找空位"——后者是 `.autoGrid` 的语义）。
    /// 这条与 `2026-09-10-plugin-page-blocks` 原 `addPageBlock` 的规则一致。
    func testPageLimitFailsWithoutScavengingOtherVacantPages() throws {
        register("filler")
        register("big", span: GridSpan(columns: 2, rows: 2), placement: .newPageWhenOccupied)
        let engine = try makeEngine()

        var model = engine.modelForTesting
        // 页数已达上限；页 0 放一个块（非空），页 1...8 是空的。
        model.drawerPages = Array(0..<LayoutModel.maxDrawerPageCount)
        engine.modelForTesting = model
        _ = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "filler", page: 0)

        let outcome = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "big", page: 0)

        XCTAssertEqual(outcome, .noPageCapacity, "当前页非空且页数已满 → 失败提示，不搜刮其它空页")
        XCTAssertEqual(
            engine.model.drawerPages.count,
            LayoutModel.maxDrawerPageCount,
            "失败时不自动清理任何页"
        )
    }

    /// 对照：当前页**自身**为空时，即便页数已达上限也应当直接就地占用（不新增页）。
    func testVacantCurrentPageIsUsedEvenAtPageLimit() throws {
        register("big", span: GridSpan(columns: 2, rows: 2), placement: .newPageWhenOccupied)
        let engine = try makeEngine()

        var model = engine.modelForTesting
        model.drawerPages = Array(0..<LayoutModel.maxDrawerPageCount)
        engine.modelForTesting = model

        let outcome = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "big", page: 0)

        guard case let .placed(_, page) = outcome else {
            return XCTFail("当前页为空 → 就地占用，实际 \(outcome)")
        }
        XCTAssertEqual(page, 0)
        XCTAssertEqual(engine.model.drawerPages.count, LayoutModel.maxDrawerPageCount)
    }

    // MARK: 落位后完全无限制（本次改动的核心）

    func testPlacedBlockCanCoexistWithOtherBlocksOnSamePage() throws {
        register("plain")
        register("big", span: GridSpan(columns: 1, rows: 1), placement: .newPageWhenOccupied)
        let engine = try makeEngine()
        _ = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "plain", page: 0)

        let outcome = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "big", page: 0)
        guard case let .placed(placementID, page) = outcome else { return XCTFail("应当放下") }

        // 手动把它拖回原页：必须成功（不与任何"独占"守卫冲突），且两页块同页共存。
        let moved = engine.moveDrawerBlockCrossPage(
            placementID: placementID,
            toPage: 0,
            column: 0,
            row: 0
        )
        XCTAssertNotNil(moved, "落位后跨页搬移必须自由：声明只影响添加那一刻")
        XCTAssertEqual(moved?.page, 0)
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).count, 2, "同页共存合法")
        XCTAssertEqual(engine.drawerBlocks(onPage: page).count, 0, "原页随之空出")
    }

    func testPlacedBlockIsMovableResizableAndReorderable() throws {
        register("plain")
        register("big", span: GridSpan(columns: 2, rows: 2), placement: .newPageWhenOccupied)
        let engine = try makeEngine()
        _ = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "plain", page: 0)

        let outcome = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "big", page: 0)
        guard case let .placed(placementID, page) = outcome else { return XCTFail("应当放下") }

        XCTAssertTrue(
            engine.moveDrawerBlock(placementID: placementID, toColumn: 2, toRow: 1),
            "页内移动必须可用"
        )
        XCTAssertTrue(
            engine.resizeDrawerBlock(placementID: placementID, toColumns: 2, toRows: 2),
            "缩放必须可用"
        )
        XCTAssertFalse(
            engine.previewArrangement(moving: placementID, toColumn: 0, toRow: 0).isEmpty,
            "拖拽预览必须存在（不再有「独占页不可拖动」的引擎守卫）"
        )
        engine.reorderDrawerBlocks(page: page)
        XCTAssertEqual(
            engine.drawerBlocks(onPage: page).count,
            1,
            "一键重排必须把它当作普通块处理，不能整页跳过"
        )
    }

    func testAutoGridPlacementKeepsFillingCurrentPage() throws {
        register("plain")
        register("other")
        let engine = try makeEngine()

        _ = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "plain", page: 0)
        let outcome = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "other", page: 0)

        guard case let .placed(_, page) = outcome else { return XCTFail("应当放下") }
        XCTAssertEqual(page, 0, ".autoGrid 是默认：留在当前页找空位，不新开页")
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).count, 2)
        XCTAssertEqual(engine.model.drawerPages, [0])
    }

    // MARK: 落位不写任何"独占"痕迹

    func testPlacedBlockDoesNotBlockOtherBlocksFromSamePage() throws {
        register("big", span: GridSpan(columns: 1, rows: 1), placement: .newPageWhenOccupied)
        register("plain")
        let engine = try makeEngine()

        let first = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "big", page: 0)
        guard case .placed = first else { return XCTFail("应当放下") }

        // 同一个 `.newPageWhenOccupied` 块再次添加：当前页非空 → 新开页；原页仍可放普通块。
        let second = engine.addDrawerBlock(pluginID: "com.test.plugin", blockID: "plain", page: 0)
        guard case let .placed(_, page) = second else { return XCTFail("应当放下") }
        XCTAssertEqual(page, 0)
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).count, 2)
    }
}
