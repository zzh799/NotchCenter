import XCTest
@testable import NotchCenter

/// 启动维护策略（Agent Note 2026-09-25-plugin-in-use-placement-criterion）。
///
/// 生产值 `LaunchMaintenance.purgesInvalidPlacements` 由 `#if DEBUG` 决定，是编译期
/// 常量——同一个测试进程只能看到其中一半。所以这里**注入**两个值，把 release
/// 那条（最需要回归、又最容易落在测试盲区，失灵就是用户布局文件被误改或永远
/// 清不掉失效组件）也覆盖上。
@MainActor
final class LaunchMaintenanceTests: XCTestCase {
    private func makeEngine(
        liveness: @escaping @MainActor (String, String) -> Bool
    ) throws -> (LayoutEngine, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchMaintenance-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = LayoutEngine(
            fileURL: directory.appendingPathComponent("layout.json"),
            blockResolver: { _, _ in nil },
            placementLiveness: liveness
        )
        return (engine, directory)
    }

    private func drawerBlock(_ pluginID: String) -> PlacedBlock {
        PlacedBlock(
            pluginID: pluginID,
            blockID: "shelf",
            placementID: "\\(pluginID)|shelf",
            originColumn: 0,
            originRow: 0,
            widthColumns: 1,
            heightRows: 1
        )
    }

    /// release 路径：策略打开 → 清理生效并落盘。
    func testRunPurgesWhenPolicyIsOn() throws {
        let (engine, directory) = try makeEngine(liveness: { _, _ in false })
        let fileURL = directory.appendingPathComponent("layout.json")
        var model = engine.modelForTesting
        model.drawerBlocks = [drawerBlock("com.gone")]
        engine.modelForTesting = model
        XCTAssertEqual(engine.invalidPlacementCount(), 1)

        XCTAssertEqual(
            LaunchMaintenance.run(layoutEngine: engine, purgeInvalidPlacements: true),
            1
        )
        XCTAssertTrue(engine.drawerBlocks.isEmpty)

        let restored = LayoutEngine(fileURL: fileURL, blockResolver: { _, _ in nil })
        XCTAssertTrue(restored.drawerBlocks.isEmpty, "清理必须落盘")
        try? FileManager.default.removeItem(at: directory)
    }

    /// debug 路径：策略关掉 → 一根毫毛都不动。开发期要靠残骸复现问题，这一档的
    /// 清理入口是「设置 → 调试 → 删除无效组件」。
    func testRunKeepsInvalidPlacementsWhenPolicyIsOff() throws {
        let (engine, directory) = try makeEngine(liveness: { _, _ in false })
        var model = engine.modelForTesting
        model.drawerBlocks = [drawerBlock("com.gone")]
        engine.modelForTesting = model

        XCTAssertEqual(
            LaunchMaintenance.run(layoutEngine: engine, purgeInvalidPlacements: false),
            0
        )
        XCTAssertEqual(engine.drawerBlocks.count, 1)
        XCTAssertEqual(engine.invalidPlacementCount(), 1, "残骸必须原样留着")
        try? FileManager.default.removeItem(at: directory)
    }

    /// 启动清理只管**失效**（`.missing`），不动"插件被停用"留下的摆放——停用可逆，
    /// 判据见 `LayoutEngine.placementLiveness`。
    func testRunKeepsPlacementsOfDisabledPlugins() throws {
        let (engine, directory) = try makeEngine(liveness: { pluginID, _ in
            pluginID != "com.gone"
        })
        var model = engine.modelForTesting
        model.drawerBlocks = [
            drawerBlock("com.disabled"),
            drawerBlock("com.gone"),
        ]
        engine.modelForTesting = model

        XCTAssertEqual(
            LaunchMaintenance.run(layoutEngine: engine, purgeInvalidPlacements: true),
            1,
            "只删 com.gone"
        )
        XCTAssertEqual(engine.drawerBlocks.map(\.pluginID), ["com.disabled"])
        try? FileManager.default.removeItem(at: directory)
    }
}
