import Foundation
import LaunchdControlKit

/// CalibrePlugin 的硬编码服务配置（沿用 DshPlugin 决策 5：不做扫描，专用插件）。
enum CalibreServiceConfig {
    static let label = "com.user.calibre-server"
    static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.user.calibre-server.plist"
    /// pgrep -f 特征：识别脱离 launchd 的野进程。只匹配真实二进制路径
    /// （wrapper exec 后命令行含 MacOS/calibre-server），避免 tail 看日志 /
    /// 编辑器打开 wrapper 脚本等命令行恰含 "calibre-server" 的无辜进程误命中；
    /// wrapper 等待外置卷阶段无需特征（launchd PID 覆盖，exec 不换 PID）。
    static let workerPattern = "MacOS/calibre-server"
    /// 探测不到端口时「打开网页」的回退 URL（wrapper 固定 --port 8080）。
    static let fallbackWebURL = URL(string: "http://localhost:8080")!
    /// plist 缺失时的固定模板参数（照抄现有 LaunchAgent）。
    static let programArguments = ["/bin/sh", NSHomeDirectory() + "/.calibre-launchd/calibre-server-wrapper.sh"]
    static let workingDirectory = NSHomeDirectory()
    static let stdoutLogPath = NSHomeDirectory() + "/.calibre-launchd/calibre-server.out.log"
    static let stderrLogPath = NSHomeDirectory() + "/.calibre-launchd/calibre-server.err.log"
    /// 外置库卷未挂载时避免重启风暴（现有 plist 的 ThrottleInterval）。
    static let throttleInterval = 60

    static var target: LaunchdProbe.Target {
        LaunchdProbe.Target(label: label, plistPath: plistPath, workerPattern: workerPattern)
    }

    /// 固定 plist 模板内容。
    static var plistContents: [String: Any] {
        LaunchdPlist.makeContents(
            label: label,
            programArguments: programArguments,
            workingDirectory: workingDirectory,
            runAtLoad: true,
            keepAlive: true,
            throttleInterval: throttleInterval,
            stdoutPath: stdoutLogPath,
            stderrPath: stderrLogPath
        )
    }
}
