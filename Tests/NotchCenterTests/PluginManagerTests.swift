import Foundation
import NotchCenterKit
import XCTest
@testable import NotchCenter

@MainActor
private final class StubHostController: HostController {
    var expandCount = 0
    var collapseCount = 0
    var editCount = 0

    func expandDrawer() { expandCount += 1 }
    func collapseDrawer() { collapseCount += 1 }
    func enterEditMode() { editCount += 1 }
    func exitEditMode() {}
    func refreshCompactDisplay() {}
}

/// 插件元数据 / 发现 / 校验 / 安装路径测试（文档 §3 / §8 / §9.1）。
/// 使用纯 Info.plist fixture bundle（不加载真实代码）。
@MainActor
final class PluginManagerTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManagerTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// 与宿主 .app 的真实 PlugIns 目录隔离：xcodebuild test 以 NotchCenter.app 为测试宿主，
    /// 缺省的 CorePaths.builtInPlugInsDirectory 会看到 build.sh 组装的真实插件，
    /// fixture 断言必须显式指定空目录。
    private func makeEmptyBuiltIn() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManagerTests-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeBundle(
        at root: URL,
        name: String,
        pluginID: String,
        apiVersion: String = "1.0..<2.0",
        displayName: String? = nil,
        principalClass: String = "FixturePlugin"
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "NSPrincipalClass": principalClass,
            "NotchCenterPluginID": pluginID,
            "NotchCenterPluginVersion": "1.0.0",
            "NotchCenterPluginAPIVersion": apiVersion,
            "NotchCenterPluginDisplayName": displayName ?? name
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundleURL
    }

    // MARK: 发现与元数据（文档 §3.2 / §3.3）

    func testDiscoversBuiltInAndUserPluginsWithMetadata() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("builtin", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        try writeBundle(at: builtIn, name: "NotesPlugin", pluginID: "com.notchcenter.notes", principalClass: "NotesPlugin")
        try writeBundle(at: user, name: "ThirdParty", pluginID: "com.example.third", displayName: "Third Party")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: builtIn,
            userDirectory: user
        )

        XCTAssertEqual(manager.entries.count, 2)
        XCTAssertTrue(manager.invalidBundles.isEmpty)

        let notes = try XCTUnwrap(manager.entry(for: "com.notchcenter.notes"))
        XCTAssertTrue(notes.metadata.isBuiltIn)
        XCTAssertEqual(notes.metadata.displayName, "NotesPlugin")
        XCTAssertEqual(notes.metadata.pluginVersion, "1.0.0")
        XCTAssertTrue(notes.metadata.isAPICompatible)
        XCTAssertEqual(notes.metadata.principalClassName, "NotesPlugin")

        let third = try XCTUnwrap(manager.entry(for: "com.example.third"))
        XCTAssertFalse(third.metadata.isBuiltIn)
        XCTAssertEqual(third.metadata.displayName, "Third Party")
    }

    func testUserPluginOverridesBuiltInWithSameID() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("builtin", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        try writeBundle(at: builtIn, name: "Original", pluginID: "com.example.shared")
        try writeBundle(at: user, name: "Replacement", pluginID: "com.example.shared", displayName: "Replacement")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: builtIn,
            userDirectory: user
        )

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entry(for: "com.example.shared")?.metadata.displayName, "Replacement")
        XCTAssertFalse(manager.entry(for: "com.example.shared")?.metadata.isBuiltIn ?? true)
    }

    func testMalformedBundlesAreReportedAsInvalid() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        try writeBundle(at: user, name: "Good", pluginID: "com.example.good")
        // 缺 NotchCenterPluginID 的坏 bundle。
        let badURL = user.appendingPathComponent("Bad.bundle/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)
        let info: [String: Any] = ["NSPrincipalClass": "Whatever"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: badURL.appendingPathComponent("Info.plist"))

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: makeEmptyBuiltIn(),
            userDirectory: user
        )

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.invalidBundles.count, 1)
    }

    // MARK: API 版本校验（文档 §9.1）

    func testAPIIncompatiblePluginCannotBeEnabled() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try writeBundle(at: user, name: "Old", pluginID: "com.example.old", apiVersion: "0.9..<1.0")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: makeEmptyBuiltIn(),
            userDirectory: user
        )
        let entry = try XCTUnwrap(manager.entry(for: "com.example.old"))
        XCTAssertFalse(entry.metadata.isAPICompatible)

        XCTAssertThrowsError(try manager.setEnabled(true, pluginID: "com.example.old")) { error in
            guard case PluginManager.PluginManagerError.apiIncompatible = error else {
                return XCTFail("expected apiIncompatible, got \(error)")
            }
        }
        XCTAssertFalse(entry.isEnabled)
        XCTAssertNotNil(entry.loadError)
    }

    // MARK: 加载失败路径（无真实二进制 → Bundle 无法装载）

    func testEnableFailsGracefullyForBundleWithoutExecutable() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try writeBundle(at: user, name: "Dead", pluginID: "com.example.dead")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: makeEmptyBuiltIn(),
            userDirectory: user
        )
        let entry = try XCTUnwrap(manager.entry(for: "com.example.dead"))

        XCTAssertThrowsError(try manager.setEnabled(true, pluginID: "com.example.dead"))
        XCTAssertFalse(entry.isEnabled)
        XCTAssertNotNil(entry.loadError)
    }

    func testRestoreEnabledStateKeepsFailedPluginsDisabled() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try writeBundle(at: user, name: "Dead", pluginID: "com.example.dead")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: makeEmptyBuiltIn(),
            userDirectory: user
        )
        manager.restoreEnabledState(from: ["com.example.dead"])

        let entry = try XCTUnwrap(manager.entry(for: "com.example.dead"))
        XCTAssertFalse(entry.isEnabled)
        XCTAssertNotNil(entry.loadError)
    }

    // MARK: 安装 / 卸载（文档 §8.2）

    func testInstallCopiesBundleThenRevertsWhenEnableFails() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let sourceBundle = try writeBundle(at: source, name: "Fresh", pluginID: "com.example.fresh")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: makeEmptyBuiltIn(),
            userDirectory: user
        )
        // 无真实二进制：复制后启用必然失败，应回滚复制出的 bundle。
        XCTAssertThrowsError(try manager.installBundle(from: sourceBundle))
        XCTAssertNil(manager.entry(for: "com.example.fresh"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: user.appendingPathComponent("com.example.fresh.bundle").path
            )
        )
    }

    func testInstallRejectsNonBundleSources() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        let notABundle = root.appendingPathComponent("plain-file.txt")
        try Data("nope".utf8).write(to: notABundle)

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: makeEmptyBuiltIn(),
            userDirectory: user
        )
        XCTAssertThrowsError(try manager.installBundle(from: notABundle))
    }

    func testUninstallRejectsBuiltInsAndRemovesUserBundles() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("builtin", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        try writeBundle(at: builtIn, name: "Official", pluginID: "com.notchcenter.official")
        try writeBundle(at: user, name: "Extra", pluginID: "com.example.extra")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: builtIn,
            userDirectory: user
        )

        XCTAssertThrowsError(try manager.uninstall(pluginID: "com.notchcenter.official"))
        XCTAssertNotNil(manager.entry(for: "com.notchcenter.official"))

        try manager.uninstall(pluginID: "com.example.extra")
        XCTAssertNil(manager.entry(for: "com.example.extra"))
    }

    // MARK: 菜单贡献（文档 §4.8）

    func testMenuContributionsComeOnlyFromEnabledPlugins() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        // 未启用插件提供菜单项，但不应出现在贡献中（enable 失败，保持禁用）。
        try writeBundle(at: user, name: "Dead", pluginID: "com.example.dead")

        let manager = PluginManager(
            hostController: StubHostController(),
            builtInDirectory: makeEmptyBuiltIn(),
            userDirectory: user
        )
        XCTAssertTrue(manager.menuContributions().isEmpty)
    }
}