import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

@MainActor
final class LayoutEngineTests: XCTestCase {
    private var registry: [String: NotchBlock] = [:]

    private func makeEngine(
        userMaxColumns: Int = 4,
        directory: URL? = nil
    ) throws -> (LayoutEngine, URL, URL) {
        let directory = directory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("LayoutEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("layout.json")
        let engine = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        engine.setUserMaxColumns(userMaxColumns)
        return (engine, directory, fileURL)
    }

    private func register(
        pluginID: String = "com.test.plugin",
        blockID: String,
        kind: BlockKind,
        sizes: Set<BlockSize> = [],
        defaultSize: BlockSize? = nil
    ) {
        registry["\(pluginID)|\(blockID)"] = NotchBlock(
            id: blockID,
            displayName: blockID,
            kind: kind,
            supportedSizes: sizes,
            defaultSize: defaultSize,
            makeView: { _ in AnyView(EmptyView()) }
        )
    }

    // MARK: 默认模型（文档 §5.4）

    func testDefaultModelHasThreeEmptySlotsAndFourColumns() throws {
        let (engine, directory, _) = try makeEngine()
        XCTAssertEqual(engine.compactSlots.count, 3)
        XCTAssertTrue(engine.compactSlots.allSatisfy { $0 == nil })
        XCTAssertEqual(engine.userMaxColumns, 4)
        XCTAssertTrue(engine.enabledPluginIDs.isEmpty)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 紧凑槽位（文档 §5.2）

    func testCompactSlotAddSwapRemove() throws {
        register(blockID: "notes.compact", kind: .compact)
        let (engine, directory, _) = try makeEngine()

        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "notes.compact"))
        XCTAssertEqual(engine.compactSlot(at: 0)?.blockID, "notes.compact")

        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "notes.compact"))
        XCTAssertEqual(engine.compactSlot(at: 1)?.blockID, "notes.compact")

        engine.swapCompactSlots(0, 1)
        XCTAssertNotNil(engine.compactSlot(at: 0))
        XCTAssertEqual(engine.compactSlot(at: 1)?.blockID, "notes.compact")

        engine.setCompactSlot(0, to: nil)
        XCTAssertNil(engine.compactSlot(at: 0))
    }

    func testAddingCompactBlockFailsWhenAllSlotsAreFilled() throws {
        register(blockID: "notes.compact", kind: .compact)
        let (engine, directory, _) = try makeEngine()
        for _ in 0..<3 {
            XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "notes.compact"))
        }
        XCTAssertFalse(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "notes.compact"))
    }

    // MARK: 抽屉网格放置（文档 §5.3）

    func testAutoPlaceUsesDefaultSizeAndFirstAvailablePosition() throws {
        register(blockID: "notes.notebook", kind: .drawer, sizes: [.large, .extraLarge], defaultSize: .extraLarge)
        register(blockID: "shelf", kind: .drawer, sizes: [.medium, .large], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 900)

        let placed = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "notes.notebook"))
        XCTAssertEqual(placed.originColumn, 0)
        XCTAssertEqual(placed.originRow, 0)
        XCTAssertEqual(placed.widthColumns, 4)
        XCTAssertEqual(placed.heightRows, 2)

        let second = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "shelf"))
        // 4 列放不下 2 格宽 → 换行到下一行（文档：超出最大列数自动换行）。
        XCTAssertEqual(second.originColumn, 0)
        XCTAssertEqual(second.originRow, 2)

        XCTAssertTrue(engine.validate().isEmpty)
    }

    func testEffectiveMaxColumnsIsConstrainedByScreenWidth() throws {
        register(blockID: "shelf", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, _, _) = try makeEngine(userMaxColumns: 8)
        // 屏幕宽度 700：可容纳 floor((700 - 32 + 12) / 162) = 4 列
        engine.updateScreenConstraint(width: 700)
        XCTAssertEqual(engine.effectiveMaxColumns(), 4)

        engine.updateScreenConstraint(width: 2000)
        XCTAssertEqual(engine.effectiveMaxColumns(), 8)
    }

    // MARK: 移动与缩放（文档 §5.5）

    func testMoveBlockResolvesOverlapToNearestFreeSpot() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 700)

        let a = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "a"))
        let b = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "b"))

        // 把 b 移到 a 的位置 (0,0)：被占用 → 就近放置 (0,1) 或 (1,0)。
        XCTAssertTrue(engine.moveDrawerBlock(placementID: b.placementID, toColumn: 0, toRow: 0))
        let moved = engine.drawerBlock(placementID: b.placementID)
        XCTAssertNotEqual(moved?.originColumn, a.originColumn)
        XCTAssertTrue(engine.validate().isEmpty)
    }

    func testResizeOnlySupportsDeclaredSizes() throws {
        register(blockID: "notes", kind: .drawer, sizes: [.small, .medium], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 700)

        let placed = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "notes"))
        XCTAssertTrue(engine.resizeDrawerBlock(placementID: placed.placementID, to: .medium))
        XCTAssertEqual(engine.drawerBlock(placementID: placed.placementID)?.widthColumns, 2)

        XCTAssertFalse(engine.resizeDrawerBlock(placementID: placed.placementID, to: .extraLarge))
        XCTAssertFalse(engine.resizeDrawerBlock(placementID: "missing", to: .medium))
    }

    func testRemoveDrawerBlock() throws {
        register(blockID: "shelf", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        let placed = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "shelf"))
        engine.removeDrawerBlock(placementID: placed.placementID)
        XCTAssertTrue(engine.drawerBlocks.isEmpty)
    }

    // MARK: 一键重排（编辑模式）

    func testReorderPacksGapsInReadingOrder() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "c", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 700)

        let a = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "a"))
        let b = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "b"))
        let c = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "c"))

        // 人为制造空洞：b 移到右上角，a 移到远处，留下大片空白。
        XCTAssertTrue(engine.moveDrawerBlock(placementID: b.placementID, toColumn: 3, toRow: 0))
        XCTAssertTrue(engine.moveDrawerBlock(placementID: a.placementID, toColumn: 2, toRow: 4))

        // 阅读顺序（行优先再按列）：c 在 (2,0) 先于 b 在 (3,0)，再轮到 a 在 (2,4)。
        engine.reorderDrawerBlocks()

        let reorderedC = engine.drawerBlock(placementID: c.placementID)
        let reorderedB = engine.drawerBlock(placementID: b.placementID)
        let reorderedA = engine.drawerBlock(placementID: a.placementID)

        // 重排后紧密无洞：按阅读优先级依次回到行首，后续块紧贴已占区域。
        XCTAssertEqual(reorderedC?.originColumn, 0)
        XCTAssertEqual(reorderedC?.originRow, 0)
        XCTAssertEqual(reorderedB?.originColumn, 1)
        XCTAssertEqual(reorderedB?.originRow, 0)
        XCTAssertEqual(reorderedA?.originColumn, 2)
        XCTAssertEqual(reorderedA?.originRow, 0)

        // 身份与跨度不变，布局无重叠。
        XCTAssertTrue(engine.validate().isEmpty)
    }

    func testReorderKeepsSpanAndIdentity() throws {
        register(blockID: "wide", kind: .drawer, sizes: [.large], defaultSize: .large)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 700)

        let wide = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "wide"))
        XCTAssertTrue(engine.moveDrawerBlock(placementID: wide.placementID, toColumn: 0, toRow: 3))

        engine.reorderDrawerBlocks()

        let moved = engine.drawerBlock(placementID: wide.placementID)
        XCTAssertEqual(moved?.placementID, wide.placementID)
        XCTAssertEqual(moved?.widthColumns, wide.widthColumns)
        XCTAssertEqual(moved?.heightRows, wide.heightRows)
        XCTAssertEqual(moved?.originColumn, 0)
        XCTAssertEqual(moved?.originRow, 0)
    }

    // MARK: 校验（文档 §5.4）

    func testValidateDetectsOverlaps() throws {
        register(blockID: "a", kind: .drawer, sizes: [.large], defaultSize: .large)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 700)

        let first = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "a"))
        let second = PlacedBlock(
            pluginID: first.pluginID,
            blockID: first.blockID,
            placementID: "second",
            originColumn: first.originColumn,
            originRow: first.originRow,
            widthColumns: first.widthColumns,
            heightRows: first.heightRows
        )
        engine.modelForTesting.drawerBlocks.append(second)

        let issues = engine.validate()
        XCTAssertTrue(issues.contains { if case .overlap = $0 { return true }; return false })
    }

    func testValidateFlagsUnknownBlocksAndKindMismatch() throws {
        register(blockID: "good", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()

        let placed = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "good"))
        let replaced = PlacedBlock(
            pluginID: placed.pluginID,
            blockID: "vanished",
            placementID: placed.placementID,
            originColumn: placed.originColumn,
            originRow: placed.originRow,
            widthColumns: placed.widthColumns,
            heightRows: placed.heightRows
        )
        engine.modelForTesting.drawerBlocks = [replaced]

        let issues = engine.validate()
        XCTAssertTrue(issues.contains { if case .unknownBlock = $0 { return true }; return false })
    }

    // MARK: 持久化（文档 §5.4）

    func testLayoutPersistsAcrossEngines() throws {
        register(blockID: "notes.compact", kind: .compact)
        register(blockID: "shelf", kind: .drawer, sizes: [.medium, .large], defaultSize: .large)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 900)

        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "notes.compact"))
        let placed = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "shelf"))
        engine.syncEnabledPluginIDs(["com.test.plugin"])
        engine.setUserMaxColumns(6)

        // 直接以同一文件重建引擎，验证持久化内容（不复写 maxColumns）。
        let restored = LayoutEngine(fileURL: directory.appendingPathComponent("layout.json"), blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        XCTAssertEqual(restored.userMaxColumns, 6)
        XCTAssertEqual(restored.enabledPluginIDs, ["com.test.plugin"])
        XCTAssertEqual(restored.compactSlot(at: 0)?.blockID, "notes.compact")
        XCTAssertEqual(restored.drawerBlocks, [placed])

        // 首次创建标记：已有文件则 didLoadFromDisk 为 true。
        XCTAssertTrue(restored.didLoadFromDisk)
    }

    func testFreshEngineCreatesLayoutFile() throws {
        let (engine, directory, fileURL) = try makeEngine()
        XCTAssertFalse(engine.didLoadFromDisk)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        // 空默认布局也要能重建。
        let model = try JSONDecoder().decode(LayoutModel.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(model.compactSlots.count, 3)
    }

    // MARK: 尺寸模型

    func testBlockSizeGridSpansMatchDocumentation() {
        XCTAssertEqual(BlockSize.small.gridSpan.columns, 1)
        XCTAssertEqual(BlockSize.small.gridSpan.rows, 1)
        XCTAssertEqual(BlockSize.medium.gridSpan.columns, 2)
        XCTAssertEqual(BlockSize.wide.gridSpan.columns, 4)
        XCTAssertEqual(BlockSize.large.gridSpan.rows, 2)
        XCTAssertEqual(BlockSize.extraLarge.gridSpan.columns, 4)
        XCTAssertEqual(BlockSize.extraLarge.gridSpan.rows, 2)
    }

    func testNotchBlockValidationRules() {
        // 紧凑块禁止声明尺寸。
        XCTAssertNotNil(NotchBlock(
            id: "c", displayName: "c", kind: .compact,
            supportedSizes: [.small],
            makeView: { _ in AnyView(EmptyView()) }
        ).validationError)

        // 抽屉块必须声明 supportedSizes 且包含 defaultSize。
        let validDrawer = NotchBlock(
            id: "d", displayName: "d", kind: .drawer,
            supportedSizes: [.medium, .large], defaultSize: .large,
            makeView: { _ in AnyView(EmptyView()) }
        )
        XCTAssertNil(validDrawer.validationError)

        XCTAssertNotNil(NotchBlock(
            id: "d2", displayName: "d2", kind: .drawer,
            supportedSizes: [],
            makeView: { _ in AnyView(EmptyView()) }
        ).validationError)

        XCTAssertNotNil(NotchBlock(
            id: "d3", displayName: "d3", kind: .drawer,
            supportedSizes: [.medium], defaultSize: .large,
            makeView: { _ in AnyView(EmptyView()) }
        ).validationError)
    }

    // MARK: 编辑模式契约：无空行 + 缩放推挤（面板按需增减高的布局基础）

    /// 直接写入精确几何（绕过 autoPlace 的首空位扫描）。
    /// 所有块共用已注册的 blockID "cell"（跨度由各测试的 register 决定），
    /// 传入的 `id` 仅作 placementID。
    private func placeRaw(
        _ engine: LayoutEngine,
        id: String,
        column: Int,
        row: Int,
        width: Int,
        height: Int
    ) {
        var model = engine.modelForTesting
        model.drawerBlocks.append(
            PlacedBlock(
                pluginID: "com.test.plugin",
                blockID: "cell",
                placementID: id,
                originColumn: column,
                originRow: row,
                widthColumns: width,
                heightRows: height
            )
        )
        engine.modelForTesting = model
    }

    private func occupiedRows(_ engine: LayoutEngine) -> Set<Int> {
        Set(
            engine.drawerBlocks.flatMap { block in
                (block.originRow..<block.originRow + block.heightRows)
            }
        )
    }

    func testRemoveBlockClosesEmptyRowBelowShiftsUp() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.wide], defaultSize: .wide)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 4, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 1, width: 4, height: 1)
        placeRaw(engine, id: "c", column: 0, row: 2, width: 4, height: 1)

        engine.removeDrawerBlock(placementID: "b")

        // 行 1 空置 → 下方整体上移一行，不留空行。
        XCTAssertEqual(engine.drawerBlock(placementID: "c")?.originRow, 1)
        XCTAssertEqual(occupiedRows(engine), [0, 1])
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testPartialRowGapIsPreserved() throws {
        // 行内部分留白保留：同行的另一块仍在 → 该行不空 → 下方不动。
        register(blockID: "cell", kind: .drawer, sizes: [.medium, .wide], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 2, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "c", column: 0, row: 1, width: 4, height: 1)

        engine.removeDrawerBlock(placementID: "a")

        XCTAssertEqual(engine.drawerBlock(placementID: "c")?.originRow, 1)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 2)
        try? FileManager.default.removeItem(at: directory)
    }

    func testMoveAwayClosesVacatedRows() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.wide], defaultSize: .wide)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 4, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 1, width: 4, height: 1)
        placeRaw(engine, id: "c", column: 0, row: 2, width: 4, height: 1)

        // 把 a 拖到很下方：原行空出 → 下方上移压实，a 也随之回到堆栈底部。
        XCTAssertTrue(engine.moveDrawerBlock(placementID: "a", toColumn: 0, toRow: 8))
        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originRow, 2)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originRow, 0)
        XCTAssertEqual(engine.drawerBlock(placementID: "c")?.originRow, 1)
        XCTAssertEqual(occupiedRows(engine), [0, 1, 2])
        try? FileManager.default.removeItem(at: directory)
    }

    func testResizeGrowPushesBlocksBelowInsteadOfFailing() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium, .large], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 1, width: 2, height: 1)
        placeRaw(engine, id: "c", column: 0, row: 2, width: 2, height: 1)

        // 扩大与下方重叠：不再回退失败，而是下方块被推挤下移。
        XCTAssertTrue(engine.resizeDrawerBlock(placementID: "a", toColumns: 2, toRows: 2))
        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.heightRows, 2)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originRow, 2)
        XCTAssertEqual(engine.drawerBlock(placementID: "c")?.originRow, 3)
        XCTAssertTrue(engine.validate().isEmpty)
        // 面板高度依据：行数 3 → 4（按需增高）。
        let rows = engine.drawerBlocks.map { $0.originRow + $0.heightRows }.max() ?? 0
        XCTAssertEqual(rows, 4)
        try? FileManager.default.removeItem(at: directory)
    }

    func testResizeShrinkCompactsFreedRows() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium, .large], defaultSize: .large)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 2)
        placeRaw(engine, id: "b", column: 0, row: 2, width: 2, height: 1)

        // 缩小腾出的行被压实：b 上移一行，总行数 3 → 2（面板收缩）。
        XCTAssertTrue(engine.resizeDrawerBlock(placementID: "a", toColumns: 2, toRows: 1))
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originRow, 1)
        XCTAssertEqual(occupiedRows(engine), [0, 1])
        try? FileManager.default.removeItem(at: directory)
    }

    func testResizePreviewMatchesCommitAndGrowsWindowRows() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium, .large], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 1, width: 2, height: 1)

        let preview = engine.previewArrangement(resizing: "a", toColumns: 2, toRows: 2)
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: 0, row: 0))
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 2))
        // 预览期间面板按最低占用行临时增高。
        XCTAssertEqual(engine.previewBottomRow(origins: preview), 3)

        // 所见即所得：提交结果与预览一致。
        XCTAssertTrue(engine.resizeDrawerBlock(placementID: "a", toColumns: 2, toRows: 2))
        for block in engine.drawerBlocks {
            XCTAssertEqual(
                LayoutEngine.GridOrigin(column: block.originColumn, row: block.originRow),
                preview[block.placementID]
            )
        }

        // 不支持的跨度预览返回空。
        XCTAssertTrue(engine.previewArrangement(resizing: "a", toColumns: 3, toRows: 3).isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testPreviewBottomRowAccountsForBottomBlockGrowth() throws {
        // 最底层块长高：没有推挤（origins 全员原位），面板行数只能来自
        // 被缩放块的新行数——必须显式传入 resized 才会增高。
        register(blockID: "cell", kind: .drawer, sizes: [.medium, .large], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 1, width: 2, height: 1)

        let preview = engine.previewArrangement(resizing: "b", toColumns: 2, toRows: 2)
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 1))
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: 0, row: 0))
        // 不带 resized：按模型旧 heightRows 计算，底行不变（历史缺陷）。
        XCTAssertEqual(engine.previewBottomRow(origins: preview), 2)
        // 带 resized：底行计入新高度，面板按需增高一格。
        XCTAssertEqual(engine.previewBottomRow(origins: preview, resized: ("b", 2)), 3)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func layoutIssueKind(_ issue: LayoutEngine.LayoutIssue) -> String {
    switch issue {
    case .overlap: return "overlap"
    case .outOfBounds: return "outOfBounds"
    case .unknownBlock: return "unknownBlock"
    case .sizeNotSupported: return "sizeNotSupported"
    default: return "other"
    }
}