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

    func testDefaultModelHasEmptyCompactSlotsAndFourColumns() throws {
        let (engine, directory, _) = try makeEngine()
        XCTAssertTrue(engine.compactSlots.isEmpty, "紧凑槽位不固定：默认无图标，宽度为 0 → 随添加伸缩")
        XCTAssertEqual(engine.userMaxColumns, 4)
        XCTAssertTrue(engine.enabledPluginIDs.isEmpty)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 紧凑槽位（文档 §5.2：数组长度即图标数，宽度随其动态伸缩）

    func testCompactSlotAddSwapRemove() throws {
        register(blockID: "a.compact", kind: .compact)
        register(blockID: "b.compact", kind: .compact)
        let (engine, directory, _) = try makeEngine()

        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "a.compact"))
        XCTAssertEqual(engine.compactSlot(at: 0)?.blockID, "a.compact")

        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "b.compact"))
        XCTAssertEqual(engine.compactSlot(at: 1)?.blockID, "b.compact")
        XCTAssertEqual(engine.compactSlots.count, 2)

        engine.swapCompactSlots(0, 1)
        XCTAssertEqual(engine.compactSlot(at: 0)?.blockID, "b.compact")
        XCTAssertEqual(engine.compactSlot(at: 1)?.blockID, "a.compact")

        // 移除闭合空隙：删除索引 0 后原索引 1 前移到 0（带宽随之收缩）。
        engine.setCompactSlot(0, to: nil)
        XCTAssertEqual(engine.compactSlots.count, 1)
        XCTAssertEqual(engine.compactSlot(at: 0)?.blockID, "a.compact")
        XCTAssertNil(engine.compactSlot(at: 1))
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddingCompactBlockGrowsUnbounded() throws {
        register(blockID: "notes.compact", kind: .compact)
        let (engine, directory, _) = try makeEngine()
        for _ in 0..<5 {
            XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "notes.compact"))
        }
        XCTAssertEqual(engine.compactSlots.count, 5)
        XCTAssertTrue(engine.compactSlots.allSatisfy { $0 != nil })
        try? FileManager.default.removeItem(at: directory)
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
        // 空默认布局也要能重建（紧凑槽位不固定：空数组）。
        let model = try JSONDecoder().decode(LayoutModel.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(model.compactSlots.count, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadsLegacyFixedThreeSlotLayoutEatingNulls() throws {
        // 旧版固定 3 槽（含 null 占位）的 layout.json：加载时剥除空槽、闭合
        // 空隙，数组长度变为实际图标数（带宽随其伸缩）。
        register(blockID: "a", kind: .compact)
        register(blockID: "c", kind: .compact)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-legacy-compact-\(UUID().uuidString).json")
        let legacy = """
        {
          "schemaVersion": 1,
          "maxColumns": 4,
          "compactSlots": [
            {"pluginID": "com.test.plugin", "blockID": "a", "placementID": "A"},
            null,
            {"pluginID": "com.test.plugin", "blockID": "c", "placementID": "C"}
          ],
          "drawerBlocks": [],
          "enabledPluginIDs": []
        }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let engine = LayoutEngine(fileURL: url, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        XCTAssertTrue(engine.didLoadFromDisk)
        XCTAssertEqual(engine.compactSlots.count, 2, "旧版空槽 null 应在加载时剥除")
        XCTAssertEqual(engine.compactSlot(at: 0)?.blockID, "a")
        XCTAssertEqual(engine.compactSlot(at: 1)?.blockID, "c")
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: url)
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

    // MARK: 编辑模式契约：列双向扩大（左扩）+ 行仅向下

    /// 向左拖出：格网自动向左扩大（originColumn 为负），面板跨度随之增加；
    /// 提交后左扩保持，行压实只向下（不影响列）。
    func testDragLeftOutExpandsGridLeft() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 1, height: 1)
        placeRaw(engine, id: "b", column: 1, row: 0, width: 1, height: 1)

        let preview = engine.previewArrangement(moving: "a", toColumn: -1, toRow: 0)
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: -1, row: 0))
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 1, row: 0))
        // 预览期间按并集跨度（-1..2 = 3 列）计算面板宽度与左缘偏移。
        XCTAssertEqual(engine.previewOccupiedColumns(origins: preview), 3)
        XCTAssertEqual(engine.previewColumnRange(origins: preview).min, -1)
        XCTAssertEqual(engine.previewColumnRange(origins: preview).max, 2)
        XCTAssertEqual(engine.previewBottomRow(origins: preview), 1)

        // 所见即所得：提交后 a 留在 -1，空列 0 由 b 左移闭合（不留空列）。
        XCTAssertTrue(engine.commitArrangement(preview))
        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originColumn, -1)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 0)
        XCTAssertEqual(engine.occupiedColumns(), 2)
        XCTAssertEqual(engine.gridLeftColumn(), -1)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 左扩受容量约束：其他块已占满容量时，向左拖出不会让总跨度超屏。
    func testDragLeftExpansionRespectsCapacity() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        engine.updateScreenConstraint(width: 700) // 容量 4
        for col in 0..<4 {
            placeRaw(engine, id: "c\(col)", column: col, row: 0, width: 1, height: 1)
        }

        let preview = engine.previewArrangement(moving: "c0", toColumn: -1, toRow: 0)
        // 跨度上限 4：-1 越界，clamp 回 0（其余块原位）。
        XCTAssertEqual(preview["c0"], LayoutEngine.GridOrigin(column: 0, row: 0))
        XCTAssertEqual(engine.previewOccupiedColumns(origins: preview), 4)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 组合预览 API（推挤 + 离线压实）与提交逐块严格相等，含左扩场景：
    /// 预览即最终布局，松手零二次位移。
    func testPreviewCommittedArrangementMatchesCommitWithLeftExpansion() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 1, height: 1)
        placeRaw(engine, id: "b", column: 1, row: 0, width: 1, height: 1)

        let preview = engine.previewCommittedArrangement(moving: "a", toColumn: -1, toRow: 0)
        // 左扩内建：落点列为负；空列 0 由压实闭合（b 左移，与提交一致）。
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: -1, row: 0))
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 0))

        // 提交侧压实是幂等兜底：预览（已压实）与提交结果逐块严格相等。
        _ = engine.commitArrangement(preview)
        for block in engine.drawerBlocks {
            XCTAssertEqual(
                LayoutEngine.GridOrigin(column: block.originColumn, row: block.originRow),
                preview[block.placementID],
                "块 \(block.placementID) 的预览与提交不一致"
            )
        }
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 压实纯函数不得触碰实时模型：预览链路在临时副本上离线压实，
    /// `model.drawerBlocks` 必须逐位不变。
    func testCompactionPureFunctionsDoNotMutateModel() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 1, height: 1)
        placeRaw(engine, id: "b", column: 1, row: 2, width: 1, height: 1)
        let before = engine.model.drawerBlocks

        // 留有空洞（空行 1、空列边界外）的副本：压实纯函数返回新数组，
        // 引擎模型不受影响。
        var copy = engine.model.drawerBlocks
        copy[1].originColumn = -2 // 负列空洞，向 0 收拢分支也要覆盖
        let rowsResult = LayoutEngine.compactEmptyRows(copy)
        let columnsResult = LayoutEngine.compactEmptyColumns(copy)
        XCTAssertTrue(rowsResult.changed, "副本存在空行，压实应报告变化")
        XCTAssertTrue(columnsResult.changed, "副本存在负列空洞，压实应报告变化")
        XCTAssertEqual(
            engine.model.drawerBlocks.map { "\($0.placementID):\($0.originColumn),\($0.originRow)" },
            before.map { "\($0.placementID):\($0.originColumn),\($0.originRow)" },
            "压实纯函数不得修改实时布局模型"
        )
        try? FileManager.default.removeItem(at: directory)
    }

    /// 左侧有空列时允许左扩；左移后的负列空洞向 0 收拢（左侧块右移）。
    func testLeftGapCompactsTowardZero() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: -2, row: 0, width: 1, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 0, width: 1, height: 1)

        // b 让出列 0（下移一行）：列 -1 出现空洞 → 左侧块 a 右移闭合。
        XCTAssertTrue(engine.moveDrawerBlock(placementID: "b", toColumn: 0, toRow: 1))
        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originColumn, -1)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 0)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 左扩布局上再自动添加块：落位后压实，不留下负列空洞。
    func testAutoPlaceAfterLeftExpansionClosesGap() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: -2, row: 0, width: 1, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 0, width: 1, height: 1)

        // 列 -1 空洞：autoPlace 落位首个空位后压实，空洞由 a 右移闭合。
        let added = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "cell"))
        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originColumn, -1)
        XCTAssertEqual(engine.drawerBlock(placementID: added.placementID)?.originColumn, 1)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 左扩块的缩放：原点不动（行仅向下、列单握把右扩），仅按容量收紧。
    func testResizeKeepsLeftOriginWhenExpanding() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: -1, row: 0, width: 1, height: 1)

        XCTAssertTrue(engine.resizeDrawerBlock(placementID: "a", toColumns: 2, toRows: 1))
        let resized = engine.drawerBlock(placementID: "a")
        XCTAssertEqual(resized?.originColumn, -1)
        XCTAssertEqual(resized?.widthColumns, 2)
        XCTAssertEqual(resized?.originRow, 0, "行始终顶边锚定，只向下扩大")
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 负列 origin 是合法布局（不再判定越界），只有合并后跨度过容量才越界。
    func testValidateAllowsNegativeOriginColumns() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: -1, row: 0, width: 1, height: 1)
        XCTAssertTrue(engine.validate().isEmpty)

        // 跨度过容量（a 在 -1 + b 宽 4 从列 1 起：跨度 6 > 容量 4）：仍应报越界。
        placeRaw(engine, id: "b", column: 1, row: 1, width: 4, height: 1)
        let issues = engine.validate()
        XCTAssertTrue(issues.contains { if case .outOfBounds = $0 { return true }; return false })
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 拖拽方向对称性：下移跨顶缘可交换（插入序安放）

    /// 核心钉子：向下拖跨过下方相邻块顶缘（目标行 == 下方块 originRow）
    /// 即触发交换——旧语义里被拖块恒占阅读序首位，下移后压实拉回原状、
    /// 永远无法交换。
    func testDragDownPastTopEdgeSwaps() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "x", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "a", column: 0, row: 1, width: 2, height: 2)
        placeRaw(engine, id: "b", column: 0, row: 3, width: 2, height: 2)

        // a 下移 2 格：目标行 3 == b 的顶缘。
        let preview = engine.previewCommittedArrangement(moving: "a", toColumn: 0, toRow: 3)
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: 0, row: 3), "被拖块落到下方块原位之下")
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 1), "下方块保位并整体上移")
        XCTAssertEqual(preview["x"], LayoutEngine.GridOrigin(column: 0, row: 0))

        // 预览即提交：逐块严格相等。
        _ = engine.commitArrangement(preview)
        for block in engine.drawerBlocks {
            XCTAssertEqual(
                LayoutEngine.GridOrigin(column: block.originColumn, row: block.originRow),
                preview[block.placementID],
                "块 \(block.placementID) 的预览与提交不一致"
            )
        }
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 下移未跨过下方块顶缘（目标行 < 下方块 originRow）：压实拉回原状，
    /// 布局逐块不变——零反馈即「未跨越」，符合直觉。
    func testDragDownBelowTopEdgeKeepsLayout() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "x", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "a", column: 0, row: 1, width: 2, height: 2)
        placeRaw(engine, id: "b", column: 0, row: 3, width: 2, height: 2)

        // a 下移 1 格：目标行 2 < b 的顶缘 3。
        let preview = engine.previewCommittedArrangement(moving: "a", toColumn: 0, toRow: 2)
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: 0, row: 1))
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 3))
        XCTAssertEqual(preview["x"], LayoutEngine.GridOrigin(column: 0, row: 0))
        try? FileManager.default.removeItem(at: directory)
    }

    /// 上移对称性对照：向上 1 格跨过上方块顶缘即交换（旧语义已如此，
    /// 插入序安放不得改变它）。
    func testDragUpSwapsSymmetrically() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "x", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "a", column: 0, row: 1, width: 2, height: 2)
        placeRaw(engine, id: "b", column: 0, row: 3, width: 2, height: 2)

        // b 上移 1 格：目标行 2 落入 a 的包围盒（a 底行 2）。
        let preview = engine.previewCommittedArrangement(moving: "b", toColumn: 0, toRow: 2)
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 1), "b 抢占 a 上方槽位")
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: 0, row: 3), "a 被挤到 b 下方")
        XCTAssertEqual(preview["x"], LayoutEngine.GridOrigin(column: 0, row: 0))
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 斜向移动（行变 + 列变）：安放顺序只由目标行决定，列走 clamp。
    func testDiagonalMoveSwapsByRow() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 1, width: 2, height: 2)
        placeRaw(engine, id: "b", column: 0, row: 3, width: 2, height: 2)
        placeRaw(engine, id: "c", column: 2, row: 1, width: 2, height: 2)

        // a 斜移到 (2, 3)：跨过 b 顶缘，行方向交换生效、列落到 c 下方。
        let preview = engine.previewCommittedArrangement(moving: "a", toColumn: 2, toRow: 3)
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: 2, row: 2))
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 2))
        XCTAssertEqual(preview["c"], LayoutEngine.GridOrigin(column: 2, row: 0))
        try? FileManager.default.removeItem(at: directory)
    }

    /// 2x2 满排布：宽块下移跨过下方整块顶缘，插入到其后（落到本列底部），
    /// 其余块不动。
    func testWideBlockDownwardInsertBetweenRows() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "tl", column: 0, row: 0, width: 2, height: 2)
        placeRaw(engine, id: "tr", column: 2, row: 0, width: 2, height: 2)
        placeRaw(engine, id: "bl", column: 0, row: 2, width: 2, height: 2)
        placeRaw(engine, id: "br", column: 2, row: 2, width: 2, height: 2)

        // tl 下移 2 格：目标行 2 == bl 顶缘 → tl 落到左列底部，tr/bl/br 不动。
        let preview = engine.previewCommittedArrangement(moving: "tl", toColumn: 0, toRow: 2)
        XCTAssertEqual(preview["tl"], LayoutEngine.GridOrigin(column: 0, row: 4))
        XCTAssertEqual(preview["tr"], LayoutEngine.GridOrigin(column: 2, row: 0))
        XCTAssertEqual(preview["bl"], LayoutEngine.GridOrigin(column: 0, row: 2))
        XCTAssertEqual(preview["br"], LayoutEngine.GridOrigin(column: 2, row: 2))
        try? FileManager.default.removeItem(at: directory)
    }

    /// 左扩 + 下移组合：目标列可为负（左扩）、目标行跨过下方块顶缘（交换），
    /// 压实闭合空洞后无负列残留。
    func testDragDownWithLeftExpansion() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 2)
        placeRaw(engine, id: "b", column: 0, row: 2, width: 2, height: 2)

        // a 斜移到 (-2, 2)：跨过 b 顶缘 + 向左拖出两列。
        let preview = engine.previewCommittedArrangement(moving: "a", toColumn: -2, toRow: 2)
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: -2, row: 0))
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 0))

        _ = engine.commitArrangement(preview)
        XCTAssertEqual(engine.occupiedColumns(), 4)
        XCTAssertTrue(engine.validate().isEmpty)
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