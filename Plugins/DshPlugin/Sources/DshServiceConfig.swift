import Foundation
import LaunchdControlKit

/// DshPlugin 的硬编码服务配置（决策 5：不做扫描，专用插件）。
enum DshServiceConfig {
    static let label = "com.deepseek.dsh-web"
    static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.deepseek.dsh-web.plist"
    /// pgrep -f 特征：识别脱离 launchd 的野进程。
    static let workerPattern = "bin.ts web"
    /// 探测不到端口时「打开网页」的回退 URL。
    static let fallbackWebURL = URL(string: "http://localhost:3080")!
    /// plist 缺失时的固定模板参数（照抄现有 LaunchAgent）。
    static let programArguments = ["/opt/homebrew/bin/pnpm", "dsh", "web"]
    static let workingDirectory = "/Users/zhouzihang/Projects/Ai/deepseek-harness"
    static let environmentPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    static let logPath = "/tmp/dsh-web.log"

    static var target: LaunchdProbe.Target {
        LaunchdProbe.Target(label: label, plistPath: plistPath, workerPattern: workerPattern)
    }

    /// 固定 plist 模板内容。
    static var plistContents: [String: Any] {
        LaunchdPlist.makeContents(
            label: label,
            programArguments: programArguments,
            workingDirectory: workingDirectory,
            environment: ["PATH": environmentPATH],
            runAtLoad: true,
            keepAlive: true,
            stdoutPath: logPath,
            stderrPath: logPath
        )
    }
}
