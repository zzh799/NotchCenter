import XCTest

@testable import CalibrePlugin

/// CalibrePlugin 配置与 plist 模板测试：只验证模板内容，不触碰真实 LaunchAgent。
final class CalibrePluginTests: XCTestCase {
    func testConfigConstants() {
        XCTAssertEqual(CalibreServiceConfig.label, "com.user.calibre-server")
        XCTAssertTrue(CalibreServiceConfig.plistPath.hasSuffix("Library/LaunchAgents/com.user.calibre-server.plist"))
        XCTAssertEqual(
            CalibreServiceConfig.programArguments,
            ["/bin/sh", NSHomeDirectory() + "/.calibre-launchd/calibre-server-wrapper.sh"]
        )
        XCTAssertEqual(CalibreServiceConfig.fallbackWebURL.absoluteString, "http://localhost:8080")
        // 特征串只匹配真实二进制路径，避免 tail 日志/编辑器等命令行误命中。
        XCTAssertEqual(CalibreServiceConfig.workerPattern, "MacOS/calibre-server")
    }

    func testPlistTemplateContents() {
        let contents = CalibreServiceConfig.plistContents
        XCTAssertEqual(contents["Label"] as? String, CalibreServiceConfig.label)
        XCTAssertEqual(contents["ProgramArguments"] as? [String], CalibreServiceConfig.programArguments)
        XCTAssertEqual(contents["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(contents["KeepAlive"] as? Bool, true)
        XCTAssertEqual(contents["ThrottleInterval"] as? Int, 60)
        XCTAssertEqual(contents["WorkingDirectory"] as? String, NSHomeDirectory())
        XCTAssertEqual(contents["StandardOutPath"] as? String, CalibreServiceConfig.stdoutLogPath)
        XCTAssertEqual(contents["StandardErrorPath"] as? String, CalibreServiceConfig.stderrLogPath)
        XCTAssertNotEqual(contents["StandardOutPath"] as? String, contents["StandardErrorPath"] as? String)
    }
}
