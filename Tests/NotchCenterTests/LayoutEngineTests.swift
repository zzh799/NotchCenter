import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

@MainActor
final class LayoutEngineTests: XCTestCase {
    private var registry: [String: NotchBlock] = [:]

    private func makeEngine(
        userMaxColumns: Int = 4,
        minRows: Int = 1,
        minColumns: Int = 1,
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
        // 默认关掉最小行/列下限：本文件多数用例断言的是**实占**跨度/行号，留白夹紧会抹平。
        // 下限 1 不在可选项范围内（生产 setter 设不出来），只能经内部写入入口给。
        var model = engine.modelForTesting
        model.minRows = minRows
        model.minColumns = minColumns
        engine.modelForTesting = model
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

    func testScreenColumnCapacityIsIndependentOfUserMaxColumns() throws {
        register(blockID: "shelf", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 4)
        // 默认屏（1440）容量 8：容量分量不受用户最大列数约束——抽屉窗口
        // 的固定满宽按它取，列数配置变化不改窗口 frame（spring 无裁剪）。
        XCTAssertEqual(engine.screenColumnCapacity(), 8)
        XCTAssertEqual(engine.effectiveMaxColumns(), 4)
        engine.setUserMaxColumns(2)
        XCTAssertEqual(engine.screenColumnCapacity(), 8)
        XCTAssertEqual(engine.effectiveMaxColumns(), 2)

        engine.updateScreenConstraint(width: 700)
        XCTAssertEqual(engine.screenColumnCapacity(), 4)
        XCTAssertEqual(engine.effectiveMaxColumns(), 2)
        try? FileManager.default.removeItem(at: directory)
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
        height: Int,
        page: Int = 0
    ) {
        var model = engine.modelForTesting
        model.drawerBlocks.append(
            PlacedBlock(
                pluginID: "com.test.plugin",
                blockID: "cell",
                placementID: id,
                page: page,
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

        // 预览必须覆盖全体块：漏一块，那一块就会在缩放期间停在旧位置。
        XCTAssertEqual(
            Set(preview.keys),
            Set(engine.drawerBlocks.map(\.placementID))
        )

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

        // 所见即所得：提交后 a 留在 -1，空列 0 保留（两个组件间允许空列）。
        XCTAssertTrue(engine.commitArrangement(preview))
        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originColumn, -1)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 1)
        XCTAssertEqual(engine.occupiedColumns(), 3)
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
        // 左扩内建：落点列为负；空列 0 保留（两个组件间允许空列，与提交一致）。
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: -1, row: 0))
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 1, row: 0))

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

    // MARK: 拖拽方向对称性：下移压到下方块即交换（插入序安放）

    /// 核心钉子：向下拖跨过下方相邻块顶缘（目标行 == 下方块 originRow）
    /// 即交换——旧语义里被拖块恒占阅读序首位，下移后压实拉回原状、
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

    /// 下移与上移同阈值：目标矩形首次压到下方块（未跨过其顶缘）即交换，
    /// 不再是「零反馈直到跨过顶缘」——那让大组件下移需要移动自身高度的格数。
    func testDragDownOntoNeighborSwaps() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "x", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "a", column: 0, row: 1, width: 2, height: 2)
        placeRaw(engine, id: "b", column: 0, row: 3, width: 2, height: 2)

        // a 下移 1 格：目标行 2，底缘压进 b 的顶缘（行 3）。
        let preview = engine.previewCommittedArrangement(moving: "a", toColumn: 0, toRow: 2)
        XCTAssertEqual(preview["a"], LayoutEngine.GridOrigin(column: 0, row: 3), "被拖块落到下方块之下")
        XCTAssertEqual(preview["b"], LayoutEngine.GridOrigin(column: 0, row: 1), "下方块保位并整体上移")
        XCTAssertEqual(preview["x"], LayoutEngine.GridOrigin(column: 0, row: 0))

        _ = engine.commitArrangement(preview)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 方向对称性：大组件（3 行）与紧邻的小块（1 行），下移 1 格与上移 1 格
    /// 必须落到**同一个**交换结果——阈值不得按拖动方向偏置。
    func testDragSwapThresholdIsDirectionSymmetric() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .large], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        placeRaw(engine, id: "big", column: 0, row: 0, width: 2, height: 3)
        placeRaw(engine, id: "small", column: 0, row: 3, width: 2, height: 1)

        // 大组件下移 1 格（目标行 1，底缘压进 small 的顶缘 3）。
        let down = engine.previewCommittedArrangement(moving: "big", toColumn: 0, toRow: 1)
        // 小块上移 1 格（目标行 2，落入 big 的包围盒）。
        let up = engine.previewCommittedArrangement(moving: "small", toColumn: 0, toRow: 2)

        XCTAssertEqual(
            down, up,
            "同一对相邻块，交换结果必须与拖动方向无关"
        )
        XCTAssertEqual(down["small"], LayoutEngine.GridOrigin(column: 0, row: 0))
        XCTAssertEqual(down["big"], LayoutEngine.GridOrigin(column: 0, row: 1))
        try? FileManager.default.removeItem(at: directory)
    }

    /// 上移对称性对照：向上 1 格、被拖块顶缘进入上方块包围盒即抢占交换
    /// （旧语义已如此，插入序安放不得改变它）。
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

    // MARK: 配置项：最小行数 / 最小列数（面板留白下限）

    /// 空布局也要撑到最小尺寸，且窗口高度与内容行数同源（顶栏 + 行高 + 底部内边距）。
    func testMinimumsFloorEmptyLayoutSize() throws {
        let (engine, directory, _) = try makeEngine(userMaxColumns: 6, minRows: 4, minColumns: 5)
        XCTAssertEqual(engine.drawerContentRows(), 4)
        XCTAssertEqual(engine.occupiedColumns(), 5)
        XCTAssertEqual(
            engine.drawerContentSize(),
            CGSize(
                width: NotchGridMetrics.contentWidth(columns: 5),
                height: NotchGridMetrics.contentHeight(rows: 4)
            )
        )
        XCTAssertEqual(
            engine.drawerWindowSize().height,
            NotchGridMetrics.drawerTopBarHeight
                + NotchGridMetrics.contentHeight(rows: 4)
                + NotchGridMetrics.contentPadding,
            accuracy: 1e-9
        )
        try? FileManager.default.removeItem(at: directory)
    }

    /// 下限只兜底、不封顶：块超过时仍按实占算。
    func testMinimumsAreFloorsNotCaps() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 6, minRows: 2, minColumns: 3)
        placeRaw(engine, id: "a", column: 0, row: 0, width: 1, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 4, width: 4, height: 2)
        XCTAssertEqual(engine.drawerContentRows(), 6)
        XCTAssertEqual(engine.occupiedColumns(), 4)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 删掉最后一个块：面板不塌回 1 行 1 列。
    func testRemovingLastBlockKeepsMinimums() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 6, minRows: 3, minColumns: 4)
        placeRaw(engine, id: "a", column: 0, row: 0, width: 1, height: 1)
        engine.removeDrawerBlock(placementID: "a")
        XCTAssertTrue(engine.drawerBlocks.isEmpty)
        XCTAssertEqual(engine.drawerContentRows(), 3)
        XCTAssertEqual(engine.occupiedColumns(), 4)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 列下限永远不超过**有效容量**（最大列数、窄屏两条都算）。
    func testMinimumColumnsNeverExceedCapacity() throws {
        let (engine, directory, _) = try makeEngine(userMaxColumns: 3, minRows: 1, minColumns: 8)
        XCTAssertEqual(engine.minimumColumnCount(), 3)
        XCTAssertEqual(engine.occupiedColumns(), 3)
        engine.updateScreenConstraint(width: 400)   // 容量 2
        XCTAssertEqual(engine.minimumColumnCount(), 2)
        XCTAssertEqual(engine.occupiedColumns(), 2)
        try? FileManager.default.removeItem(at: directory)
    }

    /// setter 夹紧：行夹进 1...9；列封顶到最大列数，最大列数小于可选项下界时忽略写入。
    func testMinimumSettersClampAndRespectMaxColumns() throws {
        let (engine, directory, _) = try makeEngine()
        engine.setUserMinRows(0)
        XCTAssertEqual(engine.userMinRows, 1)
        engine.setUserMinRows(99)
        XCTAssertEqual(engine.userMinRows, 9)
        engine.setUserMinColumns(99)
        XCTAssertEqual(engine.userMinColumns, 4, "封顶到最大列数")
        engine.setUserMaxColumns(2)
        engine.setUserMinColumns(5)
        XCTAssertEqual(engine.userMinColumns, 4, "最大列数 2 < 下界 3：该配置无从生效")
        XCTAssertEqual(engine.minimumColumnCount(), 2, "以容量为准")
        engine.setUserMaxColumns(6)
        XCTAssertEqual(engine.userMinColumns, 4, "原设置未被抹掉")
        try? FileManager.default.removeItem(at: directory)
    }

    /// 编辑模式契约不破：留白下限不参与行压实，预览与提交同一条列公式。
    func testCompactionAndPreviewContractHoldWithMinimums() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 6, minRows: 5, minColumns: 3)
        placeRaw(engine, id: "a", column: 0, row: 0, width: 1, height: 1)
        placeRaw(engine, id: "b", column: 0, row: 3, width: 1, height: 1)

        XCTAssertTrue(engine.compactEmptyRows())
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originRow, 1, "空行照样闭合")
        XCTAssertEqual(engine.drawerContentRows(), 5, "压实后仍按最小行数留白")

        let preview = engine.previewArrangement(moving: "a", toColumn: 2, toRow: 0)
        XCTAssertEqual(
            engine.previewOccupiedColumns(origins: preview),
            engine.occupiedColumns(),
            "预览 == 提交：同一条下限公式"
        )
        XCTAssertEqual(engine.previewBottomRow(origins: preview), 5)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 容量缩小修复（setUserMaxColumns 越界重排）
    //
    // 渲染可见列窗口 = [gridLeft, gridLeft + capacity)：合并跨度超容量的页，
    // 右缘块被面板裁掉。修复保持该页左缘锚定，越界块就近折回（贴窗口右缘），
    // 撞上已固定块即下移，收尾按页压实；修完幂等。

    func testShrinkingMaxColumnsPullsOutOfRangeBlockBackIntoWindow() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 6, row: 0, width: 2, height: 1)

        engine.setUserMaxColumns(4)

        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originColumn, 0, "窗口内块零移动")
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 2, "越界块就近折回窗口右缘")
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originRow, 0)
        XCTAssertTrue(engine.validate().isEmpty)
        let range = engine.occupiedColumnRange()
        XCTAssertLessThanOrEqual(range.max - range.min, engine.effectiveMaxColumns())
        try? FileManager.default.removeItem(at: directory)
    }

    func testShrinkingMaxColumnsPushesDownWhenWindowColumnOccupied() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 2, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "c", column: 6, row: 0, width: 2, height: 1)

        engine.setUserMaxColumns(4)

        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originColumn, 0)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 2)
        XCTAssertEqual(engine.drawerBlock(placementID: "c")?.originColumn, 2, "夹回窗口右缘 2...3")
        XCTAssertEqual(engine.drawerBlock(placementID: "c")?.originRow, 1, "撞上 b 即下移")
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testShrinkingMaxColumnsAnchorsWindowAtPageLeftEdge() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        placeRaw(engine, id: "a", column: -2, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 4, row: 0, width: 2, height: 1)

        engine.setUserMaxColumns(4)

        XCTAssertEqual(engine.drawerBlock(placementID: "a")?.originColumn, -2, "左缘（含负列左扩）锚定不动")
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 0, "夹回窗口 [-2, 2) 右缘")
        let range = engine.occupiedColumnRange()
        XCTAssertEqual(range.min, -2)
        XCTAssertEqual(range.max, 2)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testShrinkingMaxColumnsCompactsRowsVacatedByRepair() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 6, row: 3, width: 2, height: 1)

        engine.setUserMaxColumns(4)

        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originColumn, 2)
        XCTAssertEqual(engine.drawerBlock(placementID: "b")?.originRow, 1, "折回后腾出的整行空洞被压实")
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testShrinkingMaxColumnsRepairsOnlyOverflowingPagesKeepsArrayOrder() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        placeRaw(engine, id: "fit-1", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "over-left", column: 0, row: 0, width: 2, height: 1, page: 1)
        placeRaw(engine, id: "fit-2", column: 2, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "over-right", column: 6, row: 0, width: 2, height: 1, page: 1)

        engine.setUserMaxColumns(4)

        XCTAssertEqual(engine.drawerBlock(placementID: "fit-1")?.originColumn, 0, "合规页不动")
        XCTAssertEqual(engine.drawerBlock(placementID: "fit-2")?.originColumn, 2)
        XCTAssertEqual(engine.drawerBlock(placementID: "over-left")?.originColumn, 0)
        XCTAssertEqual(engine.drawerBlock(placementID: "over-right")?.originColumn, 2, "越界页修复")
        XCTAssertEqual(
            engine.modelForTesting.drawerBlocks.map(\.placementID),
            ["fit-1", "over-left", "fit-2", "over-right"],
            "perPage 契约：数组顺序（ForEach 稳定性）不得重排"
        )
        try? FileManager.default.removeItem(at: directory)
    }

    func testShrinkingMaxColumnsRepairIsIdempotent() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.medium], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        placeRaw(engine, id: "a", column: 0, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "b", column: 6, row: 0, width: 2, height: 1)
        placeRaw(engine, id: "c", column: 6, row: 1, width: 2, height: 1)

        engine.setUserMaxColumns(4)
        let repaired = engine.modelForTesting.drawerBlocks

        engine.setUserMaxColumns(8)
        engine.setUserMaxColumns(4)
        XCTAssertEqual(engine.modelForTesting.drawerBlocks, repaired, "重复缩列修复结果逐块相同")
        try? FileManager.default.removeItem(at: directory)
    }

    func testRepairToleratesBlockWiderThanCapacity() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium, .wide], defaultSize: .medium)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        placeRaw(engine, id: "wide", column: 1, row: 0, width: 6, height: 1)
        placeRaw(engine, id: "small", column: 0, row: 1, width: 1, height: 1)

        engine.setUserMaxColumns(4)

        XCTAssertEqual(
            engine.drawerBlock(placementID: "wide")?.originColumn, 0,
            "超宽块无法用列位移修复：夹回窗口左缘（部分裁切与窄屏现状一致）"
        )
        XCTAssertEqual(engine.drawerBlock(placementID: "small")?.originColumn, 0)
        XCTAssertEqual(
            engine.modelForTesting.drawerBlocks.map(\.widthColumns),
            [6, 1],
            "不改写块跨度"
        )
        let kinds = Set(engine.validate().map(layoutIssueKind))
        XCTAssertTrue(kinds.contains("outOfBounds"), "超宽块仍报越界（不可修复项）")
        XCTAssertFalse(kinds.contains("overlap"))
        try? FileManager.default.removeItem(at: directory)
    }

    func testRandomShrinkRepairKeepsInvariants() throws {
        register(blockID: "cell", kind: .drawer, sizes: [.small, .medium], defaultSize: .small)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 8)
        // 固定种子可重放；每块独占一行（初始无重叠），列随机。
        var seed: UInt64 = 0x5EED_2026
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let ids = (0..<6).map { "b\($0)" }
        for (index, id) in ids.enumerated() {
            placeRaw(engine, id: id, column: random(7), row: index, width: 1 + random(2), height: 1)
        }

        for _ in 0..<30 {
            // 4...8：宽 ≤ 2 的块恒可修复，跨度不变量必须严格成立。
            engine.setUserMaxColumns(4 + random(5))

            let blocks = engine.modelForTesting.drawerBlocks
            XCTAssertEqual(blocks.map(\.placementID), ids, "数组顺序稳定")
            let range = engine.occupiedColumnRange()
            XCTAssertLessThanOrEqual(range.max - range.min, engine.effectiveMaxColumns(), "跨度 ≤ 容量")
            for (index, block) in blocks.enumerated() {
                XCTAssertGreaterThanOrEqual(block.originRow, 0)
                for other in blocks.dropFirst(index + 1) {
                    XCTAssertFalse(
                        LayoutEngine.rectsOverlap(block, other),
                        "\(block.placementID) 与 \(other.placementID) 重叠"
                    )
                }
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 跨页搬移（胶囊驻留切页的落位动作）

    /// 双页布局种子:页 0 三块(keep/moved/below),页 1 一块(other)。
    private func seedTwoPages(_ engine: LayoutEngine) {
        var model = engine.modelForTesting
        model.drawerPages = [0, 1]
        model.drawerBlocks = [
            PlacedBlock(pluginID: "p", blockID: "b", placementID: "keep", page: 0, originColumn: 0, originRow: 0, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "p", blockID: "b", placementID: "moved", page: 0, originColumn: 1, originRow: 0, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "p", blockID: "b", placementID: "below", page: 0, originColumn: 0, originRow: 2, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "p", blockID: "b", placementID: "other", page: 1, originColumn: 0, originRow: 0, widthColumns: 1, heightRows: 1)
        ]
        engine.modelForTesting = model
    }

    func testMoveDrawerBlockCrossPagePreservesIdentityAndCompactsSource() throws {
        let (engine, directory, _) = try makeEngine()
        seedTwoPages(engine)

        let moved = engine.moveDrawerBlockCrossPage(placementID: "moved", toPage: 1, column: 0, row: 0)
        XCTAssertNotNil(moved)
        // placementID 是插件实例状态键,跨页必须原样保留。
        XCTAssertEqual(moved?.placementID, "moved")
        XCTAssertEqual(moved?.page, 1)
        // 请求格 (0,0) 被 other 占 → nearestFreeOrigin 行内先右:(1,0)。
        XCTAssertEqual(moved?.originColumn, 1)
        XCTAssertEqual(moved?.originRow, 0)

        let blocks = engine.modelForTesting.drawerBlocks
        XCTAssertEqual(blocks.count, 4, "搬移不增减块数")
        // 原页压实:moved 搬走后空行闭合,below 上移一行。
        XCTAssertEqual(blocks.first { $0.placementID == "keep" }?.originRow, 0)
        XCTAssertEqual(blocks.first { $0.placementID == "below" }?.originRow, 1)
        XCTAssertEqual(blocks.first { $0.placementID == "below" }?.page, 0)
        // 目标页两块不重叠。
        let page1 = blocks.filter { $0.page == 1 }
        XCTAssertEqual(page1.count, 2)
        XCTAssertFalse(LayoutEngine.rectsOverlap(page1[0], page1[1]))
        try? FileManager.default.removeItem(at: directory)
    }

    func testMoveDrawerBlockCrossPageLandsAtFreePreferredCell() throws {
        let (engine, directory, _) = try makeEngine()
        seedTwoPages(engine)
        // 页 1 的 (2,0) 空闲 → 精确落在请求格。
        let moved = engine.moveDrawerBlockCrossPage(placementID: "moved", toPage: 1, column: 2, row: 0)
        XCTAssertEqual(moved?.originColumn, 2)
        XCTAssertEqual(moved?.originRow, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testMoveDrawerBlockCrossPageRejectsSamePageAndUnknownID() throws {
        let (engine, directory, _) = try makeEngine()
        seedTwoPages(engine)
        let before = engine.modelForTesting.drawerBlocks
        // 同页搬移走 moveDrawerBlock 语义,不走这里。
        XCTAssertNil(engine.moveDrawerBlockCrossPage(placementID: "moved", toPage: 0, column: 3, row: 0))
        // 未知 placementID。
        XCTAssertNil(engine.moveDrawerBlockCrossPage(placementID: "nope", toPage: 1, column: 3, row: 0))
        // 不存在的目标页(页索引恒为身份,从不重编号)。
        XCTAssertNil(engine.moveDrawerBlockCrossPage(placementID: "moved", toPage: 7, column: 0, row: 0))
        XCTAssertEqual(engine.modelForTesting.drawerBlocks, before, "拒绝路径不得改写布局")
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