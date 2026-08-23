import Foundation

// MARK: - 只读探测

/// 一次探测得到的完整服务状态快照。
public struct LaunchdServiceStatus: Sendable, Equatable {
    /// 服务四态判定。
    public enum State: Sendable, Equatable {
        /// 未加载且无进程在跑。
        case stopped
        /// launchd 已加载、由它（或其子孙进程）提供服务。
        case managed
        /// 有进程在监听端口，但与 launchd 实例血缘无关（野进程）。
        case unmanagedExternal
        /// 多个实例同时监听端口。
        case portConflict(listeningCount: Int)
        /// launchd 已加载但未运行（启动中或崩溃）。
        case loadedNotRunning
    }

    public let state: State
    /// launchd 任务是否已加载。
    public let isLoaded: Bool
    /// 正在提供服务的进程 PID；未运行为 nil。
    public let pid: pid_t?
    /// 探测到的 TCP 监听端口；未知为 nil。
    public let port: UInt16?
    /// launchd 记录的 PID（可能与 serving PID 不同，pnpm/sh 包装场景）。
    public let launchdPID: pid_t?

    public init(
        state: State,
        isLoaded: Bool,
        pid: pid_t?,
        port: UInt16?,
        launchdPID: pid_t?
    ) {
        self.state = state
        self.isLoaded = isLoaded
        self.pid = pid
        self.port = port
        self.launchdPID = launchdPID
    }

    /// 是否有进程在提供服务（含野进程）。
    public var isRunning: Bool { pid != nil }
}

/// 只读系统探测层：只收集事实，不修改任何系统状态。
///
/// 刻意与「有副作用的操作」（`LaunchdControl`）分开。所有方法同步阻塞，
/// 调用方负责放到后台线程。
public struct LaunchdProbe: Sendable {
    /// 服务描述：launchd label、plist 路径、worker 命令行特征。
    public struct Target: Sendable {
        public let label: String
        public let plistPath: String
        /// pgrep -f 的命令行特征串，用于识别脱离 launchd 的野进程；
        /// 为 nil 时跳过野进程识别（只信 launchd PID）。
        public let workerPattern: String?

        public init(label: String, plistPath: String, workerPattern: String? = nil) {
            self.label = label
            self.plistPath = plistPath
            self.workerPattern = workerPattern
        }
    }

    public let target: Target

    public init(target: Target) {
        self.target = target
    }

    public init(label: String, plistPath: String, workerPattern: String? = nil) {
        self.init(target: Target(label: label, plistPath: plistPath, workerPattern: workerPattern))
    }

    // MARK: 单项探测

    /// `launchctl list` 中该任务的加载状态与 PID。
    public func launchdInfo() -> (isLoaded: Bool, pid: pid_t?) {
        let list = Shell.run(ExecutablePath.launchctl, ["list"])
        guard list.status == 0,
              let line = list.output.split(separator: "\n").first(where: { $0.contains(target.label) }) else {
            return (false, nil)
        }
        // launchctl list 输出形如: PID\tStatus\tLabel
        let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        let pid = cols.first.flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
        return (isLoaded: true, pid: pid)
    }

    /// 找出所有 worker 候选进程 PID：launchd PID + pgrep 特征匹配的野进程，
    /// 按 PID 去重，launchd PID 在前。
    ///
    /// 注意：pgrep -f 的 pattern 是 ERE，会匹配**任何**命令行含该子串的
    /// 进程（终端、编辑器、swift run 等）。因此：
    /// 1. 特征串中的 ERE 元字符需转义（"bin.ts web" 的 "." 会通配任意字符）；
    /// 2. 排除自身进程组（pgrep 可能命中发起探测的宿主命令行）。
    public func workerCandidates(including launchdPID: pid_t?) -> [pid_t] {
        var candidates: [pid_t] = []
        if let launchdPID { candidates.append(launchdPID) }
        if let pattern = target.workerPattern {
            let pg = Shell.run(ExecutablePath.pgrep, ["-f", Self.escapingERESpecials(pattern)])
            if pg.status == 0 {
                for p in pg.output.split(separator: "\n") {
                    if let pid = Int32(p.trimmingCharacters(in: .whitespaces)) {
                        // 排除自身及父进程链：pgrep -f 可能命中发起探测的
                        // 宿主/终端命令行（含特征串字面量）。
                        guard !isSelfOrAncestor(pid) else { continue }
                        candidates.append(pid)
                    }
                }
            }
        }
        var seen = Set<pid_t>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// 转义 ERE 特殊字符，让特征串按字面量匹配（避免 "bin.ts" 的 "."
    /// 通配任意字符造成误匹配）。
    static func escapingERESpecials(_ pattern: String) -> String {
        let specials = "\\.^$[]()|*+?{}"
        return String(pattern.flatMap { char in
            specials.contains(char) ? ["\\", char] : [char]
        })
    }

    /// 判断 pid 是否是当前进程自身或其祖先（沿 ppid 向上最多 20 层）。
    private func isSelfOrAncestor(_ pid: pid_t) -> Bool {
        let selfPID = getpid()
        var current = pid
        for _ in 0..<20 {
            if current == selfPID { return true }
            let ps = Shell.run(ExecutablePath.ps, ["-o", "ppid=", "-p", String(current)])
            guard let parent = Int32(ps.output.trimmingCharacters(in: .whitespacesAndNewlines)), parent > 0 else {
                return false
            }
            current = parent
        }
        return false
    }

    /// 在候选里找出真正监听端口的实例（它才是「在提供服务」的进程）。
    public func servingPID(among candidates: [pid_t]) -> pid_t? {
        for candidate in candidates where isListening(pid: candidate) {
            return candidate
        }
        return nil
    }

    /// 统计候选中有多少个进程在监听端口。
    public func listeningCount(among candidates: [pid_t]) -> Int {
        candidates.filter { isListening(pid: $0) }.count
    }

    /// 某 PID 是否有 TCP LISTEN 套接字。
    ///
    /// 注意：macOS 的 lsof 在同时给 `-p` 与 `-i` 时会忽略 `-p` 过滤，
    /// 因此只用 `-p` 过滤该 PID，再从输出里挑出 LISTEN 的 TCP 行。
    public func isListening(pid: pid_t) -> Bool {
        let lsof = Shell.run(ExecutablePath.lsof, ["-p", String(pid), "-nP"])
        return lsof.output.split(separator: "\n").contains {
            $0.contains("TCP") && $0.contains("(LISTEN)")
        }
    }

    /// 判断 child 是否是 ancestor 的后代（含自身）。
    ///
    /// 沿 `ps -o ppid=` 向上遍历进程树，最多爬 20 层防止意外死循环。
    /// launchd 经 pnpm / sh 包装启动时，真正监听端口的是子孙进程，
    /// 用此函数可正确识别「受 launchd 管理但 PID 不同」的场景。
    public func isDescendant(_ child: pid_t, of ancestor: pid_t) -> Bool {
        guard child != ancestor else { return true }
        var current = child
        for _ in 0..<20 {
            let ps = Shell.run(ExecutablePath.ps, ["-o", "ppid=", "-p", String(current)])
            let ppid = ps.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parent = Int32(ppid), parent > 0 else { return false } // 已到根或进程消失
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    /// 探测某 PID 正在监听的第一个 TCP 端口号；探测不到返回 nil。
    public func detectPort(pid: pid_t) -> UInt16? {
        // 形如: node 99013 ... TCP 127.0.0.1:3080 (LISTEN)
        let lsof = Shell.run(ExecutablePath.lsof, ["-p", String(pid), "-nP"])
        guard lsof.status == 0 else { return nil }
        for line in lsof.output.split(separator: "\n") {
            guard line.contains("TCP"), line.contains("(LISTEN)") else { continue }
            if let range = line.range(of: #":\d+ \(LISTEN\)"#, options: .regularExpression) {
                let token = String(line[range]).dropFirst() // "3080 (LISTEN)"
                let digits = token.prefix(while: { $0.isNumber })
                if let port = UInt16(digits) { return port }
            }
        }
        return nil
    }

    /// 开机自启是否开启（plist 的 RunAtLoad 字段）。plist 不存在返回 false。
    public func autostartEnabled() -> Bool {
        LaunchdPlist(plistPath: target.plistPath).readRunAtLoad() ?? false
    }

    // MARK: 全量快照

    /// 四态判定全量探测。多次 shell 调用（launchctl/pgrep/lsof/ps），毫秒级总量，
    /// 由调用方调度到后台线程执行。
    @discardableResult
    public func probe() -> LaunchdServiceStatus {
        let launchd = launchdInfo()
        let candidates = workerCandidates(including: launchd.pid)
        let serving = servingPID(among: candidates)
        let active = serving ?? candidates.first

        let state: LaunchdServiceStatus.State
        if active != nil {
            if launchd.isLoaded, let lp = launchd.pid, let sp = serving {
                if sp == lp || isDescendant(sp, of: lp) {
                    state = .managed
                } else {
                    let count = listeningCount(among: candidates)
                    state = count > 1 ? .portConflict(listeningCount: count) : .unmanagedExternal
                }
            } else if launchd.isLoaded {
                state = .managed
            } else {
                state = .unmanagedExternal
            }
        } else {
            state = launchd.isLoaded ? .loadedNotRunning : .stopped
        }

        let port = active.flatMap { detectPort(pid: $0) }
        return LaunchdServiceStatus(
            state: state,
            isLoaded: launchd.isLoaded,
            pid: active,
            port: port,
            launchdPID: launchd.pid
        )
    }
}
