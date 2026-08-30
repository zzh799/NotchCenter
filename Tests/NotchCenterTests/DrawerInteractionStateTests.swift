import CoreGraphics
import NotchCenterKit
import XCTest
@testable import NotchCenter

/// 拖拽 / 缩放状态机的时序契约回归。
///
/// 这些状态此前是 `DrawerPanelView` 上 5 个互不相干的 `@State`，散落在手势
/// 回调里各自维护；因为视图无法在单测里构造，下面的契约**一条测试都没有**：
/// 松手顺序、清空的时机、预览原点与提交布局的一致性。
@MainActor
final class DrawerInteractionStateTests: XCTestCase {
    private let metrics = GridMetrics(
        cellWidth: 150, cellHeight: 120, spacing: 12,
        contentPadding: 16, topBarHeight: 36
    )

    /// 假 Bridge：记录事件序列，并能在提交时回读状态机的 phase。
    private final class Recorder {
        var events: [String] = []
        var origins: [String: LayoutEngine.GridOrigin] = [:]
        var phasesAtCommit: [DrawerInteractionState.Phase] = []

        func bridge() -> DrawerInteractionState.Bridge {
            DrawerInteractionState.Bridge(
                previewMove: { [weak self] _, _, _ in
                    self?.events.append("previewMove")
                    return self?.origins ?? [:]
                },
                previewResize: { [weak self] _, _, _ in
                    self?.events.append("previewResize")
                    return self?.origins ?? [:]
                },
                commitMove: { [weak self] _, _, _ in
                    self?.events.append("commitMove")
                    if let phase = self?.phaseProvider?() { self?.phasesAtCommit.append(phase) }
                },
                commitResize: { [weak self] _, _, _ in
                    self?.events.append("commitResize")
                    if let phase = self?.phaseProvider?() { self?.phasesAtCommit.append(phase) }
                },
                setReorderPreview: { [weak self] origin, _ in
                    self?.events.append(origin == nil ? "clearReorderPreview" : "setReorderPreview")
                }
            )
        }

        /// 由测试注入：在提交那一刻读取状态机的 phase。
        var phaseProvider: (() -> DrawerInteractionState.Phase)?
    }

    private func placement(
        placementID: String = "a",
        column: Int = 0,
        row: Int = 0,
        columns: Int = 1,
        rows: Int = 1
    ) -> PlacedBlock {
        PlacedBlock(
            pluginID: "p", blockID: "b", placementID: placementID,
            originColumn: column, originRow: row,
            widthColumns: columns, heightRows: rows
        )
    }

    // MARK: - 阶段迁移

    func testPhaseTransitions() {
        let state = DrawerInteractionState(bridge: Recorder().bridge())
        XCTAssertEqual(state.phase, .idle)

        state.beginDrag("a")
        XCTAssertEqual(state.draggingPlacementID, "a")
        XCTAssertNil(state.resizingPlacementID)

        state.endDrag("a", column: 0, row: 0)
        XCTAssertEqual(state.phase, .idle)
    }

    func testResizeStartsAtCommittedSpan() {
        // 按下瞬间位移为零：预览跨度 = 当前提交跨度，不会瞬间缩小。
        let state = DrawerInteractionState(bridge: Recorder().bridge())
        state.updateResize(
            "a",
            translation: .zero,
            placement: placement(columns: 2, rows: 3),
            supportedSpans: [GridSpan(columns: 1, rows: 1), GridSpan(columns: 2, rows: 3)],
            metrics: metrics
        )
        XCTAssertEqual(state.previewSpan(for: "a"), GridSpan(columns: 2, rows: 3))
        XCTAssertTrue(state.isResizing("a"))
    }

    func testResizeSnapsToSupportedSpan() {
        let state = DrawerInteractionState(bridge: Recorder().bridge())
        // 向右下拖 300/264 pt ≈ (1.85, 2) 格 → 吸附到 3×4。
        state.updateResize(
            "a",
            translation: CGSize(width: 300, height: 264),
            placement: placement(columns: 1, rows: 2),
            supportedSpans: [GridSpan(columns: 1, rows: 2), GridSpan(columns: 3, rows: 4)],
            metrics: metrics
        )
        XCTAssertEqual(state.previewSpan(for: "a"), GridSpan(columns: 3, rows: 4))
    }

    func testDragDoesNotTakeOverDuringResize() {
        // 握把手势优先：缩放期间 beginDrag 不接管。
        let state = DrawerInteractionState(bridge: Recorder().bridge())
        state.updateResize(
            "a",
            translation: .zero,
            placement: placement(),
            supportedSpans: [GridSpan(columns: 1, rows: 1)],
            metrics: metrics
        )
        state.beginDrag("a")
        XCTAssertNil(state.draggingPlacementID)
        XCTAssertEqual(state.resizingPlacementID, "a")
    }

    // MARK: - 渲染原点

    func testResolveOriginExcludesTheDraggedBlock() {
        let recorder = Recorder()
        recorder.origins = [
            "a": LayoutEngine.GridOrigin(column: 4, row: 4),
            "b": LayoutEngine.GridOrigin(column: 0, row: 3)
        ]
        let state = DrawerInteractionState(bridge: recorder.bridge())
        let committed = LayoutEngine.GridOrigin(column: 0, row: 0)

        state.beginDrag("a")
        state.updateDrag("a", column: 4, row: 4, span: GridSpan(columns: 1, rows: 1))

        // 被拖块用提交原点：它的视觉位置由容器的 dragOffset 跟随光标，
        // 再叠一层推挤预览会双重位移。
        XCTAssertEqual(state.resolveOrigin(placementID: "a", committed: committed), committed)
        // 其余块用推挤后的预览位置。
        XCTAssertEqual(
            state.resolveOrigin(placementID: "b", committed: committed),
            LayoutEngine.GridOrigin(column: 0, row: 3)
        )
    }

    // MARK: - 松手时序

    func testEndDragSequenceReturnsToIdleBeforeCommit() {
        let recorder = Recorder()
        recorder.origins = ["a": LayoutEngine.GridOrigin(column: 1, row: 1)]
        let state = DrawerInteractionState(bridge: recorder.bridge())
        recorder.phaseProvider = { state.phase }

        state.beginDrag("a")
        state.updateDrag("a", column: 1, row: 1, span: GridSpan(columns: 1, rows: 1))
        state.endDrag("a", column: 1, row: 1)

        XCTAssertEqual(
            recorder.events,
            ["previewMove", "setReorderPreview", "clearReorderPreview", "commitMove"]
        )
        // 提交那一刻必须已经回到 idle：否则 resolveOrigin 那一帧仍走
        //「排除被拖块」分支，块会先弹回原位再瞬移到落点。
        XCTAssertEqual(recorder.phasesAtCommit, [.idle])
        XCTAssertTrue(state.previewOrigins.isEmpty, "提交后不得残留预览原点")
    }

    func testUpdateDragIgnoresIncompleteOrigins() {
        // 被拖块不在结果里（例如块已被移除）时不写半截预览。
        let recorder = Recorder()
        recorder.origins = ["b": LayoutEngine.GridOrigin(column: 0, row: 1)]
        let state = DrawerInteractionState(bridge: recorder.bridge())

        state.beginDrag("a")
        state.updateDrag("a", column: 2, row: 2, span: GridSpan(columns: 1, rows: 1))

        XCTAssertTrue(state.previewOrigins.isEmpty)
        XCTAssertFalse(recorder.events.contains("setReorderPreview"))
    }

    func testCommitResizeClearsStateEvenWithoutSpan() {
        // 手势已结束但从未产生预览跨度（例如按下即松手）：状态仍须清干净。
        let recorder = Recorder()
        let state = DrawerInteractionState(bridge: recorder.bridge())
        state.updateResize(
            "a",
            translation: .zero,
            placement: placement(),
            supportedSpans: [GridSpan(columns: 1, rows: 1)],
            metrics: metrics
        )
        state.commitResize("a")

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.previewSpan(for: "a"))
        XCTAssertEqual(recorder.events, ["commitResize"])
    }

    // MARK: - 复位

    func testResetClearsEverything() {
        let recorder = Recorder()
        recorder.origins = ["a": LayoutEngine.GridOrigin(column: 1, row: 1)]
        let state = DrawerInteractionState(bridge: recorder.bridge())

        state.beginDrag("a")
        state.updateDrag("a", column: 1, row: 1, span: GridSpan(columns: 1, rows: 1))
        state.reset()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.previewOrigins.isEmpty)
        XCTAssertTrue(recorder.events.contains("clearReorderPreview"))
    }

    // MARK: - 预览即最终布局（真引擎 · 随机拖拽）

    private func makeEngine(
        blocks: [(String, Int, Int, Int, Int)],
        maxColumns: Int = 4
    ) -> LayoutEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-interaction-\(UUID().uuidString).json")
        let engine = LayoutEngine(fileURL: url, blockResolver: { _, _ in nil })
        var model = LayoutModel()
        model.maxColumns = maxColumns
        model.drawerBlocks = blocks.map { item in
            PlacedBlock(
                pluginID: "p", blockID: "b", placementID: item.0,
                originColumn: item.1, originRow: item.2,
                widthColumns: item.3, heightRows: item.4
            )
        }
        engine.modelForTesting = model
        engine.updateScreenConstraint(width: 1440)
        return engine
    }

    /// 复刻 `clampedDropTarget`：列夹到引擎的合法区间，行非负。
    private func clamped(
        _ engine: LayoutEngine,
        _ placementID: String,
        _ column: Int,
        _ row: Int
    ) -> (column: Int, row: Int) {
        let bounds = engine.dropTargetColumnBounds(placementID: placementID)
        return (min(max(column, bounds.lower), bounds.upper), max(row, 0))
    }

    /// 用真 `LayoutEngine` 驱动状态机：把「预览原点 == 松手后逐块真实原点」
    /// 这条契约从引擎层（`DragUnificationTests`）顶到视图序列层——
    /// 中间多了一层状态机，预览必须原样传递，不能被截断或延后一帧。
    func testPreviewOriginsMatchCommittedLayoutOverRandomDrags() {
        let engine = makeEngine(blocks: [
            ("a", 0, 0, 2, 2),
            ("b", 2, 0, 2, 1),
            ("c", 0, 2, 1, 1)
        ])
        let ids = ["a", "b", "c"]
        let state = DrawerInteractionState(
            bridge: DrawerInteractionState.Bridge(
                previewMove: { [weak self] id, column, row in
                    guard let self else { return [:] }
                    let target = self.clamped(engine, id, column, row)
                    return engine.previewCommittedArrangement(
                        moving: id, toColumn: target.column, toRow: target.row
                    )
                },
                previewResize: { _, _, _ in [:] },
                commitMove: { [weak self] id, column, row in
                    guard let self else { return }
                    let target = self.clamped(engine, id, column, row)
                    let origins = engine.previewCommittedArrangement(
                        moving: id, toColumn: target.column, toRow: target.row
                    )
                    _ = engine.commitArrangement(origins)
                },
                commitResize: { _, _, _ in },
                setReorderPreview: { _, _ in }
            )
        )

        var rng = SystemRandomNumberGenerator()
        for step in 0..<200 {
            guard let id = ids.randomElement(using: &rng) else { break }
            let column = Int.random(in: -2...4, using: &rng)
            let row = Int.random(in: 0...4, using: &rng)
            let span = engine.drawerBlocks.first { $0.placementID == id }
                .map { GridSpan(columns: $0.widthColumns, rows: $0.heightRows) }
                ?? GridSpan(columns: 1, rows: 1)

            state.beginDrag(id)
            state.updateDrag(id, column: column, row: row, span: span)
            let previewed = state.previewOrigins
            // 预览必须覆盖全体块，否则有些块会在拖动期间停在旧位置。
            XCTAssertEqual(
                Set(previewed.keys),
                Set(engine.drawerBlocks.map(\.placementID)),
                "step \(step)：预览未覆盖全体块"
            )

            state.endDrag(id, column: column, row: row)
            for block in engine.drawerBlocks {
                XCTAssertEqual(
                    previewed[block.placementID],
                    LayoutEngine.GridOrigin(column: block.originColumn, row: block.originRow),
                    "step \(step)：\(block.placementID) 预览与提交不一致——松手会跳一下"
                )
            }
            // 不变量与 `DragReorderReproTests` 一致：无重叠、行号不失控、
            // 列跨度不超容量。这里**不调 `validate()`**——测试的
            // blockResolver 返回 nil，它会为此报无关的 unknownBlock。
            let maxColumns = engine.effectiveMaxColumns()
            let minColumn = engine.drawerBlocks.map(\.originColumn).min() ?? 0
            for block in engine.drawerBlocks {
                XCTAssertGreaterThanOrEqual(block.originRow, 0, "step \(step)")
                XCTAssertLessThan(block.originRow, 40, "step \(step)：推挤失控")
                XCTAssertLessThanOrEqual(
                    (block.originColumn - minColumn) + block.widthColumns,
                    maxColumns,
                    "step \(step)：\(block.placementID) 超出列容量"
                )
            }
            for (index, block) in engine.drawerBlocks.enumerated() {
                for other in engine.drawerBlocks.dropFirst(index + 1) {
                    XCTAssertFalse(
                        LayoutEngine.rectsOverlap(block, other),
                        "step \(step)：\(block.placementID) 与 \(other.placementID) 重叠"
                    )
                }
            }
        }
    }
}
