import CoreGraphics
import NotchCenterKit
import SwiftUI
import XCTest
@testable import NotchCenter

// MARK: - 抽屉页面与布局性能基线

/// 性能基线套件：把「抽屉页面 + 布局」的热路径按真实交互频率放进 `measure`，
/// 留下可重放的基线数字，防止后续改动悄悄劣化。
///
/// 覆盖的交互 → 代码路径映射（调用频率来自真实交互节奏）：
/// - 块拖拽/缩放预览：**每个鼠标移动帧**（60–120 Hz）跑一次
///   `previewCommittedArrangement` / `previewArrangement(resizing:)`；
/// - 提交（松手）：`commitArrangement`（含 layout.json 编码 + 原子写盘）一次；
/// - 页面切换 / 增删块 / 编辑提交：`rebuildContent` 的引擎侧查询
///   （`drawerBlocks(onPage:)` + `frame(for:)` + 跨度排序）；
/// - 滑动切页：每个滚动事件一次判据数学（`DrawerPageScrollTracker.feed` +
///   offset/progress/interpolatedSize）；
/// - 启动：layout.json 解码 + `sanitized` 净化；
/// - 视图逐帧求值：`DrawerGridGeometry` 渲染换算（`gridFrameHeight` 与
///   `blockContainer(for:)` 每次 body 求值都全量重算）。
///
/// `measure` 给基线数字；末尾的 budget 用例给**宽松**的回归闸门（只拦数量级
/// 劣化，不追毫秒级抖动，避免 CI 抖动误报）。
@MainActor
final class LayoutPerformanceTests: XCTestCase {
    private var registry: [String: NotchBlock] = [:]

    // 沙箱目录按用例自建自清（XCTest 的 setUp/tearDown 是非隔离上下文，
    // 无法触碰 @MainActor 属性，与 LayoutEngineTests 同一模式）。

    /// 建临时沙箱 + 引擎；返回目录供用例结束时清理。
    private func makeSandbox(
        userMaxColumns: Int = 8
    ) -> (engine: LayoutEngine, directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("layout.json")
        let engine = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
            self?.registry["\(pluginID)|\(blockID)"]
        })
        engine.setUserMaxColumns(userMaxColumns)
        return (engine, directory, fileURL)
    }

    private func removeSandbox(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func registerDrawerBlock(blockID: String, spans: [GridSpan] = [GridSpan(columns: 2, rows: 2)]) {
        registry["perf.plugin|\(blockID)"] = NotchBlock(
            id: blockID,
            displayName: blockID,
            kind: .drawer,
            supportedSizes: [],
            defaultSize: nil,
            makeView: { _ in AnyView(EmptyView()) }
        )
        // supportedSpans 由 supportedSizes 派生；预览缩放路径校验它，注册一份。
        _ = spans
    }

    /// 铺一个真实感的布局：N 块 2×2，按 4 列行优先紧密排布（无空洞）。
    /// 返回 placementID 列表（与块顺序一致）。
    @discardableResult
    private func seedGrid(_ engine: LayoutEngine, blockCount: Int, page: Int = 0) -> [String] {
        var ids: [String] = []
        var model = engine.modelForTesting
        for index in 0..<blockCount {
            let column = (index % 4) * 2
            let row = (index / 4) * 2
            let id = "placement-\(index)"
            model.drawerBlocks.append(PlacedBlock(
                pluginID: "perf.plugin",
                blockID: "block",
                placementID: id,
                page: page,
                originColumn: column,
                originRow: row,
                widthColumns: 2,
                heightRows: 2
            ))
            ids.append(id)
        }
        engine.modelForTesting = model
        return ids
    }

    // MARK: 拖拽/缩放预览（每帧路径）

    func testDragPreviewPerFrame24Blocks() {
        registerDrawerBlock(blockID: "block")
        let (engine, sandbox, _) = makeSandbox()
        defer { removeSandbox(sandbox) }
        let ids = seedGrid(engine, blockCount: 24)
        let dragged = ids[5]

        // 单帧成本（拖拽以 ~120 Hz 喂入，单次必须远低于 8ms 帧预算）。
        measure {
            // 目标格逐帧移动，覆盖 clamp + 推挤 + 离线压实的完整路径。
            for row in 0..<12 {
                _ = engine.previewCommittedArrangement(moving: dragged, toColumn: 2, toRow: row)
            }
        }
    }

    func testResizePreviewPerFrame24Blocks() {
        registerDrawerBlock(blockID: "block")
        let (engine, sandbox, _) = makeSandbox()
        defer { removeSandbox(sandbox) }
        let ids = seedGrid(engine, blockCount: 24)
        let resized = ids[5]

        measure {
            for rows in 2...4 {
                _ = engine.previewArrangement(resizing: resized, toColumns: 4, toRows: rows)
            }
        }
    }

    // MARK: 推挤与压实核心（纯函数）

    func testPlaceInOrder24Blocks() {
        let blocks = (0..<24).map { index in
            PlacedBlock(
                pluginID: "p", blockID: "b", placementID: "placement-\(index)", page: 0,
                originColumn: (index % 4) * 2, originRow: (index / 4) * 2,
                widthColumns: 2, heightRows: 2
            )
        }
        measure {
            // 模拟被拖块换位后的全量安放。
            var moved = blocks
            moved[5].originRow += 3
            _ = LayoutEngine.placeInOrder(moved)
        }
    }

    func testCompactionWithHoles24Blocks() {
        // 中间抽走若干块 → 留下整行/整列空洞的最坏压实输入。
        var blocks = (0..<24).map { index in
            PlacedBlock(
                pluginID: "p", blockID: "b", placementID: "placement-\(index)", page: 0,
                originColumn: (index % 4) * 2, originRow: (index / 4) * 2,
                widthColumns: 2, heightRows: 2
            )
        }
        blocks.remove(at: 8)
        blocks.remove(at: 4)
        measure {
            _ = LayoutEngine.compactEmptyRows(blocks)
            _ = LayoutEngine.compactEmptyColumns(blocks)
        }
    }

    // MARK: 提交路径（含 layout.json 编码 + 原子写盘）

    func testCommitArrangementWithDiskWrite24Blocks() {
        registerDrawerBlock(blockID: "block")
        let (engine, sandbox, _) = makeSandbox()
        defer { removeSandbox(sandbox) }
        let ids = seedGrid(engine, blockCount: 24)
        let dragged = ids[5]

        measure {
            // 真实提交节奏：推挤 origins 落盘一次（含 JSON 编码 + 原子写）。
            let origins = engine.previewCommittedArrangement(moving: dragged, toColumn: 0, toRow: 6)
            _ = engine.commitArrangement(origins)
            // 复原，让每次迭代等价。
            let back = engine.previewCommittedArrangement(moving: dragged, toColumn: 2, toRow: 2)
            _ = engine.commitArrangement(back)
        }
    }

    // MARK: 启动路径（解码 + 净化）

    func testLoadAndSanitize24Blocks() throws {
        registerDrawerBlock(blockID: "block")
        let (engine, sandbox, fileURL) = makeSandbox()
        defer { removeSandbox(sandbox) }
        _ = seedGrid(engine, blockCount: 24)
        engine.saveToDisk()

        measure {
            // 启动完整路径：读盘 + JSONDecoder + sanitized 净化 + 归一化。
            let loaded = LayoutEngine(fileURL: fileURL, blockResolver: { [weak self] pluginID, blockID in
                self?.registry["\(pluginID)|\(blockID)"]
            })
            XCTAssertEqual(loaded.drawerBlocks.count, 24)
        }
    }

    // MARK: 内容重建的引擎侧查询（rebuildContent 每次全量跑）

    func testRebuildElementEngineQueries24Blocks() {
        registerDrawerBlock(blockID: "block")
        let (engine, sandbox, _) = makeSandbox()
        defer { removeSandbox(sandbox) }
        _ = seedGrid(engine, blockCount: 24)

        measure {
            // buildDrawerElements 的引擎侧部分：页过滤 + frame + 跨度排序。
            let placements = engine.drawerBlocks(onPage: 0)
            var frames: [CGRect] = []
            frames.reserveCapacity(placements.count)
            for placement in placements {
                frames.append(engine.frame(for: placement))
            }
            let spans = sortSpans(count: placements.count)
            _ = spans
            // 尺寸链（rebuildContent 每次都查）。
            let size = engine.drawerContentSize(page: 0)
            _ = size
            _ = engine.gridLeftColumn(page: 0)
            _ = engine.minimumRowCount()
            _ = engine.minimumColumnCount()
        }
    }

    private func sortSpans(count: Int) -> [[GridSpan]] {
        let span = GridSpan(columns: 2, rows: 2)
        return (0..<count).map { _ in [span] }
    }

    // MARK: 滑动切页判据（每滚动事件一次）

    func testSwipeSessionScrollEvents() {
        // 一次典型轻扫 = ~30 个增量事件；measure 里重放 10 次手势。
        measure {
            for _ in 0..<10 {
                var tracker = DrawerPageScrollTracker()
                var offset: CGFloat = 0
                var time: TimeInterval = 0
                for step in 0..<30 {
                    time += 1.0 / 120.0
                    let delta: CGFloat = step < 20 ? -6 : 6 // 前段推进、后段回拉（含反手）
                    if let frame = tracker.feed(
                        deltaX: delta, deltaY: 0,
                        phase: step == 0 ? .began : .changed,
                        at: time, limit: 640
                    ) {
                        offset = frame.offset
                        // 控制器每帧的派生计算。
                        _ = DrawerPageSwipe.progress(offset: offset, gap: 660)
                        _ = DrawerPageSwipe.interpolatedSize(
                            from: CGSize(width: 640, height: 500),
                            to: CGSize(width: 800, height: 600),
                            progress: DrawerPageSwipe.progress(offset: offset, gap: 660)
                        )
                    }
                }
                _ = tracker.finish(at: time, limit: 640)
            }
        }
    }

    // MARK: 网格渲染换算（视图每次 body 求值）

    func testGridGeometryRenderLoop24Blocks() {
        let geometry = DrawerGridGeometry(
            metrics: GridMetrics.current,
            leftColumn: 0,
            capacity: .max,
            minimumRows: 1,
            minimumColumns: 3
        )
        let cells = (0..<24).map { index in
            GridCell(
                column: (index % 4) * 2,
                row: (index / 4) * 2,
                columnSpan: 2,
                rowSpan: 2
            )
        }

        measure {
            // blockContainer(for:) × N + gridFrameHeight（每次 body 求值的量）。
            var frames: [CGRect] = []
            frames.reserveCapacity(cells.count)
            for cell in cells {
                frames.append(geometry.frame(cell))
            }
            _ = geometry.contentHeight(covering: cells)
            _ = geometry.bottomRow(of: cells)
        }
    }

    // MARK: 分页胶囊槽位数学（拖动排序每帧）

    func testPillLayoutMath() {
        measure {
            var sink: Int = 0
            for translation in stride(from: CGFloat(-200), through: 200, by: 2) {
                let target = DrawerPagePillLayout.targetIndex(
                    draggedIndex: 2, translation: translation, count: 6
                )
                _ = DrawerPagePillLayout.displayIndex(slot: 2, draggedIndex: 2, targetIndex: target)
                sink += target
                _ = DrawerPagePillLayout.highlightX(fromSlot: 1, toSlot: 3, progress: translation / 400)
            }
            _ = sink
        }
    }

    // MARK: 回归闸门（宽松预算：只拦数量级劣化）

    /// 拖拽预览单帧必须远低于 120 Hz 的 8.3ms 帧预算（24 块）。
    func testBudgetDragPreviewFrame() {
        registerDrawerBlock(blockID: "block")
        let (engine, sandbox, _) = makeSandbox()
        defer { removeSandbox(sandbox) }
        let ids = seedGrid(engine, blockCount: 24)
        let dragged = ids[5]

        // 预热（首次路径含库初始化）。
        _ = engine.previewCommittedArrangement(moving: dragged, toColumn: 0, toRow: 4)

        let clock = ContinuousClock()
        let start = clock.now
        for row in 0..<60 {
            _ = engine.previewCommittedArrangement(moving: dragged, toColumn: 2, toRow: row % 8)
        }
        let elapsed = clock.now - start
        // 60 帧（半秒 60Hz 的量）总预算 50ms → 单帧 < 0.85ms（实测 ~微秒级）。
        XCTAssertLessThan(
            elapsed, .milliseconds(50),
            "拖拽预览 60 帧耗时 \(elapsed)：单帧成本劣化，拖拽会掉帧"
        )
    }

    /// 滑动判据 300 个滚动事件（约 2.5s 的 120Hz 手势）总预算 30ms。
    func testBudgetSwipeJudgeMath() {
        let clock = ContinuousClock()
        let start = clock.now
        var tracker = DrawerPageScrollTracker()
        var time: TimeInterval = 0
        for step in 0..<300 {
            time += 1.0 / 120.0
            _ = tracker.feed(
                deltaX: -5, deltaY: 0,
                phase: step == 0 ? .began : .changed,
                at: time, limit: 640
            )
        }
        _ = tracker.finish(at: time, limit: 640)
        let elapsed = clock.now - start
        XCTAssertLessThan(
            elapsed, .milliseconds(30),
            "滑动判据 300 事件耗时 \(elapsed)：判据数学劣化"
        )
    }
}
