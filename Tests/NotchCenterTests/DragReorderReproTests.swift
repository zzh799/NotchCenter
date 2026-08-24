import XCTest
@testable import NotchCenter
import NotchCenterKit

// 拖拽排序复现测试：完全模拟 DrawerPanelView.onCommitDrag 的调用序列
// （previewArrangement → commitArrangement），暴力重放随机拖拽，
// 校验提交后的布局不变量：块间不得重叠、行号不得失控增长。
@MainActor
final class DragReorderReproTests: XCTestCase {

    private func makeEngine(
        blocks: [(String, String, Int, Int, Int, Int)],
        maxColumns: Int = 4,
        screenWidth: CGFloat = 1440
    ) -> LayoutEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-repro-\(UUID().uuidString).json")
        let engine = LayoutEngine(fileURL: url, blockResolver: { _, _ in nil })
        // 直接写入模型：绕过 blockResolver（视图拖拽路径不依赖它）。
        var model = LayoutModel()
        model.maxColumns = maxColumns
        model.drawerBlocks = blocks.map { item in
            PlacedBlock(
                pluginID: "p", blockID: "b", placementID: item.0,
                originColumn: item.2, originRow: item.3,
                widthColumns: item.4, heightRows: item.5
            )
        }
        engine.modelForTesting = model
        engine.updateScreenConstraint(width: screenWidth)
        return engine
    }

    private func overlaps(_ engine: LayoutEngine) -> [(String, String)] {
        var result: [(String, String)] = []
        let blocks = engine.drawerBlocks
        for i in 0..<blocks.count {
            for j in (i + 1)..<blocks.count {
                let a = blocks[i], b = blocks[j]
                let ax2 = a.originColumn + a.widthColumns
                let ay2 = a.originRow + a.heightRows
                let bx2 = b.originColumn + b.widthColumns
                let by2 = b.originRow + b.heightRows
                if a.originColumn < bx2 && b.originColumn < ax2
                    && a.originRow < by2 && b.originRow < ay2 {
                    result.append((a.placementID, b.placementID))
                }
            }
        }
        return result
    }

    /// 视图语义：target = 原始位置 + 四舍五入(位移/格尺寸)。这里直接用绝对目标格。
    private func dragAndCommit(_ engine: LayoutEngine, id: String, toColumn: Int, toRow: Int) {
        let origins = engine.previewArrangement(moving: id, toColumn: toColumn, toRow: toRow)
        _ = engine.commitArrangement(origins)
    }

    func testRepeatedDragsNeverProduceOverlapOrRunawayRows() {
        // 与用户真实布局近似的块集合（混合宽高）。
        let engine = makeEngine(blocks: [
            ("a", "n", 0, 0, 2, 2),
            ("b", "s", 0, 2, 4, 1),
            ("c", "s", 1, 3, 2, 2),
            ("d", "s", 2, 0, 1, 1),
            ("e", "n", 0, 5, 2, 2),
            ("f", "s", 2, 5, 2, 1),
        ])

        var rng = SeededRandom(seed: 20260822)
        var maxRowEver = 0

        for step in 0..<400 {
            let blocks = engine.drawerBlocks
            let victim = blocks[Int(rng.next() % UInt64(blocks.count))]
            // 随机目标：含深度越界（负列、超列），模拟真实拖拽的任意落点，
            // 覆盖向左拖出自动左扩的 clamp 路径。
            let targetCol = Int(rng.next() % 8) - 4
            let targetRow = Int(rng.next() % 8) - 1
            dragAndCommit(engine, id: victim.placementID, toColumn: targetCol, toRow: targetRow)

            let bad = overlaps(engine)
            XCTAssertTrue(
                bad.isEmpty,
                "step \(step): 提交后出现重叠 \(bad)，布局=\(engine.drawerBlocks)"
            )
            let row = engine.drawerBlocks.map { $0.originRow + $0.heightRows }.max() ?? 0
            maxRowEver = max(maxRowEver, row)
            XCTAssertLessThan(
                row, 40,
                "step \(step): 行号失控 row=\(row)，布局=\(engine.drawerBlocks)"
            )
            // 列双向扩大的容量不变量：合并后列跨度不得超过容量（左扩/右扩皆然）。
            let minCol = engine.drawerBlocks.map(\.originColumn).min() ?? 0
            let maxCol = engine.drawerBlocks.map { $0.originColumn + $0.widthColumns }.max() ?? 0
            XCTAssertLessThanOrEqual(
                maxCol - minCol, engine.effectiveMaxColumns(),
                "step \(step): 列跨度超容量 span=\(maxCol - minCol)，布局=\(engine.drawerBlocks)"
            )
        }
        _ = maxRowEver
    }

    /// 粘连对回归：两个完全同矩形的块一旦出现，任何后续拖拽都不应使其行号暴涨。
    func testGluedPairDoesNotRunAway() {
        let engine = makeEngine(blocks: [
            ("x", "s", 1, 1, 2, 2),
            ("y", "s", 1, 1, 2, 2), // 人造粘连对（历史脏数据）
            ("z", "s", 0, 0, 4, 1),
        ])
        dragAndCommit(engine, id: "z", toColumn: 0, toRow: 3)
        let rows = engine.drawerBlocks.map(\.originRow)
        XCTAssertLessThan(rows.max() ?? 0, 20, "粘连对行号暴涨: \(engine.drawerBlocks)")
    }

    /// 真实事故数据回归（2026-08 用户 layout.json 快照）：旧算法的粘连块对
    /// 在多次拖拽后被推到 row=258/450，且互相重叠。加载时应自动去重叠并
    /// 向上压实；之后的拖拽不再劣化。
    func testRecoversFromRealWorldCorruptedLayout() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-corrupt-\(UUID().uuidString).json")
        let corrupted = """
        {
          "schemaVersion": 1,
          "maxColumns": 4,
          "compactSlots": [null, null, null],
          "drawerBlocks": [
            {"pluginID": "p", "blockID": "b", "placementID": "notes-1",      "originColumn": 0, "originRow": 450, "widthColumns": 2, "heightRows": 2},
            {"pluginID": "p", "blockID": "b", "placementID": "notes-2",      "originColumn": 0, "originRow": 2,   "widthColumns": 2, "heightRows": 2},
            {"pluginID": "p", "blockID": "b", "placementID": "shelf-wide-1", "originColumn": 0, "originRow": 450, "widthColumns": 4, "heightRows": 2},
            {"pluginID": "p", "blockID": "b", "placementID": "shelf-wide-2", "originColumn": 0, "originRow": 258, "widthColumns": 4, "heightRows": 1},
            {"pluginID": "p", "blockID": "b", "placementID": "shelf-large",  "originColumn": 1, "originRow": 258, "widthColumns": 2, "heightRows": 2},
            {"pluginID": "p", "blockID": "b", "placementID": "shelf-small",  "originColumn": 2, "originRow": 1,   "widthColumns": 1, "heightRows": 1}
          ],
          "enabledPluginIDs": []
        }
        """
        try corrupted.write(to: url, atomically: true, encoding: .utf8)

        let engine = LayoutEngine(fileURL: url, blockResolver: { _, _ in nil })
        XCTAssertTrue(engine.didLoadFromDisk)

        // 加载即自愈：无重叠、行号受控、不丢块。
        XCTAssertTrue(
            overlaps(engine).isEmpty,
            "损坏布局加载后仍有重叠: \(overlaps(engine))"
        )
        let maxRowAfterLoad = engine.drawerBlocks.map { $0.originRow + $0.heightRows }.max() ?? 0
        XCTAssertLessThanOrEqual(
            maxRowAfterLoad, 12,
            "行号未在加载时修复: \(engine.drawerBlocks)"
        )
        XCTAssertEqual(engine.drawerBlocks.count, 6, "净化不得丢块")

        // 自愈后继续随机拖拽不再劣化。
        var rng = SeededRandom(seed: 42)
        for _ in 0..<100 {
            let blocks = engine.drawerBlocks
            let victim = blocks[Int(rng.next() % UInt64(blocks.count))]
            dragAndCommit(
                engine,
                id: victim.placementID,
                toColumn: Int(rng.next() % 8) - 4,
                toRow: Int(rng.next() % 6) - 1
            )
            XCTAssertTrue(overlaps(engine).isEmpty)
            let minCol = engine.drawerBlocks.map(\.originColumn).min() ?? 0
            let maxCol = engine.drawerBlocks.map { $0.originColumn + $0.widthColumns }.max() ?? 0
            XCTAssertLessThanOrEqual(maxCol - minCol, engine.effectiveMaxColumns())
        }
    }

    /// 无重叠但存在大留白的正常布局不应被净化改动（保留用户留白）。
    func testSanitizerKeepsLegitGaps() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-legit-\(UUID().uuidString).json")
        let legit = """
        {
          "schemaVersion": 1,
          "maxColumns": 4,
          "compactSlots": [null, null, null],
          "drawerBlocks": [
            {"pluginID": "p", "blockID": "b", "placementID": "lonely", "originColumn": 0, "originRow": 9, "widthColumns": 2, "heightRows": 1}
          ],
          "enabledPluginIDs": []
        }
        """
        try legit.write(to: url, atomically: true, encoding: .utf8)

        let engine = LayoutEngine(fileURL: url, blockResolver: { _, _ in nil })
        XCTAssertEqual(engine.drawerBlocks.first?.originRow, 9, "无重叠布局不应被移动")
    }
}

/// 可复现的简易随机源。
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
