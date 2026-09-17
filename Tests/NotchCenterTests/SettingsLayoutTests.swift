import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

// MARK: - 可配置网格指标（设置 → 布局）

@MainActor
final class GridMetricsStoreTests: XCTestCase {
    private func makeStore() -> (GridMetricsStore, UserDefaults, String) {
        let suite = "GridMetricsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (
            GridMetricsStore(defaults: defaults, postsNotification: false),
            defaults,
            suite
        )
    }

    func testDefaultsMatchProductionValues() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removeSuite(named: suite) }
        XCTAssertEqual(store.cellWidth, 150)
        XCTAssertEqual(store.cellHeight, 120)
        XCTAssertEqual(store.spacing, 12)
        XCTAssertEqual(store.contentPadding, 16)
        XCTAssertTrue(store.isDefault)
    }

    func testSnapshotKeepsValuesWhileNewReadsFollowChanges() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.set(.cellWidth, to: 180)
        store.set(.cellHeight, to: 90)
        store.set(.spacing, to: 8)
        store.set(.contentPadding, to: 20)
        let before = store.snapshot()
        XCTAssertEqual(before, GridMetrics(
            cellWidth: 180, cellHeight: 90, spacing: 8,
            contentPadding: 20, topBarHeight: 36
        ))
        XCTAssertEqual(before.size(columns: 2, rows: 3), CGSize(width: 368, height: 286))

        store.set(.cellWidth, to: 220)
        store.set(.cellHeight, to: 100)
        store.set(.spacing, to: 10)
        store.set(.contentPadding, to: 24)
        XCTAssertEqual(before.cellWidth, 180)
        XCTAssertEqual(before.cellHeight, 90)
        XCTAssertEqual(before.spacing, 8)
        XCTAssertEqual(before.contentPadding, 20)
        XCTAssertEqual(store.snapshot(), GridMetrics(
            cellWidth: 220, cellHeight: 100, spacing: 10,
            contentPadding: 24, topBarHeight: 36
        ))
    }

    func testSetClampsIntoDeclaredRange() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removeSuite(named: suite) }
        store.set(.cellWidth, to: 1)
        XCTAssertEqual(store.cellWidth, GridMetricsStore.range(for: .cellWidth).lowerBound)
        store.set(.cellWidth, to: 10_000)
        XCTAssertEqual(store.cellWidth, GridMetricsStore.range(for: .cellWidth).upperBound)
        store.set(.spacing, to: -8)
        XCTAssertEqual(store.spacing, 0)
        XCTAssertFalse(store.isDefault)
    }

    func testValuesPersistAcrossInstances() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removeSuite(named: suite) }
        store.set(.cellWidth, to: 200)
        store.set(.spacing, to: 20)

        let reloaded = GridMetricsStore(defaults: defaults, postsNotification: false)
        XCTAssertEqual(reloaded.cellWidth, 200)
        XCTAssertEqual(reloaded.spacing, 20)

        reloaded.resetToDefaults()
        XCTAssertEqual(GridMetricsStore(defaults: defaults, postsNotification: false).cellWidth, 150)
    }

    /// `NotchGridMetrics` 是既有几何计算的统一访问点：改 store 后
    /// 派生公式（内容宽度）必须同步，抽屉尺寸才会跟着设置走。
    ///
    /// 共享单例落的是**真实用户偏好**（测试以宿主 App 为 TEST_HOST），所以这里
    /// 只能"改完原样还原"：早先用 `resetToDefaults()` 收尾，等于每次跑测试都把
    /// 用户在「设置 → 布局」里调过的格子**删掉**（它移除持久化的键）。
    func testGridMetricsForwardsToSharedStore() {
        let snapshot = GridMetricsSnapshot()
        addTeardownBlock { snapshot.apply(to: .shared) }
        let shared = GridMetricsStore.shared
        shared.set(.cellWidth, to: 200)
        shared.set(.spacing, to: 10)
        XCTAssertEqual(NotchGridMetrics.cellWidth, 200)
        XCTAssertEqual(NotchGridMetrics.spacing, 10)
        XCTAssertEqual(NotchGridMetrics.contentWidth(columns: 2), 2 * 200 + 10)

        // 还原 = 回到用户原本那一份（未必是出厂默认，故比快照不比常量）。
        snapshot.apply(to: .shared)
        XCTAssertEqual(NotchGridMetrics.cellWidth, snapshot.cellWidth)
        XCTAssertEqual(NotchGridMetrics.spacing, snapshot.spacing)
        XCTAssertEqual(
            NotchGridMetrics.contentWidth(columns: 2),
            2 * snapshot.cellWidth + snapshot.spacing
        )
    }
}

// MARK: - 设置面板拖拽落位（布局引擎新增 API）

@MainActor
final class BlockPlacementTests: XCTestCase {
    private var registry: [String: NotchBlock] = [:]

    /// 像素夹具的前提：钉住网格指标，隔离宿主 App 的真实偏好（见
    /// `GridMetricsTestSupport`）。
    nonisolated override func setUp() {
        super.setUp()
        pinGridMetricsToFixtureDefaults()
    }

    private func makeEngine(userMaxColumns: Int = 4) throws -> (LayoutEngine, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockPlacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = LayoutEngine(
            fileURL: directory.appendingPathComponent("layout.json"),
            blockResolver: { [weak self] pluginID, blockID in
                self?.registry["\(pluginID)|\(blockID)"]
            }
        )
        engine.setUserMaxColumns(userMaxColumns)
        return (engine, directory)
    }

    private func register(
        pluginID: String = "com.test.plugin",
        blockID: String,
        kind: BlockKind,
        sizes: Set<FixtureSize> = [],
        defaultSize: FixtureSize? = nil
    ) {
        let makeView: @MainActor (BlockContext) -> AnyView = { _ in AnyView(EmptyView()) }
        switch kind {
        case .compact:
            registry["\(pluginID)|\(blockID)"] = NotchBlock(
                id: blockID, displayName: blockID, kind: kind, makeView: makeView
            )
        case .drawer:
            let box = fixtureBox(sizes: sizes, defaultSize: defaultSize)
            registry["\(pluginID)|\(blockID)"] = NotchBlock(
                id: blockID, displayName: blockID, kind: kind,
                minSize: box.min, maxSize: box.max, recommendedSize: box.recommended,
                makeView: makeView
            )
        }
    }

    // MARK: 快速区插入（紧凑块拖拽落点，屏幕位置语义）

    /// 屏幕从左到右的 blockID 序列（快捷区落点的用户可见顺序）。
    private func screenOrderBlockIDs(_ engine: LayoutEngine) -> [String] {
        let count = engine.compactSlots.count
        return CompactSlotOrder.screenOrder(slotCount: count)
            .compactMap { engine.compactSlot(at: $0)?.blockID }
    }

    func testScreenOrderMatchesSlotRectGeometry() {
        // 纯算术的屏幕顺序必须与槽位几何（中点排序）一致——
        // 拖动/插入都按 screenOrder 运算，两边对不上就会所见非所得。
        for count in 1...9 {
            let strip = NotchGeometry.layout(for: nil, compactCount: count)
                .compactStrip(slotCount: count)
            let geometric = (0..<count).sorted { lhs, rhs in
                (strip.slotRect(at: lhs)?.midX ?? 0) < (strip.slotRect(at: rhs)?.midX ?? 0)
            }
            XCTAssertEqual(
                CompactSlotOrder.screenOrder(slotCount: count),
                geometric,
                "slotCount \(count) 的屏幕顺序与槽位几何不一致"
            )
        }
    }

    func testInsertCompactBlockAtScreenPosition() throws {
        register(blockID: "a", kind: .compact)
        register(blockID: "b", kind: .compact)
        register(blockID: "c", kind: .compact)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "a"))
        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "b"))

        // 插到屏幕第 1 位（a 之后、b 之前）：屏幕 a c | b，其余保持相对顺序。
        XCTAssertTrue(engine.insertCompactBlock(
            pluginID: "com.test.plugin",
            blockID: "c",
            atScreenPosition: 1
        ))
        XCTAssertEqual(engine.compactSlots.compactMap { $0?.blockID }, ["a", "b", "c"])
        XCTAssertEqual(screenOrderBlockIDs(engine), ["a", "c", "b"])

        // 越界钳制：负数落到最左、超大落到末尾。
        XCTAssertTrue(engine.insertCompactBlock(
            pluginID: "com.test.plugin",
            blockID: "a",
            atScreenPosition: -5
        ))
        XCTAssertEqual(screenOrderBlockIDs(engine).first, "a")
        XCTAssertTrue(engine.insertCompactBlock(
            pluginID: "com.test.plugin",
            blockID: "b",
            atScreenPosition: 99
        ))
        XCTAssertEqual(screenOrderBlockIDs(engine).last, "b")
        XCTAssertTrue(engine.validate().isEmpty)
    }

    // MARK: 快捷按钮重排（编辑模式拖动换位，方案 A：按屏幕顺序运算）

    func testMoveCompactSlotKeepsScreenOrderOfOthers() throws {
        register(blockID: "a", kind: .compact)
        register(blockID: "b", kind: .compact)
        register(blockID: "c", kind: .compact)
        register(blockID: "d", kind: .compact)
        register(blockID: "e", kind: .compact)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        for blockID in ["a", "b", "c", "d", "e"] {
            XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: blockID))
        }
        // 数组 [a,b,c,d,e] → 屏幕 a c e | b d（偶数下标在左、奇数在右）。
        XCTAssertEqual(screenOrderBlockIDs(engine), ["a", "c", "e", "b", "d"])

        // 跨面板拖动：屏幕第 0 位（a）拖到屏幕第 2 位（c 与 e 之间）。
        // 期望屏幕 c a e | b d——只有 a 移动，其余保持相对顺序。
        XCTAssertTrue(engine.moveCompactSlot(from: 0, toScreenPosition: 2))
        XCTAssertEqual(screenOrderBlockIDs(engine), ["c", "a", "e", "b", "d"])
        XCTAssertTrue(engine.validate().isEmpty)
    }

    func testMoveCompactSlotWithinThreeIcons() throws {
        register(blockID: "a", kind: .compact)
        register(blockID: "b", kind: .compact)
        register(blockID: "c", kind: .compact)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        for blockID in ["a", "b", "c"] {
            XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: blockID))
        }
        XCTAssertEqual(screenOrderBlockIDs(engine), ["a", "c", "b"])

        // 屏幕第 0 位（a）拖到屏幕第 2 位 → 屏幕 c a | b。
        XCTAssertTrue(engine.moveCompactSlot(from: 0, toScreenPosition: 2))
        XCTAssertEqual(screenOrderBlockIDs(engine), ["c", "a", "b"])

        // 屏幕第 0 位（c）拖到末尾 → 屏幕 a b | c。
        XCTAssertTrue(engine.moveCompactSlot(from: 0, toScreenPosition: 3))
        XCTAssertEqual(screenOrderBlockIDs(engine), ["a", "b", "c"])

        // 屏幕第 1 位（b，数组下标 2）拖到屏幕第 1 / 2 位都是“c 之前”→ 原位。
        XCTAssertFalse(engine.moveCompactSlot(from: 2, toScreenPosition: 1))
        XCTAssertFalse(engine.moveCompactSlot(from: 2, toScreenPosition: 2))
        // 拖到屏幕第 3 位（末尾，c 之后）→ 屏幕 a c | b。
        XCTAssertTrue(engine.moveCompactSlot(from: 2, toScreenPosition: 3))
        XCTAssertEqual(screenOrderBlockIDs(engine), ["a", "c", "b"])
        XCTAssertTrue(engine.validate().isEmpty)
    }

    func testMoveCompactSlotIgnoresNoopAndOutOfRange() throws {
        register(blockID: "a", kind: .compact)
        register(blockID: "b", kind: .compact)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "a"))
        XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: "b"))

        // 落点即原位（含“右侧相邻”这种视觉上没挪动的落点）→ 不改动、不落盘。
        XCTAssertFalse(engine.moveCompactSlot(from: 0, toScreenPosition: 0))
        XCTAssertFalse(engine.moveCompactSlot(from: 0, toScreenPosition: 1))
        XCTAssertEqual(engine.compactSlots.compactMap { $0?.blockID }, ["a", "b"])

        // 越界来源直接忽略。
        XCTAssertFalse(engine.moveCompactSlot(from: 7, toScreenPosition: 0))
        XCTAssertEqual(engine.compactSlots.compactMap { $0?.blockID }, ["a", "b"])
    }

    /// 移除同样保持屏幕相对顺序：直接 remove 会让后续下标重排、屏幕上
    /// 其余图标集体换位（e 会从左面板跳到右面板）。
    func testRemoveCompactSlotKeepsScreenOrder() throws {
        register(blockID: "a", kind: .compact)
        register(blockID: "b", kind: .compact)
        register(blockID: "c", kind: .compact)
        register(blockID: "d", kind: .compact)
        register(blockID: "e", kind: .compact)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        for blockID in ["a", "b", "c", "d", "e"] {
            XCTAssertTrue(engine.addCompactBlock(pluginID: "com.test.plugin", blockID: blockID))
        }
        // 屏幕 a c e | b d：移除屏幕第 1 位（c，数组下标 2）→ 屏幕 a e | b d。
        engine.setCompactSlot(2, to: nil)
        XCTAssertEqual(screenOrderBlockIDs(engine), ["a", "e", "b", "d"])
        XCTAssertTrue(engine.validate().isEmpty)
    }

    func testInsertCompactBlockRejectsDrawerBlock() throws {
        register(blockID: "drawer", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(
            engine.insertCompactBlock(
                pluginID: "com.test.plugin",
                blockID: "drawer",
                atScreenPosition: 0
            ),
            "快捷按钮区只接受紧凑块——抽屉块拖到快速区应被拒绝"
        )
        XCTAssertTrue(engine.compactSlots.isEmpty)
    }

    // MARK: 抽屉落点

    func testPlaceDrawerBlockHonorsDropPoint() throws {
        register(blockID: "notes", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }

        let placed = engine.placeDrawerBlock(
            pluginID: "com.test.plugin",
            blockID: "notes",
            column: 2,
            row: 1
        )
        XCTAssertNotNil(placed)
        XCTAssertEqual(placed?.originColumn, 2)
        XCTAssertEqual(placed?.originRow, 1)
        XCTAssertTrue(engine.validate().isEmpty)
    }

    func testPlaceDrawerBlockFallsBackToNearestFreeSpot() throws {
        register(blockID: "notes", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNotNil(engine.placeDrawerBlock(
            pluginID: "com.test.plugin",
            blockID: "notes",
            column: 0,
            row: 0
        ))
        // 同一落点被占：行优先扫描最近可用位置（同一行右侧优先）。
        let second = engine.placeDrawerBlock(
            pluginID: "com.test.plugin",
            blockID: "notes",
            column: 0,
            row: 0
        )
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.originRow, 0)
        XCTAssertEqual(second?.originColumn, 1)
        XCTAssertTrue(engine.validate().isEmpty, "落点被占时不得写出重叠布局")
    }

    func testPlaceDrawerBlockRejectsCompactBlock() throws {
        register(blockID: "button", kind: .compact)
        let (engine, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(
            engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "button", column: 0, row: 0),
            "抽屉网格只接受抽屉块——快捷按钮拖到网格应被拒绝"
        )
        XCTAssertTrue(engine.drawerBlocks.isEmpty)
    }
}

// MARK: - 最小行数 / 最小列数的持久化（layout.json）

@MainActor
final class MinimumGridSizePersistenceTests: XCTestCase {
    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MinimumGridSize-\(UUID().uuidString).json")
    }

    private func makeEngine(fileURL: URL) -> LayoutEngine {
        LayoutEngine(fileURL: fileURL, blockResolver: { _, _ in nil })
    }

    /// 编码必须真的带上这两个键：`CodingKeys` 漏加会被合成编码器静默丢弃，
    /// 表现为「设置了但重启后回到默认」。
    func testMinimumsAreEncodedAndRoundTrip() throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = makeEngine(fileURL: url)
        engine.setUserMinRows(7)
        engine.setUserMinColumns(4)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["minRows"] as? Int, 7)
        XCTAssertEqual(json?["minColumns"] as? Int, 4)

        let restored = makeEngine(fileURL: url)
        XCTAssertEqual(restored.userMinRows, 7)
        XCTAssertEqual(restored.userMinColumns, 4)
        XCTAssertTrue(restored.didLoadFromDisk)
    }

    /// 老 layout.json 无这两个键 → 默认 1 行（高度行为不变）/ 3 列（抽屉至少 3 列宽）。
    func testLegacyLayoutWithoutKeysFallsBackToDefaults() throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {
          "schemaVersion": 1,
          "maxColumns": 4,
          "compactSlots": [],
          "drawerBlocks": [],
          "enabledPluginIDs": []
        }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let engine = makeEngine(fileURL: url)
        XCTAssertEqual(engine.userMinRows, LayoutModel.defaultMinRows)
        XCTAssertEqual(engine.userMinColumns, LayoutModel.defaultMinColumns)
        XCTAssertEqual(engine.drawerContentRows(), 1)
        XCTAssertEqual(engine.occupiedColumns(), 3)
    }

    /// 自定义 `init(from:)` 不跑成员式 init 的夹紧：越界存量值必须在解码处各自夹好。
    /// 两段各用独立文件——引擎 init 末尾会写盘，复用同一文件第二次读到的是已夹紧结果。
    func testOutOfRangeStoredValuesAreClampedOnDecode() throws {
        let below = makeFileURL()
        let above = makeFileURL()
        defer {
            try? FileManager.default.removeItem(at: below)
            try? FileManager.default.removeItem(at: above)
        }
        try layoutJSON(minRows: 99, minColumns: 0).write(to: below, atomically: true, encoding: .utf8)
        let lowEngine = makeEngine(fileURL: below)
        XCTAssertEqual(lowEngine.userMinRows, LayoutModel.minRowsRange.upperBound)
        XCTAssertEqual(lowEngine.userMinColumns, LayoutModel.minColumnsRange.lowerBound)

        try layoutJSON(minRows: -5, minColumns: 99).write(to: above, atomically: true, encoding: .utf8)
        let highEngine = makeEngine(fileURL: above)
        XCTAssertEqual(highEngine.userMinRows, LayoutModel.minRowsRange.lowerBound)
        XCTAssertEqual(highEngine.userMinColumns, LayoutModel.minColumnsRange.upperBound)
        // 存量列下限大于最大列数 → 下限等于容量：面板恒为满宽，但不超出固定窗口。
        highEngine.setUserMaxColumns(4)
        XCTAssertEqual(highEngine.minimumColumnCount(), 4)
        XCTAssertEqual(highEngine.occupiedColumns(), 4)
    }

    private func layoutJSON(minRows: Int, minColumns: Int) -> String {
        """
        {
          "schemaVersion": 1,
          "maxColumns": 8,
          "minRows": \(minRows),
          "minColumns": \(minColumns),
          "compactSlots": [],
          "drawerBlocks": [],
          "enabledPluginIDs": []
        }
        """
    }
}
