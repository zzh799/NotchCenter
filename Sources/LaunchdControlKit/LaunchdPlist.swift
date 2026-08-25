import Foundation

// MARK: - LaunchAgent plist 读写与生成

/// LaunchAgent plist 的读取、字段写入与模板生成。
///
/// 读写走 PropertyListSerialization（不依赖 PlistBuddy，可单测）；
/// 字段级修改（RunAtLoad）保留原文件其余内容。
public struct LaunchdPlist: @unchecked Sendable {
    public let plistPath: String
    /// FileManager 非线程安全但本类型只在单一后台任务内串行使用。
    public var fileManager: FileManager = .default

    public init(plistPath: String) {
        self.plistPath = plistPath
    }

    // MARK: 读取

    /// 读出整个 plist 字典；不存在或解析失败返回 nil。
    public func readContents() -> [String: Any]? {
        guard let data = fileManager.contents(atPath: plistPath) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// RunAtLoad 字段；plist 不存在或字段缺失返回 nil。
    public func readRunAtLoad() -> Bool? {
        readContents()?["RunAtLoad"] as? Bool
    }

    // MARK: 写入

    /// 写入整个字典为 XML plist（原子写）。目录不存在会自动创建。
    @discardableResult
    public func write(contents: [String: Any]) -> Bool {
        let url = URL(fileURLWithPath: plistPath)
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: contents, format: .xml, options: 0
        ) else { return false }
        return fileManager.createFile(atPath: plistPath, contents: data)
    }

    /// 只改 RunAtLoad 字段，保留其余内容。plist 不存在返回 false。
    @discardableResult
    public func writeRunAtLoad(_ on: Bool) -> Bool {
        guard var contents = readContents() else { return false }
        contents["RunAtLoad"] = on
        return write(contents: contents)
    }

    // MARK: 模板生成

    /// 标准 launchd plist 键集合（Label / ProgramArguments / KeepAlive 等）。
    /// `throttleInterval` 对应 ThrottleInterval（重启风暴抑制秒数），nil 不写入。
    public static func makeContents(
        label: String,
        programArguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        runAtLoad: Bool = true,
        keepAlive: Bool = true,
        throttleInterval: Int? = nil,
        stdoutPath: String? = nil,
        stderrPath: String? = nil
    ) -> [String: Any] {
        var contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": runAtLoad,
            "KeepAlive": keepAlive
        ]
        if let workingDirectory { contents["WorkingDirectory"] = workingDirectory }
        if let environment { contents["EnvironmentVariables"] = environment }
        if let throttleInterval { contents["ThrottleInterval"] = throttleInterval }
        if let stdoutPath { contents["StandardOutPath"] = stdoutPath }
        if let stderrPath { contents["StandardErrorPath"] = stderrPath }
        return contents
    }

    /// 若 plist 尚不存在则按给定内容创建；已存在时不覆盖。返回是否落盘成功。
    @discardableResult
    public func createIfMissing(contents: [String: Any]) -> Bool {
        guard !fileManager.fileExists(atPath: plistPath) else { return true }
        return write(contents: contents)
    }
}
