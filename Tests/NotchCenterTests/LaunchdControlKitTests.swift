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

    func testMakeContentsThrottleInterval() throws {
        // 默认不写入 ThrottleInterval。
        let plain = LaunchdPlist.makeContents(label: "com.example.svc", programArguments: ["/bin/true"])
        XCTAssertNil(plain["ThrottleInterval"])

        let throttled = LaunchdPlist.makeContents(
            label: "com.example.svc",
            programArguments: ["/bin/true"],
            throttleInterval: 60
        )
        XCTAssertEqual(throttled["ThrottleInterval"] as? Int, 60)
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

    // MARK: - probe 状态机（resolveState 纯函数，不真跑 shell）

    func testResolveStateUnmanagedRequiresListening() {
        // 回归：服务未加载时，仅命令行特征匹配（tail 日志/编辑器/残留进程）、
        // 未监听端口的进程不算野进程 → Stopped，不误显示 Unmanaged。
        XCTAssertEqual(
            LaunchdProbe.resolveState(
                isLoaded: false, launchdPID: nil, servingPID: nil,
                servingManaged: false, listeningCount: 0
            ),
            .stopped
        )
    }

    func testResolveStateTable() {
        typealias State = LaunchdServiceStatus.State
        let cases: [(String, Bool, pid_t?, pid_t?, Bool, Int, State)] = [
            // (说明, isLoaded, launchdPID, servingPID, servingManaged, listeningCount, 期望)
            ("未加载 + 真有监听野进程", false, nil, 901, false, 1, .unmanagedExternal),
            ("未加载 + 两个监听实例", false, nil, 901, false, 2, .portConflict(listeningCount: 2)),
            ("已加载 + wrapper 等待外置卷（有 PID 未监听）→ 启动中，不冒充 Running", true, 100, nil, false, 0, .starting),
            ("已加载无 PID 且无监听（进程已退/真挂）", true, nil, nil, false, 0, .loadedNotRunning),
            ("已加载 + 监听实例即 launchd PID", true, 100, 100, true, 1, .managed),
            ("已加载 + 监听实例是 launchd 子孙（exec/pnpm 包装）", true, 100, 200, true, 1, .managed),
            ("已加载 + 监听实例无血缘", true, 100, 999, false, 1, .unmanagedExternal),
            ("已加载 + 监听实例无血缘且多实例", true, 100, 999, false, 2, .portConflict(listeningCount: 2)),
            ("已加载但 launchctl 未报 PID + 有监听（无法证伪血缘）", true, nil, 999, false, 1, .managed),
        ]
        for (name, isLoaded, launchdPID, servingPID, managed, count, expected) in cases {
            XCTAssertEqual(
                LaunchdProbe.resolveState(
                    isLoaded: isLoaded, launchdPID: launchdPID, servingPID: servingPID,
                    servingManaged: managed, listeningCount: count
                ),
                expected,
                name
            )
        }
    }
}
