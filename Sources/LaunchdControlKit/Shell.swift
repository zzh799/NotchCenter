import Foundation

// MARK: - 通用 shell 执行

/// 一次外部命令执行的结果。
public struct ShellResult: Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// 同步执行外部命令，stdout 与 stderr 合并返回。
///
/// 刻意保持同步阻塞：调用点都是用户手动触发或后台轮询，命令本身
/// （launchctl / ps / lsof / pgrep）都在毫秒级返回。并发调度归调用方。
///
/// 必须先读完管道再 waitUntilExit：若先等待退出，输出超过管道缓冲（64KB）
/// 时会写满缓冲，子进程阻塞在写端，父进程又等不到退出，形成死锁。
public enum Shell {
    @discardableResult
    public static func run(_ path: String, _ args: [String]) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return ShellResult(status: -1, output: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return ShellResult(status: proc.terminationStatus, output: out)
    }
}

/// 用到的系统可执行文件路径集中在一处，避免调用点散落魔法字符串。
public enum ExecutablePath {
    public static let launchctl = "/bin/launchctl"
    public static let plistBuddy = "/usr/libexec/PlistBuddy"
    public static let pgrep = "/usr/bin/pgrep"
    public static let lsof = "/usr/sbin/lsof"
    public static let ps = "/bin/ps"
    public static let open = "/usr/bin/open"
}

/// launchd 用户域标识：`gui/<uid>`（现代 bootstrap/bootout API 的目标域）。
public func launchdGUIDomain(uid: uid_t = getuid()) -> String {
    "gui/\(uid)"
}
