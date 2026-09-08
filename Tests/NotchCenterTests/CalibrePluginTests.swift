import NotchCenterKit
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

    func testCompactLayoutThreshold() {
        // 窄块（< 110pt）隐藏指示灯 / 状态 / 端口 / 开关，退化为「图标 + 名称」。
        XCTAssertEqual(ServiceBlockCompactMetrics.widthThreshold, 110)
        XCTAssertTrue(ServiceBlockCompactMetrics.isCompact(width: 75))
        XCTAssertTrue(ServiceBlockCompactMetrics.isCompact(width: 109.9))
        XCTAssertFalse(ServiceBlockCompactMetrics.isCompact(width: 110))
        XCTAssertFalse(ServiceBlockCompactMetrics.isCompact(width: 150))
    }
}
