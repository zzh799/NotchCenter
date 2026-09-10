import Foundation
import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

/// 抽屉多页面：页面集合管理、页内算法隔离、旧版 layout.json 兼容解码。
@MainActor
final class DrawerPageTests: XCTestCase {
    private var registry: [String: NotchBlock] = [:]

    /// 像素夹具的前提：钉住网格指标（出厂格 = 夹具换算基准），否则开发者机器上
    /// 调过的格子会把档位换算成别的跨，几何断言翻倍（见 `GridMetricsTestSupport`）。
    nonisolated override func setUp() {
        super.setUp()
        pinGridMetricsToFixtureDefaults()
    }

    private func makeEngine(
        userMaxColumns: Int = 4,
        minRows: Int = 1,
        minColumns: Int = 1,
        directory: URL? = nil
    ) throws -> (LayoutEngine, URL, URL) {
        let directory = directory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("DrawerPageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("layout.json")
        let engine = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        engine.setUserMaxColumns(userMaxColumns)
        // 默认关掉最小行/列下限：本文件断言的是各页**实占**跨度（含「两页尺寸不同」），
        // 留白夹紧会抹平差异。下限 1 不在可选项范围内，只能经内部写入入口给。
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
        sizes: Set<FixtureSize> = [],
        defaultSize: FixtureSize? = nil
    ) {
        let makeView: @MainActor (BlockContext) -> AnyView = { _ in AnyView(EmptyView()) }
        switch kind {
        case .compact:
            registry["\(pluginID)|\(blockID)"] = NotchBlock(
                id: blockID, displayName: blockID, kind: kind, makeView: makeView
            )
        case .drawer, .page:
            let box = fixtureBox(sizes: sizes, defaultSize: defaultSize)
            registry["\(pluginID)|\(blockID)"] = NotchBlock(
                id: blockID, displayName: blockID, kind: kind,
                minSize: box.min, maxSize: box.max, recommendedSize: box.recommended,
                makeView: makeView
            )
        }
    }

    private func loadModel(from fileURL: URL) throws -> LayoutModel {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(LayoutModel.self, from: data)
    }

    // MARK: 页面集合

    func testDefaultModelHasHomePageOnly() throws {
        let (engine, directory, _) = try makeEngine()
        XCTAssertEqual(engine.drawerPages, [0])
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddDrawerPageGrowsOutwardFromHome() throws {
        let (engine, directory, _) = try makeEngine()
        let left = engine.addDrawerPage(.left)
        XCTAssertEqual(left, -1)
        XCTAssertEqual(engine.drawerPages, [-1, 0])

        let right = engine.addDrawerPage(.right)
        XCTAssertEqual(right, 1)
        XCTAssertEqual(engine.drawerPages, [-1, 0, 1])

        let secondLeft = engine.addDrawerPage(.left)
        XCTAssertEqual(secondLeft, -2)
        XCTAssertEqual(engine.drawerPages, [-2, -1, 0, 1])
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddDrawerPagePersistsAcrossReload() throws {
        let (engine, directory, fileURL) = try makeEngine()
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        _ = engine.addDrawerPage(.left)
        _ = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: -1
        ))

        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        XCTAssertEqual(reloaded.drawerPages, [-1, 0])
        XCTAssertEqual(reloaded.drawerBlocks(onPage: -1).count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddDrawerPageIsCapped() throws {
        let (engine, directory, _) = try makeEngine()
        // 初始 1 页（主页），加到上限前仍可加页。
        for _ in 0..<(LayoutModel.maxDrawerPageCount - 2) {
            _ = engine.addDrawerPage(.right)
        }
        XCTAssertEqual(engine.drawerPages.count, LayoutModel.maxDrawerPageCount - 1)
        XCTAssertTrue(engine.canAddDrawerPage())
        _ = engine.addDrawerPage(.right)
        XCTAssertEqual(engine.drawerPages.count, LayoutModel.maxDrawerPageCount)
        XCTAssertFalse(engine.canAddDrawerPage())
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 显示序列（拖动排序）

    func testNormalizedPagesPreservesDisplayOrder() {
        // 数组顺序即显示次序：归一化只去重与补主页，**绝不排序**（排序会把用户
        // 的拖动结果抹掉）。
        XCTAssertEqual(
            LayoutModel.normalizedPages([3, -1, 0, 3, 2]),
            [3, -1, 0, 2]
        )
        // 缺主页 0 → 补到序列首位；块引用的散页按出现顺序追加到末尾。
        XCTAssertEqual(LayoutModel.normalizedPages([5, 7]), [0, 5, 7])
        XCTAssertEqual(
            LayoutModel.normalizedPages([2, 0], blockPages: [2, 9, 0, 4]),
            [2, 0, 9, 4]
        )
    }

    func testAddDrawerPageUsesValueExtremesWhenOrderIsPermuted() throws {
        let (engine, directory, _) = try makeEngine()
        // 乱序显示序列：first/last 都不再是极值，新页索引必须按权值算。
        var model = engine.modelForTesting
        model.drawerPages = [2, -1, 0, 1]
        engine.modelForTesting = model

        XCTAssertEqual(engine.addDrawerPage(.right), 3)
        XCTAssertEqual(engine.drawerPages, [2, -1, 0, 1, 3], "右加追加到序列末尾")
        XCTAssertEqual(engine.addDrawerPage(.left), -2)
        XCTAssertEqual(engine.drawerPages, [-2, 2, -1, 0, 1, 3], "左加插到序列首位")
        try? FileManager.default.removeItem(at: directory)
    }

    func testMoveDrawerPageReordersWithoutTouchingBlockPages() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, fileURL) = try makeEngine()
        _ = engine.addDrawerPage(.right)
        _ = engine.addDrawerPage(.left)
        XCTAssertEqual(engine.drawerPages, [-1, 0, 1])
        _ = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: -1
        ))
        _ = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "b", column: 0, row: 0, page: 1
        ))

        // 把 1 页挪到序列首位：显示序变了，块上的 page 值一个都不动。
        XCTAssertTrue(engine.moveDrawerPage(from: 1, to: 0))
        XCTAssertEqual(engine.drawerPages, [1, -1, 0])
        XCTAssertEqual(engine.drawerBlocks(onPage: -1).count, 1)
        XCTAssertEqual(engine.drawerBlocks(onPage: 1).count, 1)
        XCTAssertEqual(Set(engine.drawerBlocks.map(\.page)), [-1, 1])

        // 落盘往返：重载后仍是用户排好的次序（旧版强制升序会把它抹平）。
        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        XCTAssertEqual(reloaded.drawerPages, [1, -1, 0])
        try? FileManager.default.removeItem(at: directory)
    }

    func testMoveDrawerPageClampsAndDetectsNoop() throws {
        let (engine, directory, _) = try makeEngine()
        _ = engine.addDrawerPage(.right)
        _ = engine.addDrawerPage(.right)
        XCTAssertEqual(engine.drawerPages, [0, 1, 2])

        // 原位与"目标就是自己"都算无变化。
        XCTAssertFalse(engine.moveDrawerPage(from: 1, to: 1))
        XCTAssertFalse(engine.moveDrawerPage(from: 99, to: 0), "不存在的页面")
        // 越界夹紧到端点。
        XCTAssertTrue(engine.moveDrawerPage(from: 0, to: 99))
        XCTAssertEqual(engine.drawerPages, [1, 2, 0])
        XCTAssertTrue(engine.moveDrawerPage(from: 2, to: -5))
        XCTAssertEqual(engine.drawerPages, [2, 1, 0])
        try? FileManager.default.removeItem(at: directory)
    }

    func testPillDragPreviewMatchesCommittedOrder() throws {
        let (engine, directory, _) = try makeEngine()
        for _ in 0..<4 { _ = engine.addDrawerPage(.right) }
        let base = engine.drawerPages
        XCTAssertEqual(base, [0, 1, 2, 3, 4])

        // 逐对穷举：预览期每颗胶囊的让位槽位，必须与引擎 remove+insert 的
        // 提交结果逐位相同（不一致就会在松手瞬间看到回弹）。
        for dragged in base.indices {
            for target in base.indices {
                var model = engine.modelForTesting
                model.drawerPages = base
                engine.modelForTesting = model

                var predicted: [Int?] = Array(repeating: nil, count: base.count)
                for slot in base.indices {
                    let destination = slot == dragged
                        ? target
                        : DrawerPagePillLayout.displayIndex(
                            slot: slot, draggedIndex: dragged, targetIndex: target
                        )
                    predicted[destination] = base[slot]
                }

                let changed = engine.moveDrawerPage(from: base[dragged], to: target)
                XCTAssertEqual(changed, dragged != target, "原位应判为无变化")
                XCTAssertEqual(predicted, engine.drawerPages.map { Optional($0) }, "预览 == 提交")
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 页面标题

    func testDrawerPageTitlesRoundTrip() throws {
        let (engine, directory, fileURL) = try makeEngine()
        _ = engine.addDrawerPage(.right)
        engine.setDrawerPageTitle(page: 1, title: "  工作  ")
        XCTAssertEqual(engine.drawerPageTitle(1), "工作", "首尾空白剥除")

        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { _, _ in nil })
        XCTAssertEqual(reloaded.drawerPageTitle(1), "工作")

        // 空标题 = 清除，回落到序号。
        engine.setDrawerPageTitle(page: 1, title: "   ")
        XCTAssertNil(engine.drawerPageTitle(1))
        try? FileManager.default.removeItem(at: directory)
    }

    func testLegacyLayoutJSONWithoutTitlesDecodes() throws {
        let (engine, directory, fileURL) = try makeEngine()
        var model = engine.modelForTesting
        model.drawerPages = [0, 1]
        // 剥掉 drawerPageTitles 键 = 改动前写出的 layout.json。
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(model),
                options: []
            ) as? [String: Any]
        )
        XCTAssertNotNil(json.removeValue(forKey: "drawerPageTitles"))
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL)

        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { _, _ in nil })
        XCTAssertEqual(reloaded.drawerPageTitles, [:])
        XCTAssertEqual(reloaded.drawerPages, [0, 1])
        try? FileManager.default.removeItem(at: directory)
    }

    func testPageDisplayNamePrefersTitleThenOrdinal() {
        let pages = [2, -1, 0, 1]
        // 默认名 = 显示序列里的 1-based 序号（不与索引混用）。
        XCTAssertEqual(
            LayoutModel.pageDisplayName(in: pages, page: -1, titles: [:]),
            LF("panel.page.untitled", 2)
        )
        XCTAssertEqual(
            LayoutModel.pageDisplayName(in: pages, page: 0, titles: [:]),
            LF("panel.page.untitled", 3)
        )
        XCTAssertNotEqual(
            LayoutModel.pageDisplayName(in: pages, page: 2, titles: [:]),
            LayoutModel.pageDisplayName(in: pages, page: 1, titles: [:]),
            "序号按位置而非索引：不同位置必须报出不同名字"
        )
        // 自定义标题优先；空串视同没有标题。
        XCTAssertEqual(
            LayoutModel.pageDisplayName(in: pages, page: 0, titles: ["0": "首页"]),
            "首页"
        )
        XCTAssertEqual(
            LayoutModel.pageDisplayName(in: pages, page: 1, titles: ["1": ""]),
            LF("panel.page.untitled", 4)
        )
    }

    // MARK: 页面图标

    func testDrawerPageIconsRoundTrip() throws {
        let (engine, directory, fileURL) = try makeEngine()
        _ = engine.addDrawerPage(.right)
        engine.setDrawerPageIcon(page: 1, icon: "  star.fill  ")
        XCTAssertEqual(engine.drawerPageIcon(1), "star.fill", "首尾空白剥除")

        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { _, _ in nil })
        XCTAssertEqual(reloaded.drawerPageIcon(1), "star.fill")

        // 空图标 = 清除，回落（主页房子、其余页无图标）。
        engine.setDrawerPageIcon(page: 1, icon: "   ")
        XCTAssertNil(engine.drawerPageIcon(1))
        try? FileManager.default.removeItem(at: directory)
    }

    func testPageIconPrefersCustomThenHomeHouse() {
        XCTAssertEqual(LayoutModel.pageIcon(page: 1, icons: ["1": "star.fill"]), "star.fill")
        // 空串视同没有自定义图标。
        XCTAssertEqual(LayoutModel.pageIcon(page: 1, icons: ["1": ""]), nil)
        // 主页默认房子；其余页无图标退化为纯文本。
        XCTAssertEqual(LayoutModel.pageIcon(page: 0, icons: [:]), "house.fill")
        XCTAssertNil(LayoutModel.pageIcon(page: 1, icons: [:]))
    }

    func testLegacyLayoutJSONWithoutIconsDecodes() throws {
        let (engine, directory, fileURL) = try makeEngine()
        var model = engine.modelForTesting
        model.drawerPages = [0, 1]
        // 剥掉 drawerPageIcons 键 = 本改动前写出的 layout.json。
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(model),
                options: []
            ) as? [String: Any]
        )
        XCTAssertNotNil(json.removeValue(forKey: "drawerPageIcons"))
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL)

        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { _, _ in nil })
        XCTAssertEqual(reloaded.drawerPageIcons, [:])
        XCTAssertEqual(reloaded.drawerPages, [0, 1])
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 删除页面

    func testRemoveDrawerPageDeletesItsBlocksAndTitle() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, fileURL) = try makeEngine()
        _ = engine.addDrawerPage(.right)
        _ = engine.addDrawerPage(.right)
        let home = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: 0
        ))
        _ = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "b", column: 0, row: 0, page: 1
        ))
        engine.setDrawerPageTitle(page: 1, title: "待删")
        engine.setDrawerPageIcon(page: 1, icon: "star.fill")
        XCTAssertEqual(engine.drawerPages, [0, 1, 2])

        let removed = try XCTUnwrap(engine.removeDrawerPage(page: 1))
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.blockID, "b")
        XCTAssertEqual(engine.drawerPages, [0, 2], "只摘掉被删的那一页")
        XCTAssertNil(engine.drawerPageTitle(1), "标题随页面一起清理")
        XCTAssertNil(engine.drawerPageIcon(1), "图标随页面一起清理")
        // 主页与该页之外的块毫发无损。
        XCTAssertEqual(engine.drawerBlocks.count, 1)
        XCTAssertEqual(engine.drawerBlock(placementID: home.placementID)?.page, 0)
        XCTAssertTrue(engine.validate().isEmpty)

        // 删页写盘：重载后页面不复活。
        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        XCTAssertEqual(reloaded.drawerPages, [0, 2])
        XCTAssertEqual(reloaded.drawerBlocks.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testRemoveDrawerPageRejectsHomeAndUnknownPage() throws {
        let (engine, directory, _) = try makeEngine()
        _ = engine.addDrawerPage(.right)
        XCTAssertNil(engine.removeDrawerPage(page: LayoutModel.homePage), "主页恒在")
        XCTAssertNil(engine.removeDrawerPage(page: 42), "不存在的页面")
        XCTAssertEqual(engine.drawerPages, [0, 1])
        try? FileManager.default.removeItem(at: directory)
    }

    func testDeletedPageIsNotResurrectedBySanitization() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, fileURL) = try makeEngine()
        _ = engine.addDrawerPage(.right)
        _ = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: 1
        ))

        // 块与页在同一次写盘里消失：加载净化的"收编块引用散页"不能再把页造出来。
        XCTAssertNotNil(engine.removeDrawerPage(page: 1))
        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        XCTAssertEqual(reloaded.drawerPages, [0])
        XCTAssertTrue(reloaded.drawerBlocks.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 页内隔离

    func testPlaceDrawerBlockOnPageIgnoresOtherPages() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()

        // 主页 (0,0) 占一格；另一页同样落在 (0,0) 不受其影响。
        _ = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: 0
        ))
        let placed = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "b", column: 0, row: 0, page: -1
        ))
        XCTAssertEqual(placed.page, -1)
        XCTAssertEqual(placed.originColumn, 0)
        XCTAssertEqual(placed.originRow, 0)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testGeometryIsScopedToPage() throws {
        register(blockID: "a", kind: .drawer, sizes: [.large], defaultSize: .large)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()

        _ = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "a", page: 0))
        _ = try XCTUnwrap(engine.autoPlaceDrawerBlock(pluginID: "com.test.plugin", blockID: "b", page: -1))

        // 主页只有 large（2×2），另一页只有 small（1×1）。
        XCTAssertEqual(engine.drawerContentRows(page: 0), 2)
        XCTAssertEqual(engine.drawerContentRows(page: -1), 1)
        XCTAssertEqual(engine.occupiedColumns(page: 0), 2)
        XCTAssertEqual(engine.occupiedColumns(page: -1), 1)
        XCTAssertTrue(
            engine.drawerContentSize(page: 0).width > engine.drawerContentSize(page: -1).width
        )
        try? FileManager.default.removeItem(at: directory)
    }

    func testCompactionOnlyTouchesOwnPage() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "c", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()

        // 直接写模型造洞（placeDrawerBlock 会自动压实，造不出整行空洞）：
        // 主页 a(0,0)；-1 页 b(0,0) + c(0,2)，中间留整行空洞。
        var model = engine.modelForTesting
        model.drawerBlocks = [
            PlacedBlock(pluginID: "com.test.plugin", blockID: "a", placementID: "a1", originColumn: 0, originRow: 0, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "com.test.plugin", blockID: "b", placementID: "b1", page: -1, originColumn: 0, originRow: 0, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "com.test.plugin", blockID: "c", placementID: "c1", page: -1, originColumn: 0, originRow: 2, widthColumns: 1, heightRows: 1),
        ]
        model.drawerPages = LayoutModel.normalizedPages(model.drawerPages, blockPages: model.drawerBlocks.map(\.page))
        engine.modelForTesting = model

        engine.compactEmptyRows()

        // 只有 -1 页的空洞被闭合：c 上移到 (0,1)，主页 a 纹丝不动。
        XCTAssertEqual(engine.drawerBlock(placementID: "c1")?.originRow, 1)
        XCTAssertEqual(engine.drawerBlock(placementID: "a1")?.originRow, 0)
        XCTAssertTrue(engine.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testDragPreviewAndCommitStayOnPage() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()

        let a = try XCTUnwrap(engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: 0))
        let b = try XCTUnwrap(engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "b", column: 0, row: 0, page: 1))

        // 在 1 页把 b 拖到 (0,3)（离线压实 + 提交）：主页 a 不参与也不被移动；
        // b 是本页唯一块，压实后回收顶行。
        let preview = engine.previewCommittedArrangement(moving: b.placementID, toColumn: 0, toRow: 3)
        XCTAssertEqual(preview.count, 1, "预览 origins 只含本页块")
        XCTAssertEqual(preview[b.placementID]?.row, 0)
        _ = engine.commitArrangement(preview)
        XCTAssertEqual(engine.drawerBlock(placementID: b.placementID)?.originRow, 0)
        XCTAssertEqual(engine.drawerBlock(placementID: a.placementID)?.originRow, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testPushDownDoesNotDragOtherPageBlocks() throws {
        register(blockID: "a", kind: .drawer, sizes: [.large, .extraLarge], defaultSize: .large)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "c", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()

        // 主页 a(0,0) 2×2 + b(0,2)；1 页 c(0,0)。缩放 a 到 4 列（推挤重排）：
        // 只涉及本页的 b，1 页的 c 不参与也不被移动。
        let a = try XCTUnwrap(engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: 0))
        let b = try XCTUnwrap(engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "b", column: 0, row: 2, page: 0))
        let c = try XCTUnwrap(engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "c", column: 0, row: 0, page: 1))

        let preview = engine.previewArrangement(resizing: a.placementID, toColumns: 4, toRows: 2)
        XCTAssertEqual(preview[a.placementID]?.column, 0)
        XCTAssertEqual(preview[b.placementID]?.row, 2, "同页块不被推挤时保持原位")
        XCTAssertNil(preview[c.placementID], "跨页块不参与推挤")

        XCTAssertTrue(engine.resizeDrawerBlock(placementID: a.placementID, toColumns: 4, toRows: 2))
        XCTAssertEqual(engine.drawerBlock(placementID: b.placementID)?.originRow, 2)
        XCTAssertEqual(engine.drawerBlock(placementID: c.placementID)?.originRow, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testMoveDrawerBlockBoundsIgnoreOtherPages() throws {
        register(blockID: "a", kind: .drawer, sizes: [.extraLarge], defaultSize: .extraLarge)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine(userMaxColumns: 4)

        // 主页被 4 列宽的块占满：1 页的块移动仍可用全部列空间
        // （validColumnRange 只看同页其他块）。
        _ = try XCTUnwrap(engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: 0))
        let b = try XCTUnwrap(engine.placeDrawerBlock(pluginID: "com.test.plugin", blockID: "b", column: 0, row: 0, page: 1))

        XCTAssertTrue(engine.moveDrawerBlock(placementID: b.placementID, toColumn: 2, toRow: 0))
        XCTAssertEqual(engine.drawerBlock(placementID: b.placementID)?.originColumn, 2)
        try? FileManager.default.removeItem(at: directory)
    }

    func testReorderDrawerBlocksOnlyTouchesOwnPage() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "b", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()

        // 主页 a(0,0)；1 页 b(0,2) 留洞（直接写模型），重排 1 页后闭合。
        var model = engine.modelForTesting
        model.drawerBlocks = [
            PlacedBlock(pluginID: "com.test.plugin", blockID: "a", placementID: "a1", originColumn: 0, originRow: 0, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "com.test.plugin", blockID: "b", placementID: "b1", page: 1, originColumn: 0, originRow: 2, widthColumns: 1, heightRows: 1),
        ]
        model.drawerPages = LayoutModel.normalizedPages(model.drawerPages, blockPages: model.drawerBlocks.map(\.page))
        engine.modelForTesting = model

        engine.reorderDrawerBlocks(page: 1)

        XCTAssertEqual(engine.drawerBlock(placementID: "b1")?.originRow, 0)
        XCTAssertEqual(engine.drawerBlock(placementID: "a1")?.originRow, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 净化与校验

    func testSanitizationHealsOverlapWithinPageOnly() throws {
        register(blockID: "clean", kind: .drawer, sizes: [.small], defaultSize: .small)
        register(blockID: "x", kind: .drawer, sizes: [.large], defaultSize: .large)
        let (engine, directory, fileURL) = try makeEngine()
        var model = engine.modelForTesting
        // -1 页存在粘连重叠对（历史 bug 形态）；主页干净。
        model.drawerBlocks = [
            PlacedBlock(pluginID: "com.test.plugin", blockID: "clean", placementID: "home", originColumn: 0, originRow: 5, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "com.test.plugin", blockID: "x", placementID: "x1", page: -1, originColumn: 0, originRow: 0, widthColumns: 2, heightRows: 2),
            PlacedBlock(pluginID: "com.test.plugin", blockID: "x", placementID: "x2", page: -1, originColumn: 0, originRow: 0, widthColumns: 2, heightRows: 2),
        ]
        model.drawerPages = LayoutModel.normalizedPages(model.drawerPages, blockPages: model.drawerBlocks.map(\.page))
        engine.modelForTesting = model

        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        // -1 页的重叠对被去重叠（x2 下移）；主页块的行号原样保留。
        XCTAssertEqual(reloaded.drawerBlock(placementID: "home")?.originRow, 5)
        XCTAssertEqual(reloaded.drawerBlock(placementID: "x1")?.originRow, 0)
        XCTAssertEqual(reloaded.drawerBlock(placementID: "x2")?.originRow, 2)
        XCTAssertTrue(reloaded.validate().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testValidateDoesNotReportCrossPageOverlap() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, _) = try makeEngine()
        var model = engine.modelForTesting
        // 两页各有一块完全同格：跨页不算重叠。
        model.drawerBlocks = [
            PlacedBlock(pluginID: "com.test.plugin", blockID: "a", placementID: "p0", page: 0, originColumn: 0, originRow: 0, widthColumns: 1, heightRows: 1),
            PlacedBlock(pluginID: "com.test.plugin", blockID: "a", placementID: "p1", page: 1, originColumn: 0, originRow: 0, widthColumns: 1, heightRows: 1),
        ]
        model.drawerPages = LayoutModel.normalizedPages(model.drawerPages, blockPages: model.drawerBlocks.map(\.page))
        engine.modelForTesting = model

        XCTAssertTrue(engine.validate().isEmpty)

        // 同页同格才算重叠。
        var samePage = model
        samePage.drawerBlocks[1].page = 0
        engine.modelForTesting = samePage
        XCTAssertEqual(engine.validate().count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 旧版 layout.json 兼容

    func testLegacyLayoutJSONDecodesWithHomePageDefault() throws {
        let (_, directory, fileURL) = try makeEngine()
        // 没有 page / drawerPages 键的旧版文件。
        let legacy = """
        {
          "schemaVersion": 1,
          "maxColumns": 4,
          "compactSlots": [],
          "drawerBlocks": [
            {
              "pluginID": "com.test.plugin",
              "blockID": "a",
              "placementID": "legacy-1",
              "originColumn": 0,
              "originRow": 0,
              "widthColumns": 2,
              "heightRows": 1
            }
          ],
          "enabledPluginIDs": []
        }
        """
        try legacy.data(using: .utf8)!.write(to: fileURL)

        let reloaded = LayoutEngine(fileURL: fileURL, blockResolver: { _, _ in nil })
        XCTAssertEqual(reloaded.drawerPages, [0])
        let block = try XCTUnwrap(reloaded.drawerBlock(placementID: "legacy-1"))
        XCTAssertEqual(block.page, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testPagesAndBlockPageRoundTripThroughDisk() throws {
        register(blockID: "a", kind: .drawer, sizes: [.small], defaultSize: .small)
        let (engine, directory, fileURL) = try makeEngine()
        _ = engine.addDrawerPage(.left)
        _ = try XCTUnwrap(engine.placeDrawerBlock(
            pluginID: "com.test.plugin", blockID: "a", column: 0, row: 0, page: -1
        ))

        let model = try loadModel(from: fileURL)
        XCTAssertEqual(model.drawerPages, [-1, 0])
        XCTAssertEqual(model.drawerBlocks.first?.page, -1)
        try? FileManager.default.removeItem(at: directory)
    }
}
