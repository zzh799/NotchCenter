import XCTest

@testable import LaunchdControlKit

/// LaunchdControlKit 单元测试：只验证命令字符串构造与 plist 读写生成，
/// 不真正执行 launchctl / 不改变系统睡眠或服务状态（参照 SystemSleepGuardTests 约定）。
final class LaunchdControlKitTests: XCTestCase {
    // MARK: - LaunchdPlist 模板生成与读写

    func testMakeContentsContainsStandardKeys() throws {
        let contents = LaunchdPlist.makeContents(
            label: "com.example.svc",
            programArguments: ["/usr/bin/foo", "--bar"],
            workingDirectory: "/tmp/work",
            environment: ["PATH": "/usr/bin:/bin"],
            runAtLoad: true,
            keepAlive: true,
            stdoutPath: "/tmp/out.log",
            stderrPath: "/tmp/err.log"
        )
        XCTAssertEqual(contents["Label"] as? String, "com.example.svc")
        XCTAssertEqual(contents["ProgramArguments"] as? [String], ["/usr/bin/foo", "--bar"])
        XCTAssertEqual(contents["WorkingDirectory"] as? String, "/tmp/work")
        XCTAssertEqual(contents["EnvironmentVariables"] as? [String: String], ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(contents["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(contents["KeepAlive"] as? Bool, true)
        XCTAssertEqual(contents["StandardOutPath"] as? String, "/tmp/out.log")
        XCTAssertEqual(contents["StandardErrorPath"] as? String, "/tmp/err.log")
    }

    func testWriteAndReadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchdkit-tests-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("test.plist").path
        defer { try? FileManager.default.removeItem(at: dir) }

        let plist = LaunchdPlist(plistPath: path)
        let contents = LaunchdPlist.makeContents(label: "com.example.svc", programArguments: ["/bin/true"])

        XCTAssertTrue(plist.createIfMissing(contents: contents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(plist.readRunAtLoad(), true)

        // 已存在时不覆盖。
        XCTAssertTrue(plist.createIfMissing(contents: LaunchdPlist.makeContents(
            label: "other", programArguments: ["/bin/false"]
        )))
        XCTAssertEqual(plist.readContents()?["Label"] as? String, "com.example.svc")

        // 只改 RunAtLoad，保留其余内容。
        XCTAssertTrue(plist.writeRunAtLoad(false))
        XCTAssertEqual(plist.readRunAtLoad(), false)
        XCTAssertEqual(plist.readContents()?["Label"] as? String, "com.example.svc")
    }

    func testReadMissingPlistReturnsNil() {
        let plist = LaunchdPlist(plistPath: "/nonexistent/\(UUID().uuidString).plist")
        XCTAssertNil(plist.readContents())
        XCTAssertNil(plist.readRunAtLoad())
        XCTAssertFalse(plist.writeRunAtLoad(true))
    }

    // MARK: - 命令字符串构造（不真跑 launchctl）

    func testGUIDomainFormat() {
        XCTAssertEqual(launchdGUIDomain(uid: 501), "gui/501")
    }

    func testProbeTargetDefaults() {
        let probe = LaunchdProbe(label: "com.example.svc", plistPath: "/tmp/x.plist")
        XCTAssertEqual(probe.target.label, "com.example.svc")
        XCTAssertNil(probe.target.workerPattern)
    }
}
