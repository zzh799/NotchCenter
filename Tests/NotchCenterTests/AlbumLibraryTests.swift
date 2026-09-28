import XCTest
@testable import AlbumPlugin

// MARK: - 本地来源的 IO 侧（真实 FileManager + 临时目录）
//
// 只碰临时目录：不读用户的真实文件，不改动仓库内任何路径。

final class AlbumLibraryTests: XCTestCase {
    private var root: URL!
    private var lockedDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 先把权限还回去，否则删不掉（chmod 000 的目录连删除都会被拒）。
        if let lockedDirectory {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: 目录扫描

    func testNonRecursiveScanFindsOnlyTopLevelImages() throws {
        try write("b.png")
        try write("a.jpg")
        try write("notes.txt")
        try write(".hidden.jpg")
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write("c.jpg", in: sub)

        guard case let .found(items) = AlbumFolderScan.scan(
            folderPath: root.path, recursive: false)
        else {
            return XCTFail("目录应当可读")
        }
        // 隐藏文件与子目录里的图都不算；非图片扩展名被丢掉；按 Finder 口径排序。
        XCTAssertEqual(items.map(\.title), ["a.jpg", "b.png"])
    }

    func testRecursiveScanIncludesSubfolders() throws {
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write("top.jpg")
        try write("nested.jpg", in: sub)

        guard case let .found(items) = AlbumFolderScan.scan(
            folderPath: root.path, recursive: true)
        else {
            return XCTFail("目录应当可读")
        }
        XCTAssertEqual(Set(items.map(\.title)), ["top.jpg", "nested.jpg"])
    }

    func testEmptyFolderIsFoundButEmpty() throws {
        guard case let .found(items) = AlbumFolderScan.scan(
            folderPath: root.path, recursive: false)
        else {
            return XCTFail("空目录也是可读目录")
        }
        XCTAssertTrue(items.isEmpty)
    }

    func testMissingPathIsReportedAsMissingNotUnreadable() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(
            AlbumFolderScan.scan(folderPath: missing.path, recursive: false), .missing)
    }

    func testAFilePathIsNotTreatedAsAFolder() throws {
        try write("a.jpg")
        XCTAssertEqual(
            AlbumFolderScan.scan(folderPath: root.appendingPathComponent("a.jpg").path, recursive: false),
            .missing)
    }

    func testUnreadableFolderIsDistinguishedFromEmpty() throws {
        // 以 root 运行时目录权限不生效，这个用例没有意义。
        try XCTSkipIf(getuid() == 0, "以 root 运行时 chmod 000 仍可列目录")
        lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        try write("inside.jpg", in: lockedDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)

        // "读不了"与"空目录"在块上是两种完全不同的提示（一个要指向 TCC 放行），
        // 所以这两者绝不能混成一个状态。
        XCTAssertEqual(
            AlbumFolderScan.scan(folderPath: lockedDirectory.path, recursive: false), .unreadable)
    }

    // MARK: 单张来源探活

    func testSingleFileProbeReportsReadyForAFile() throws {
        try write("one.jpg")
        XCTAssertEqual(
            AlbumFileProbe.state(ofFileAt: root.appendingPathComponent("one.jpg").path), .ready)
    }

    func testSingleFileProbeReportsMissingForGonePath() {
        XCTAssertEqual(
            AlbumFileProbe.state(ofFileAt: root.appendingPathComponent("gone.jpg").path), .missing)
    }

    func testSingleFileProbeRejectsDirectories() throws {
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(AlbumFileProbe.state(ofFileAt: sub.path), .missing)
    }

    // MARK: 夹具

    /// 内容无关紧要：筛选只看扩展名，不读文件内容（那正是"大目录不产生逐文件
    /// syscall"的立论），所以空文件就够。
    private func write(_ name: String, in directory: URL? = nil) throws {
        let target = (directory ?? root).appendingPathComponent(name)
        try Data().write(to: target)
    }
}
