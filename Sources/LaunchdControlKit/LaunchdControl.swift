import Foundation

// MARK: - 副作用操作

/// launchd 服务的副作用操作层：bootstrap / bootout / RunAtLoad 写入。
///
/// 刻意与只读探测（`LaunchdProbe`）分开。所有方法同步阻塞，调用方负责
/// 放到后台线程。
public struct LaunchdControl: Sendable {
    public let target: LaunchdProbe.Target

    public init(target: LaunchdProbe.Target) {
        self.target = target
    }

    public init(label: String, plistPath: String, workerPattern: String? = nil) {
        self.init(target: LaunchdProbe.Target(label: label, plistPath: plistPath, workerPattern: workerPattern))
    }

    private var probe: LaunchdProbe { LaunchdProbe(target: target) }

    /// 加载并启动服务：`launchctl bootstrap gui/<uid> <plist>`。
    /// plist 不存在时返回 false 并填入错误信息。
    @discardableResult
    public func start() -> Bool {
        guard FileManager.default.fileExists(atPath: target.plistPath) else { return false }
        let result = Shell.run(
            ExecutablePath.launchctl,
            ["bootstrap", launchdGUIDomain(), target.plistPath]
        )
        return result.status == 0
    }

    /// 停止并卸载服务：`launchctl bootout gui/<uid>/<label>`。
    @discardableResult
    public func stop() -> Bool {
        let result = Shell.run(
            ExecutablePath.launchctl,
            ["bootout", "\(launchdGUIDomain())/\(target.label)"]
        )
        // bootout 对「未加载」的任务会报非零退出，视为已停止（幂等）。
        return result.status == 0
    }

    /// 重启：优先 `launchctl kickstart -k`（launchd 内部 kill + respawn，
    /// 单命令无 bootout→bootstrap 的异步竞态）。kickstart 要求任务已加载，
    /// 未加载时回退到 bootstrap 直接启动。返回是否成功。
    @discardableResult
    public func restart() -> Bool {
        guard probe.launchdInfo().isLoaded else { return start() }
        let result = Shell.run(
            ExecutablePath.launchctl,
            ["kickstart", "-k", "\(launchdGUIDomain())/\(target.label)"]
        )
        return result.status == 0
    }

    /// 读取开机自启状态；plist 不存在或字段缺失返回 nil。
    public func readRunAtLoad() -> Bool? {
        LaunchdPlist(plistPath: target.plistPath).readRunAtLoad()
    }

    /// 写入开机自启（plist 的 RunAtLoad 字段）。开启时若服务未加载会顺带 bootstrap。
    @discardableResult
    public func setAutostart(_ on: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: target.plistPath) else { return false }
        let ok = Shell.run(
            ExecutablePath.plistBuddy,
            ["-c", "Set :RunAtLoad \(on ? "true" : "false")", target.plistPath]
        ).status == 0
        guard ok else { return false }
        if on {
            let info = probe.launchdInfo()
            if !info.isLoaded { return start() }
        }
        return true
    }
}
