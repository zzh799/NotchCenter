import SwiftUI
import XCTest
@testable import NotchCenter
import NotchCenterKit

// 统一拖拽观感的两条关键不变量：
//   1. `Payload` 的相等只看身份——携带的视图每次都是新实例，若参与比较，
//      「哪张卡片在拖」的高亮会永久失灵。
//   2. 虚线占位框预示的落点 == 松手后真正落到的位置。跟手浮窗是飞向
//      占位框的，这条不成立的话整个落位动画就是在骗人。
@MainActor
final class DragUnificationTests: XCTestCase {

    // MARK: - 1. Payload 相等语义

    private func makePayload(
        blockID: String = "b",
        columns: Int = 2,
        rows: Int = 2,
        preview: BlockDragCoordinator.DragPreviewContent? = nil
    ) -> BlockDragCoordinator.Payload {
        BlockDragCoordinator.Payload(
            pluginID: "p",
            blockID: blockID,
            kind: .drawer,
            displayName: "块",
            symbolName: nil,
            span: GridSpan(columns: columns, rows: rows),
            preview: preview
        )
    }

    private func anyContent() -> BlockDragCoordinator.DragPreviewContent {
        BlockDragCoordinator.DragPreviewContent(
            view: AnyView(EmptyView()),
            size: CGSize(width: 150, height: 120)
        )
    }

    /// 手写 `==` 的最大风险是漏字段：以后新增字段却忘了加进 `==`，
    /// 卡片高亮（`SettingsPages` 的 `.opacity(payload == item.payload)`）
    /// 会静默失灵——这个测试守住它。
    func testPayloadEqualityIgnoresPreviewView() {
        // `AnyView` 不可比较，故视图必须被排除在相等语义之外。
        XCTAssertEqual(
            makePayload(preview: anyContent()),
            makePayload(preview: anyContent())
        )
        // 有视图 vs 无视图（自动化探针）也应视为同一个载荷。
        XCTAssertEqual(makePayload(preview: anyContent()), makePayload(preview: nil))
    }

    func testPayloadEqualityDistinguishesIdentity() {
        XCTAssertNotEqual(makePayload(blockID: "b"), makePayload(blockID: "c"))
        XCTAssertNotEqual(makePayload(columns: 2, rows: 2), makePayload(columns: 1, rows: 2))
        XCTAssertNotEqual(makePayload(columns: 2, rows: 2), makePayload(columns: 2, rows: 1))
    }

    // MARK: - 2. 占位框落点 == 提交落点

    private func makeEngine(
        blocks: [(String, Int, Int, Int, Int)],
        maxColumns: Int = 4,
        screenWidth: CGFloat = 1440
    ) -> LayoutEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-draguni-\(UUID().uuidString).json")
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
        engine.updateScreenConstraint(width: screenWidth)
        return engine
    }

    private func origin(of placementID: String, in engine: LayoutEngine) -> LayoutEngine.GridOrigin? {
        guard let block = engine.drawerBlocks.first(where: { $0.placementID == placementID })
        else { return nil }
        return LayoutEngine.GridOrigin(column: block.originColumn, row: block.originRow)
    }

    /// 布局无空行/空列可压实的情况下，占位框与真实落点必须**严格相等**。
    func testDropPlaceholderMatchesCommittedOriginExactly() {
        // b 从右上挪到左下：与 a 不重叠，不触发推挤，也不产生空行/空列。
        let engine = makeEngine(blocks: [
            ("a", 0, 0, 2, 2),
            ("b", 2, 0, 2, 2),
        ])
        let origins = engine.previewArrangement(moving: "b", toColumn: 0, toRow: 2)
        guard let placeholder = origins["b"] else {
            return XCTFail("被拖块必须有落点，否则占位框无从绘制")
        }

        // 复刻 `commitArrangement` 的步骤，先确认压实确实是空操作
        // （否则下面的严格相等不成立，原因见另一个测试）。
        engine.applyOrigins(origins)
        XCTAssertFalse(engine.compactEmptyRows(), "前提：本布局不应产生空行")
        XCTAssertFalse(engine.compactEmptyColumns(), "前提：本布局不应产生空列")

        XCTAssertEqual(
            origin(of: "b", in: engine),
            placeholder,
            "占位框与真实落点不一致：跟手浮窗会飞到一个块实际不去的位置"
        )
    }

    /// 压实一致性（实时推挤恢复后的核心不变量）：`previewCommittedArrangement`
    /// （拖动预览）与 `commitArrangement`（松手提交）对同一目标给出**逐块
    /// 严格相等**的布局——预览即最终布局，松手零跳动。
    ///
    /// 此前预览不模拟压实（推挤后、未压实的坐标画占位框），只能钉
    /// 「压实只上移」的容忍断言；压实抽成纯函数、预览链路离线压实后，
    /// 直接钉严格相等。
    func testPreviewCommittedArrangementMatchesCommitExactly() {
        let scenarios: [(
            name: String,
            blocks: [(String, Int, Int, Int, Int)],
            moving: String, toColumn: Int, toRow: Int
        )] = [
            // 顶部腾空 + 下移交换：a 下移跨过 b 顶缘（目标行 2 == b 的
            // originRow）→ b 保位、a 落到其下 → 压实整体上移闭合顶部空洞。
            ("下移交换", [("a", 0, 0, 2, 2), ("b", 0, 2, 2, 2)], "a", 0, 2),
            // 左扩：b 拖到左边界外 → 落点列可为负 → 压实不得产生负列空洞。
            ("左扩", [("a", 0, 0, 2, 2), ("b", 2, 0, 2, 2)], "b", -3, 0),
            // 无推挤无压实的平凡场景。
            ("平凡挪动", [("a", 0, 0, 2, 2), ("b", 2, 0, 2, 2)], "b", 0, 2),
        ]
        for scenario in scenarios {
            let engine = makeEngine(blocks: scenario.blocks)
            let origins = engine.previewCommittedArrangement(
                moving: scenario.moving,
                toColumn: scenario.toColumn,
                toRow: scenario.toRow
            )
            guard let placeholder = origins[scenario.moving] else {
                XCTFail("\(scenario.name)：被拖块必须有落点，否则占位框无从绘制")
                continue
            }
            _ = engine.commitArrangement(origins)
            for block in engine.drawerBlocks {
                XCTAssertEqual(
                    LayoutEngine.GridOrigin(column: block.originColumn, row: block.originRow),
                    origins[block.placementID],
                    "\(scenario.name)：块 \(block.placementID) 的预览位置与提交结果不一致"
                )
            }
            XCTAssertEqual(
                origin(of: scenario.moving, in: engine),
                placeholder,
                "\(scenario.name)：占位框与真实落点不一致"
            )
        }
    }

    /// 左扩语义钉死：拖到左边界外时落点列合法（可为负），压实后格网
    /// 无负列空洞、总跨度不越容量。
    func testLeftExpansionPreviewProducesContiguousColumns() {
        let engine = makeEngine(blocks: [
            ("a", 0, 0, 2, 2),
            ("b", 2, 0, 2, 2),
        ])
        let origins = engine.previewCommittedArrangement(moving: "b", toColumn: -3, toRow: 0)
        guard let dragged = origins["b"] else {
            return XCTFail("被拖块必须有落点")
        }
        XCTAssertLessThan(dragged.column, 0, "向左拖出应预示格网左扩（落点列为负）")

        // 预览即最终布局：提交后负列区域无缝、无空洞、不越容量。
        _ = engine.commitArrangement(origins)
        let columns = Set(engine.drawerBlocks.flatMap {
            $0.originColumn..<($0.originColumn + $0.widthColumns)
        })
        let minColumn = columns.min() ?? 0
        let maxColumn = columns.max() ?? 0
        XCTAssertEqual(
            columns.count, maxColumn - minColumn + 1,
            "压实后不得残留列空洞（含负列区域）"
        )
        XCTAssertLessThanOrEqual(
            columns.count,
            engine.effectiveMaxColumns(),
            "左扩后的总跨度不得越过容量"
        )
    }

    /// 占位框的绘制前提：`previewArrangement` 对被拖块**总有**落点。
    /// 否则拖动到某些区域时占位框会整段消失。
    func testPreviewArrangementAlwaysYieldsOriginForDraggedBlock() {
        let engine = makeEngine(blocks: [
            ("a", 0, 0, 2, 2),
            ("b", 2, 0, 2, 2),
        ])
        for column in -2...4 {
            for row in 0...4 {
                let origins = engine.previewArrangement(moving: "a", toColumn: column, toRow: row)
                XCTAssertNotNil(
                    origins["a"],
                    "落点 (\(column), \(row)) 未给出被拖块原点——占位框会消失"
                )
            }
        }
    }
}
