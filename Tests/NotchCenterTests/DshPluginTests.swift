import NotchCenterKit
import XCTest

@testable import DshPlugin

/// DshPlugin 配置与 plist 模板测试：只验证模板内容，不触碰真实 LaunchAgent。
final class DshPluginTests: XCTestCase {
    func testConfigConstants() {
        XCTAssertEqual(DshServiceConfig.label, "com.deepseek.dsh-web")
        XCTAssertTrue(DshServiceConfig.plistPath.hasSuffix("Library/LaunchAgents/com.deepseek.dsh-web.plist"))
        XCTAssertFalse(DshServiceConfig.programArguments.isEmpty)
    }

    func testPlistTemplateContents() {
        let contents = DshServiceConfig.plistContents
        XCTAssertEqual(contents["Label"] as? String, DshServiceConfig.label)
        XCTAssertEqual(contents["ProgramArguments"] as? [String], DshServiceConfig.programArguments)
        XCTAssertEqual(contents["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(contents["KeepAlive"] as? Bool, true)
        XCTAssertEqual(contents["StandardOutPath"] as? String, DshServiceConfig.logPath)
        XCTAssertEqual(contents["StandardErrorPath"] as? String, DshServiceConfig.logPath)
        let env = contents["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(env?["PATH"], DshServiceConfig.environmentPATH)
    }

    func testCompactLayoutThreshold() {
        // 窄块（< 110pt）隐藏指示灯 / 状态 / 端口 / 开关，退化为「图标 + 名称」。
        XCTAssertEqual(ServiceBlockCompactMetrics.widthThreshold, 110)
        XCTAssertTrue(ServiceBlockCompactMetrics.isCompact(width: 75))
        XCTAssertTrue(ServiceBlockCompactMetrics.isCompact(width: 109.9))
        XCTAssertFalse(ServiceBlockCompactMetrics.isCompact(width: 110))
        XCTAssertFalse(ServiceBlockCompactMetrics.isCompact(width: 300))
    }
}
