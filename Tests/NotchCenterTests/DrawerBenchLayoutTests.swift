import XCTest
@testable import NotchCenter

/// `DrawerBenchLayout` 合成布局的纯函数回归。
///
/// 为什么要测：它是 N 曲线基准的**输入口径**——排布重叠会被宿主净化掉、
/// 页数/块数写错会直接改变曲线的横轴，而基准不会因此报任何错，只会给出
/// 一组看起来合理的错数。另：块的跨度按面积降序循环是"大块优先"的刻意选择
/// （NaN 曲线首尾更陡），改排序会静默改变历史数字的可比性。
@MainActor
final class DrawerBenchLayoutTests: XCTestCase {

    private func shape(
        _ pluginID: String,
        _ blockID: String,
        _ columns: Int,
        _ rows: Int
    ) -> PlacedBlock {
        PlacedBlock(
            pluginID: pluginID,
            blockID: blockID,
            placementID: UUID().uuidString,
            page: 0,
            originColumn: 0,
            originRow: 0,
            widthColumns: columns,
            heightRows: rows
        )
    }

    private var twoShapes: [PlacedBlock] {
        [
            shape("p.small", "small", 2, 1),
            shape("p.big", "big", 4, 4),
            shape("p.small", "small", 2, 1),   // 重复块型：只应取一次
        ]
    }

    private var template: LayoutModel {
        var model = LayoutModel()
        model.maxColumns = 8
        model.minRows = 2
        model.minColumns = 4
        return model
    }

    func testNCurveLayoutHasSixPagesWithExpectedBlockCounts() throws {
        let model = try XCTUnwrap(
            DrawerBenchLayout.makeSynthetic(shapes: twoShapes, template: template, mode: .nCurve)
        )
        XCTAssertEqual(model.drawerPages.count, DrawerBenchLayout.pageBlockCounts.count)
        for (page, expected) in DrawerBenchLayout.pageBlockCounts.enumerated() {
            XCTAssertEqual(
                model.drawerBlocks.filter { $0.page == page }.count,
                expected,
                "第 \(page) 页块数必须等于采样点 \(expected)"
            )
        }
        // 模板字段随行：列数/行下限决定抽屉宽高口径，丢了数字就不可比。
        XCTAssertEqual(model.maxColumns, 8)
        XCTAssertEqual(model.minRows, 2)
    }

    func testUniformLayoutGivesOnePagePerShapeWithFixedCount() throws {
        let model = try XCTUnwrap(
            DrawerBenchLayout.makeSynthetic(shapes: twoShapes, template: template, mode: .uniform)
        )
        XCTAssertEqual(model.drawerPages.count, 2, "同型对照 = 每个块型一页（重复块型去重）")
        for page in model.drawerPages {
            let blocks = model.drawerBlocks.filter { $0.page == page }
            XCTAssertEqual(blocks.count, DrawerBenchLayout.uniformPageBlocks)
            XCTAssertEqual(Set(blocks.map(\.blockID)).count, 1, "同页必须全为同一块型，否则对照无意义")
        }
        XCTAssertEqual(
            Set(model.drawerBlocks.map(\.blockID)), ["small", "big"],
            "每个块型都要有自己的页"
        )
    }

    func testShelfPackingNeverOverlapsAndKeepsSpans() throws {
        let model = try XCTUnwrap(
            DrawerBenchLayout.makeSynthetic(shapes: twoShapes, template: template, mode: .nCurve)
        )
        for page in model.drawerPages {
            let blocks = model.drawerBlocks.filter { $0.page == page }
            for (index, a) in blocks.enumerated() {
                for b in blocks[(index + 1)...] {
                    let overlaps = a.originColumn < b.originColumn + b.widthColumns
                        && b.originColumn < a.originColumn + a.widthColumns
                        && a.originRow < b.originRow + b.heightRows
                        && b.originRow < a.originRow + a.heightRows
                    XCTAssertFalse(overlaps, "第 \(page) 页块重叠：\(a.originColumn),\(a.originRow) 与 \(b.originColumn),\(b.originRow)")
                }
                // 跨度原样保留：块的像素尺寸就是它在基准里的身份。
                XCTAssertGreaterThan(a.widthColumns, 0)
                XCTAssertGreaterThan(a.heightRows, 0)
                XCTAssertLessThanOrEqual(a.widthColumns, DrawerBenchLayout.rowColumns)
            }
        }
    }

    func testEmptyShapesYieldNil() {
        XCTAssertNil(
            DrawerBenchLayout.makeSynthetic(shapes: [], template: template, mode: .nCurve),
            "没有可用块型时必须返回 nil（调用方据此提示退出），而不是造一份空基准"
        )
    }
}
