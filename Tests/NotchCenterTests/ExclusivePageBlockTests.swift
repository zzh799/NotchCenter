import CoreGraphics
import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

/// 整页块（`BlockKind.page`）的引擎侧回归：添加落点规则、独占不变量守卫、
/// 几何归一与 `isPage` 持久化标记回落。
///
/// 决策背景见 Agent Note 2026-09-10-plugin-page-blocks（排他性由引擎保证，
/// 不依赖视图层）。用例一律钉住像素夹具基准的网格指标（默认 150×120），
/// 否则开发者机器上改过的格子会让"推荐档 → 格跨"的断言漂移。
@MainActor
final class ExclusivePageBlockTests: XCTestCase {
    private let pluginID = "com.test.page"
    private var registry: [String: NotchBlock] = [:]

    // 每个测试方法新建实例，`registry` 的内联初值即空字典，无需在 setUp 重置
    // （`setUp` 保持 nonisolated，不触碰主线程隔离状态）。
    nonisolated override func setUp() {
        super.setUp()
        pinGridMetricsToFixtureDefaults()
    }

    // MARK: 夹具

    /// 整页块：物理三档 300×240 / 600×360 / 900×600（对标 pomodoro.page）。
    private func registerPageBlock(id: String = "page.app") {
        registry["\(pluginID)|\(id)"] = NotchBlock(
            id: id,
            displayName: id,
            kind: .page,
            minSize: BlockPixelSize(width: 300, height: 240),
            maxSize: BlockPixelSize(width: 900, height: 600),
            recommendedSize: BlockPixelSize(width: 600, height: 360),
            makeView: { _ in AnyView(EmptyView()) }
        )
    }

    /// 普通抽屉块：300×120 单档（推荐 = 最小）。
    private func registerDrawerBlock(id: String = "grid.card") {
        registry["\(pluginID)|\(id)"] = NotchBlock(
            id: id,
            displayName: id,
            kind: .drawer,
            minSize: BlockPixelSize(width: 300, height: 120),
            maxSize: BlockPixelSize(width: 300, height: 120),
            recommendedSize: BlockPixelSize(width: 300, height: 120),
            makeView: { _ in AnyView(EmptyView()) }
        )
    }

    private func makeEngine() throws -> (LayoutEngine, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExclusivePage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let engine = LayoutEngine(
            fileURL: directory.appendingPathComponent("layout.json"),
            blockResolver: { [weak self] pluginID, blockID in
                self?.registry["\(pluginID)|\(blockID)"]
            }
        )
        return (engine, directory)
    }

    private func placedPageBlock(_ engine: LayoutEngine) -> PlacedBlock? {
        engine.drawerBlocks.first { $0.isPage }
    }

    // MARK: 添加落点（空页就地占用，否则新开一页）

    func testAddPageBlockOccupiesVacantCurrentPage() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()

        guard case let .placed(_, page) = engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ) else {
            return XCTFail("空页应当就地占用")
        }
        XCTAssertEqual(page, 0)
        XCTAssertEqual(engine.drawerPages, [0])

        let block = try XCTUnwrap(placedPageBlock(engine))
        XCTAssertEqual(block.originColumn, 0)
        XCTAssertEqual(block.originRow, 0)
        XCTAssertTrue(block.isPage)
        // 推荐档 600×360 → 4×3 格；列再夹进 [最小列数 3, 有效容量 4] = 4。
        XCTAssertEqual(block.widthColumns, 4)
        XCTAssertEqual(block.heightRows, 3)
        // 页面身份按块名补默认值：胶囊上不再是"第 1 页"。
        XCTAssertEqual(engine.drawerPageTitles["0"], "page.app")
    }

    func testAddPageBlockOpensNewPageWhenCurrentPageBusy() throws {
        registerPageBlock()
        registerDrawerBlock()
        let (engine, _) = try makeEngine()
        let existing = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: pluginID, blockID: "grid.card", column: 0, row: 0
        ))

        guard case let .placed(_, page) = engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ) else {
            return XCTFail("当前页非空时应新开一页")
        }
        XCTAssertNotEqual(page, 0)
        XCTAssertEqual(engine.drawerPages, [0, page])
        // 普通块原地不动（添加路径不重排既有内容）。
        XCTAssertEqual(engine.drawerBlock(placementID: existing.placementID)?.page, 0)
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).count, 1)
    }

    func testAddPageBlockFailsWhenAllPagesAreBusy() throws {
        registerPageBlock()
        registerDrawerBlock()
        let (engine, _) = try makeEngine()
        // 9 页全部放上普通块：没有空页可占用，也不允许再新开页。
        _ = engine.placeDrawerBlock(pluginID: pluginID, blockID: "grid.card", column: 0, row: 0)
        while engine.canAddDrawerPage() {
            let page = engine.addDrawerPage(.right)
            _ = engine.placeDrawerBlock(
                pluginID: pluginID, blockID: "grid.card", column: 0, row: 0, page: page
            )
        }
        XCTAssertEqual(engine.drawerPages.count, LayoutModel.maxDrawerPageCount)

        XCTAssertEqual(
            engine.addPageBlock(pluginID: pluginID, blockID: "page.app", preferredPage: 0),
            .noPageCapacity
        )
        XCTAssertNil(placedPageBlock(engine))
    }

    func testAddPageBlockReportsUnavailableForNonPageBlock() throws {
        registerDrawerBlock()
        let (engine, _) = try makeEngine()
        XCTAssertEqual(
            engine.addPageBlock(pluginID: pluginID, blockID: "grid.card", preferredPage: 0),
            .unavailable
        )
        XCTAssertEqual(
            engine.addPageBlock(pluginID: pluginID, blockID: "missing", preferredPage: 0),
            .unavailable
        )
    }

    // MARK: 独占守卫

    func testExclusivePageRejectsEveryPlacementPath() throws {
        registerPageBlock()
        registerDrawerBlock()
        let (engine, _) = try makeEngine()
        let pageBlock = try XCTUnwrap(engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ).placedBlock(engine))
        XCTAssertTrue(engine.isExclusivePage(0))

        // 自动投放 / 指定落点都进不来。
        XCTAssertNil(engine.autoPlaceDrawerBlock(pluginID: pluginID, blockID: "grid.card", page: 0))
        XCTAssertNil(engine.placeDrawerBlock(
            pluginID: pluginID, blockID: "grid.card", column: 0, row: 0, page: 0
        ))
        XCTAssertEqual(engine.drawerBlocks(onPage: 0).map(\.placementID), [pageBlock.placementID])
    }

    func testCrossPageMoveCannotEnterOrLeaveExclusivePage() throws {
        registerPageBlock()
        registerDrawerBlock()
        let (engine, _) = try makeEngine()
        let pageBlock = try XCTUnwrap(engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ).placedBlock(engine))
        let normal = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: pluginID, blockID: "grid.card", column: 0, row: 0, page: 1
        ))

        // 普通块搬不进整页页；整页块也搬不走（归属由所在页决定）。
        XCTAssertNil(engine.moveDrawerBlockCrossPage(
            placementID: normal.placementID, toPage: 0, column: 0, row: 0
        ))
        XCTAssertNil(engine.moveDrawerBlockCrossPage(
            placementID: pageBlock.placementID, toPage: 1, column: 0, row: 0
        ))
        XCTAssertEqual(engine.drawerBlock(placementID: normal.placementID)?.page, 1)
        XCTAssertEqual(engine.drawerBlock(placementID: pageBlock.placementID)?.page, 0)
    }

    func testPageBlockIsNotMovableOnItsOwnPage() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()
        let pageBlock = try XCTUnwrap(engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ).placedBlock(engine))

        XCTAssertFalse(engine.moveDrawerBlock(
            placementID: pageBlock.placementID, toColumn: 2, toRow: 1
        ))
        XCTAssertFalse(engine.moveDrawerBlock(
            placementID: pageBlock.placementID, toColumn: 0, toRow: 3
        ))
        XCTAssertEqual(engine.drawerBlock(placementID: pageBlock.placementID)?.originRow, 0)
    }

    func testReorderSkipsExclusivePage() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()
        let pageBlock = try XCTUnwrap(engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ).placedBlock(engine))

        engine.reorderDrawerBlocks(page: 0)

        let after = try XCTUnwrap(engine.drawerBlock(placementID: pageBlock.placementID))
        XCTAssertEqual(after.originColumn, 0)
        XCTAssertEqual(after.originRow, 0)
        XCTAssertEqual(after, pageBlock)
    }

    // MARK: 几何归一（原点恒 0、列夹进容量）

    func testResizePageBlockAnchorsOriginAndClampsColumns() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()
        let pageBlock = try XCTUnwrap(engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ).placedBlock(engine))

        // 6 列在声明盒内（max 900pt = 6 格），但用户容量是 4 → 夹到 4。
        XCTAssertTrue(engine.resizeDrawerBlock(
            placementID: pageBlock.placementID, toColumns: 6, toRows: 4
        ))
        let resized = try XCTUnwrap(engine.drawerBlock(placementID: pageBlock.placementID))
        XCTAssertEqual(resized.originColumn, 0)
        XCTAssertEqual(resized.originRow, 0)
        XCTAssertEqual(resized.widthColumns, engine.effectiveMaxColumns())
        XCTAssertEqual(resized.heightRows, 4)

        // 低于最小列数同样被抬起来（整页恒铺满内容区）。
        XCTAssertTrue(engine.resizeDrawerBlock(
            placementID: pageBlock.placementID, toColumns: 2, toRows: 2
        ))
        let narrowed = try XCTUnwrap(engine.drawerBlock(placementID: pageBlock.placementID))
        XCTAssertEqual(narrowed.widthColumns, engine.minimumColumnCount())
    }

    func testResizePageBlockRejectsSpanOutsideDeclaredBox() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()
        let pageBlock = try XCTUnwrap(engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ).placedBlock(engine))

        // 10 列 / 9 行超出 max 档（900×600 → 6×5 格），提交闸门直接拒绝。
        XCTAssertFalse(engine.resizeDrawerBlock(
            placementID: pageBlock.placementID, toColumns: 10, toRows: 3
        ))
        XCTAssertFalse(engine.resizeDrawerBlock(
            placementID: pageBlock.placementID, toColumns: 4, toRows: 9
        ))
        XCTAssertEqual(engine.drawerBlock(placementID: pageBlock.placementID), pageBlock)
    }

    func testShrinkingUserCapacityReclampsPageBlock() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()
        let pageBlock = try XCTUnwrap(engine.addPageBlock(
            pluginID: pluginID, blockID: "page.app", preferredPage: 0
        ).placedBlock(engine))
        XCTAssertEqual(pageBlock.widthColumns, 4)

        engine.setUserMaxColumns(3)

        let after = try XCTUnwrap(engine.drawerBlock(placementID: pageBlock.placementID))
        XCTAssertEqual(after.widthColumns, 3)
        XCTAssertEqual(engine.effectiveMaxColumns(), 3)
    }

    // MARK: 持久化标记与非法共存收敛

    func testNormalizeWritesIsPageFlagFromDeclaration() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()
        // 手改 JSON 的等价场景：声明是整页块，但标记没跟上（或反之）。
        var model = engine.modelForTesting
        model.drawerBlocks = [PlacedBlock(
            pluginID: pluginID,
            blockID: "page.app",
            placementID: "hand-edited",
            page: 0,
            originColumn: 2,
            originRow: 3,
            widthColumns: 8,
            heightRows: 2,
            isPage: false
        )]
        engine.modelForTesting = model

        engine.normalizeExclusivePageState()

        let block = try XCTUnwrap(engine.drawerBlock(placementID: "hand-edited"))
        XCTAssertTrue(block.isPage, "声明为整页块时应回写持久化标记")
        XCTAssertEqual(block.originColumn, 0)
        XCTAssertEqual(block.originRow, 0)
        XCTAssertEqual(block.widthColumns, engine.effectiveMaxColumns())
    }

    func testUnresolvedPluginFallsBackToPersistedFlag() throws {
        // 解析器恒返回 nil（插件被停用 / 卸载）：独占守卫与占位视图只能靠标记。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExclusivePage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let engine = LayoutEngine(
            fileURL: directory.appendingPathComponent("layout.json"),
            blockResolver: { _, _ in nil }
        )
        var model = engine.modelForTesting
        model.drawerBlocks = [PlacedBlock(
            pluginID: pluginID,
            blockID: "page.app",
            placementID: "orphan",
            page: 0,
            originColumn: 0,
            originRow: 0,
            widthColumns: 4,
            heightRows: 3,
            isPage: true
        )]
        engine.modelForTesting = model

        let orphan = try XCTUnwrap(engine.drawerBlock(placementID: "orphan"))
        XCTAssertTrue(engine.isExclusivePageBlock(orphan))
        XCTAssertTrue(engine.isExclusivePage(0))
    }

    func testSeparateExclusivePageConflictsMovesPageBlockAside() throws {
        registerPageBlock()
        registerDrawerBlock()
        let (engine, _) = try makeEngine()
        var model = engine.modelForTesting
        model.drawerBlocks = [
            PlacedBlock(
                pluginID: pluginID, blockID: "page.app", placementID: "page",
                page: 0, originColumn: 0, originRow: 0,
                widthColumns: 4, heightRows: 3, isPage: true
            ),
            PlacedBlock(
                pluginID: pluginID, blockID: "grid.card", placementID: "normal",
                page: 0, originColumn: 0, originRow: 3,
                widthColumns: 2, heightRows: 1
            ),
        ]
        engine.modelForTesting = model

        XCTAssertEqual(
            LayoutEngine.exclusivePageConflictPages(
                model.drawerBlocks,
                isPageBlock: { $0.blockID == "page.app" }
            ),
            [0]
        )

        engine.separateExclusivePageConflicts()

        // 普通块原地不动；整页块自己搬到新页。
        XCTAssertEqual(engine.drawerBlock(placementID: "normal")?.page, 0)
        let moved = try XCTUnwrap(engine.drawerBlock(placementID: "page"))
        XCTAssertNotEqual(moved.page, 0)
        XCTAssertTrue(engine.drawerPages.contains(moved.page))
    }

    func testValidateReportsPageBlockSharing() throws {
        registerPageBlock()
        registerDrawerBlock()
        let (engine, _) = try makeEngine()
        var model = engine.modelForTesting
        model.drawerBlocks = [
            PlacedBlock(
                pluginID: pluginID, blockID: "page.app", placementID: "page",
                page: 0, originColumn: 0, originRow: 0,
                widthColumns: 4, heightRows: 3, isPage: true
            ),
            PlacedBlock(
                pluginID: pluginID, blockID: "grid.card", placementID: "normal",
                page: 0, originColumn: 0, originRow: 3,
                widthColumns: 2, heightRows: 1
            ),
        ]
        engine.modelForTesting = model

        XCTAssertTrue(
            engine.validate().contains(.pageBlockSharing(placementID: "page")),
            "同页共存必须被校验器点名（加载路径会把块搬走，报错用于手改数据）"
        )
    }

    func testCompactSlotRejectsPageBlockReference() throws {
        registerPageBlock()
        let (engine, _) = try makeEngine()
        var model = engine.modelForTesting
        model.compactSlots = [CompactSlotReference(
            pluginID: pluginID, blockID: "page.app", placementID: "slot"
        )]
        engine.modelForTesting = model

        XCTAssertTrue(
            engine.validate().contains(.compactBlockKindMismatch(placementID: "slot")),
            "整页块不该出现在紧凑槽位里"
        )
    }

    // MARK: 声明与种类语义

    func testPageBlockDeclarationRules() {
        let valid = NotchBlock(
            id: "p", displayName: "p", kind: .page,
            minSize: BlockPixelSize(width: 300, height: 240),
            maxSize: BlockPixelSize(width: 900, height: 600),
            recommendedSize: BlockPixelSize(width: 600, height: 360),
            makeView: { _ in AnyView(EmptyView()) }
        )
        XCTAssertNil(valid.validationError)

        // 三档缺失 / 下限不足 / 推荐档越界：与 drawer 同一套校验。
        let missingSize = NotchBlock(
            id: "p", displayName: "p", kind: .page,
            makeView: { _ in AnyView(EmptyView()) }
        )
        XCTAssertNotNil(missingSize.validationError)

        let tooSmall = NotchBlock(
            id: "p", displayName: "p", kind: .page,
            minSize: BlockPixelSize(width: 60, height: 40),
            maxSize: BlockPixelSize(width: 900, height: 600),
            recommendedSize: BlockPixelSize(width: 600, height: 360),
            makeView: { _ in AnyView(EmptyView()) }
        )
        XCTAssertNotNil(tooSmall.validationError)

        // interaction 是紧凑块专属：整页声明 .custom 即报错。
        let customInteraction = NotchBlock(
            id: "p", displayName: "p", kind: .page,
            minSize: BlockPixelSize(width: 300, height: 240),
            maxSize: BlockPixelSize(width: 900, height: 600),
            recommendedSize: BlockPixelSize(width: 600, height: 360),
            interaction: .custom,
            makeView: { _ in AnyView(EmptyView()) }
        )
        XCTAssertNotNil(customInteraction.validationError)
    }

    func testBlockKindSemantics() {
        XCTAssertFalse(BlockKind.compact.occupiesDrawerGrid)
        XCTAssertTrue(BlockKind.drawer.occupiesDrawerGrid)
        XCTAssertTrue(BlockKind.page.occupiesDrawerGrid)

        XCTAssertFalse(BlockKind.compact.isExclusivePage)
        XCTAssertFalse(BlockKind.drawer.isExclusivePage)
        XCTAssertTrue(BlockKind.page.isExclusivePage)
    }
}

// MARK: - 添加结果便利解包

@MainActor
private extension ExclusivePageAddOutcome {
    /// `.placed` 的放置实例（从引擎取回），其余结果返回 nil。
    func placedBlock(_ engine: LayoutEngine) -> PlacedBlock? {
        guard case .placed = self else { return nil }
        return engine.drawerBlocks.first { $0.isPage }
    }
}
