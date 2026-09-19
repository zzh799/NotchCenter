import Darwin
import Foundation

// MARK: - 执行环境（决策 3）
//
// 宿主从 Finder 启动时 `PATH` 是 launchd 给 GUI app 的最小值
// （/usr/bin:/bin:/usr/sbin:/sbin），从终端 `build.sh run` 启动时继承 shell——
// 不处理就是"开发时能跑、打包后找不到 pnpm"的确定性翻车。这里显式注入一份
// 补全的 PATH，让"命令能不能找到"变成与启动方式无关的确定性事实。
//
// **不用 `zsh -lc`**（登录 shell）：rc 里的 `echo` / `nvm` 默认加载会污染任务
// 日志，且结果依赖本机 rc 内容，不可测试不可复现。需要 nvm 时在任务命令里
// 显式 `source ~/.nvm/nvm.sh && nvm use 18 && …`，把依赖显式化在任务里。
enum ExecutionEnvironment {
    /// 注入的路径搜索目录（在继承的 PATH 之后追加，去重保序）。
    static let injectedDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        ".local/bin",
        ".bun/bin",
        ".cargo/bin",
        "Library/pnpm",
    ]

    /// 任务的可执行文件路径（绝对路径，`posix_spawn` 不走 PATH 查找）。
    static let shellPath = "/bin/zsh"

    /// 构造子进程环境：继承宿主环境 → 覆盖 PATH → 叠加任务级 env。
    ///
    /// 继承而不是从零构造，是因为 `TMPDIR` / `HOME` / `USER` / `LANG` 这些
    /// 缺失会让不少工具直接崩或行为诡异；只覆盖真正需要确定的那一项。
    static func make(task: ScheduledTask) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = mergedPath(inherited: environment["PATH"])
        for (key, value) in task.environment {
            environment[key] = value
        }
        return environment
    }

    /// 继承 PATH ∪ 注入目录（去重、保持先继承后注入的顺序）。
    static func mergedPath(inherited: String?) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        let inheritedParts = (inherited ?? "").split(separator: ":").map(String.init)
        for part in inheritedParts where !part.isEmpty {
            if seen.insert(part).inserted { ordered.append(part) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for directory in injectedDirectories {
            let resolved = directory.hasPrefix("/") ? directory : home + "/" + directory
            if seen.insert(resolved).inserted { ordered.append(resolved) }
        }
        // 兜底：注入全丢也不至于连 /bin 都没有。
        for fallback in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where seen.insert(fallback).inserted {
            ordered.append(fallback)
        }
        return ordered.joined(separator: ":")
    }

    /// 任务的工作目录：显式路径优先，否则 `$HOME`。
    static func workingDirectory(for task: ScheduledTask) -> String {
        guard let raw = task.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return (raw as NSString).expandingTildeInPath
    }
}

// MARK: - 执行结果

enum RunOutcome: Equatable {
    /// 正常退出（`code` 为退出码；被信号杀死时为 128 + 信号号）。
    case exited(code: Int32)
    /// 守卫超时被杀。
    case timedOut
    /// 宿主退出 / 插件被禁用时被杀。
    case aborted
    /// 起不来（shell 路径不存在、cwd 不存在等）。
    case spawnFailed(String)

    /// 记录状态（`aborted` 与 `failed` 必须分开——被你自己关掉不是失败）。
    var status: TaskRun.Status {
        switch self {
        case let .exited(code): return code == 0 ? .succeeded : .failed
        case .timedOut: return .timedOut
        case .aborted: return .aborted
        case .spawnFailed: return .failed
        }
    }

    /// 落盘退出码；`spawnFailed` 与信号终止用 -1 表达"没有正常退出码"。
    var exitCode: Int32? {
        switch self {
        case let .exited(code): return code
        case .timedOut, .aborted, .spawnFailed: return nil
        }
    }
}

// MARK: - 可取消句柄

/// 一次执行的可取消句柄，持有**进程组** id。
///
/// 超时/中止必须杀整个进程组而不是直接子进程：`zsh -c "a | b"` 里 `b` 不随
/// zsh 死，只杀直接子进程会让它变孤儿继续往日志尾巴写。子进程由
/// `POSIX_SPAWN_SETPGROUP`（pgroup = 0）建成自己的组长，`pgid == pid`，
/// 于是 `kill(-pid, …)` 命中整棵树。
final class ProcessCancellation: @unchecked Sendable {
    enum Reason: Equatable {
        case none
        case timeout
        case abort
    }

    /// SIGTERM 后等这么久仍未退出就 SIGKILL（进程忽略 SIGTERM 时唯一出路）。
    static let forceKillGrace: TimeInterval = 5

    private let lock = NSLock()
    private var pid: pid_t?
    private var currentReason: Reason = .none
    private var forceKillScheduled = false

    var reason: Reason {
        lock.lock()
        defer { lock.unlock() }
        return currentReason
    }

    /// 子进程 spawn 成功后立即登记。若此前已请求取消（spawn 与登记之间的
    /// 竞态窗口），这里补杀一次，否则那次取消会被永久吞掉。
    func attach(pid: pid_t) {
        lock.lock()
        self.pid = pid
        let alreadyCancelled = currentReason != .none
        lock.unlock()
        guard alreadyCancelled else { return }
        signalGroup(pid, SIGTERM)
        scheduleForceKill(pid)
    }

    /// 请求取消（幂等；首个原因生效，不随后续请求改写）。
    func cancel(_ reason: Reason) {
        lock.lock()
        if currentReason == .none { currentReason = reason }
        let pid = self.pid
        lock.unlock()
        guard let pid else { return } // attach 时补杀
        signalGroup(pid, SIGTERM)
        scheduleForceKill(pid)
    }

    private func signalGroup(_ pid: pid_t, _ signal: Int32) {
        // 负 pid = 对进程组发信号；前提是子进程由 POSIX_SPAWN_SETPGROUP 建组。
        _ = kill(-pid, signal)
        // 兜底：极端情况下建组失败（pid 组不存在）时至少杀掉直接子进程。
        _ = kill(pid, signal)
    }

    private func scheduleForceKill(_ pid: pid_t) {
        lock.lock()
        guard !forceKillScheduled else {
            lock.unlock()
            return
        }
        forceKillScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.forceKillGrace) {
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
        }
    }
}

// MARK: - 执行器

/// 同步执行一个任务命令，输出边读边喂给 `sink`。调用方负责丢到后台线程
/// （`Task.detached`），本类型不做任何调度。
enum ProcessRunner {
    /// 直接子进程退出后，最多再收多久它的"后代"仍持有管道写端的输出。
    ///
    /// 存在的意义：任务里若启动了常驻进程（`my_daemon &`），管道写端不会随
    /// shell 退出而关闭，没有这个宽限 run 会永远卡在"运行中"。副作用是宽限
    /// 结束后我们关掉读端，那个后代进程再写标准输出会拿到 EPIPE——这是
    /// "run 的生命周期 = 直接子进程的生命周期"这一语义的必然结果，已在
    /// Agent Note 与插件 README 记明。
    static let descendantDrainGrace: TimeInterval = 1.0

    private static let pollIntervalMilliseconds: Int32 = 100
    private static let readBufferSize = 8192

    static func run(
        task: ScheduledTask,
        sink: RunOutputSink?,
        cancellation: ProcessCancellation
    ) -> RunOutcome {
        let arguments = [ExecutionEnvironment.shellPath, "-c", task.command]
        let environment = ExecutionEnvironment.make(task: task)
        let workingDirectory = ExecutionEnvironment.workingDirectory(for: task)
        // 超时策略：任务级 0 = 关闭；nil = 用调用方传入的全局默认（由 SchedulerCore
        // 折算成具体秒数后写进 task.timeoutSeconds 之前的那一层决定，这里只认最终值）。
        let timeout = task.timeoutSeconds.flatMap { $0 > 0 ? TimeInterval($0) : nil }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            return .spawnFailed("pipe() failed")
        }
        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]

        // SDK 里 `posix_spawn_file_actions_t` / `posix_spawnattr_t` 都是 `void *`，
        // Swift 侧是可按需分配的裸指针——必须先 init 再传址给各 add*/set* 调用。
        var fileActions: posix_spawn_file_actions_t?
        _ = posix_spawn_file_actions_init(&fileActions)
        defer { _ = posix_spawn_file_actions_destroy(&fileActions) }
        // stdout 与 stderr 合并（与 LaunchdControlKit.Shell 同语义，也是任务
        // 作者对"看到命令干了什么"的默认预期）；两边都指向管道写端。
        _ = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)
        _ = posix_spawn_file_actions_addclose(&fileActions, readFD)
        _ = posix_spawn_file_actions_addclose(&fileActions, writeFD)
        let chdirResult = workingDirectory.withCString {
            posix_spawn_file_actions_addchdir_np(&fileActions, $0)
        }
        guard chdirResult == 0 else {
            close(readFD)
            close(writeFD)
            return .spawnFailed("cannot set working directory: \(workingDirectory)")
        }

        var attributes: posix_spawnattr_t?
        _ = posix_spawnattr_init(&attributes)
        defer { _ = posix_spawnattr_destroy(&attributes) }
        // 建新进程组（pgroup = 0 → pgid = 子进程 pid），超时才能杀整棵树。
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        _ = posix_spawnattr_setpgroup(&attributes, 0)

        let argv = cStrings(arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            argv.dropLast().forEach { free($0) }
            envp.dropLast().forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(
            &pid,
            ExecutionEnvironment.shellPath,
            &fileActions,
            &attributes,
            argv,
            envp
        )
        close(writeFD)
        guard spawnResult == 0 else {
            close(readFD)
            return .spawnFailed("posix_spawn failed with code \(spawnResult)")
        }

        cancellation.attach(pid: pid)

        var timeoutTimer: DispatchSourceTimer?
        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { cancellation.cancel(.timeout) }
            timer.resume()
            timeoutTimer = timer
        }
        defer { timeoutTimer?.cancel() }

        let (status, sawExit) = drain(readFD: readFD, pid: pid, sink: sink)
        close(readFD)

        if cancellation.reason == .abort { return .aborted }
        if cancellation.reason == .timeout { return .timedOut }
        guard sawExit else { return .spawnFailed("child reaped by someone else") }
        return .exited(code: exitCode(fromWaitStatus: status))
    }

    // MARK: 收流循环

    /// 非阻塞读 + `poll` 心跳。返回（wait status，是否成功 waitpid 到）。
    ///
    /// 不用"阻塞读完管道再 `waitUntilExit`"的写法：那条路径在"子进程先退出、
    /// 后代仍持有写端"时会永久挂住。
    private static func drain(
        readFD: Int32,
        pid: pid_t,
        sink: RunOutputSink?
    ) -> (status: Int32, sawExit: Bool) {
        let originalFlags = fcntl(readFD, F_GETFL, 0)
        _ = fcntl(readFD, F_SETFL, originalFlags | O_NONBLOCK)

        var status: Int32 = 0
        var sawExit = false
        var pipeClosed = false
        var drainDeadline: Date?
        var buffer = [UInt8](repeating: 0, count: readBufferSize)

        while true {
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, pollIntervalMilliseconds)
            if ready > 0 {
                let count = read(readFD, &buffer, readBufferSize)
                if count > 0 {
                    sink?.append(Data(bytes: buffer, count: count))
                } else if count == 0 {
                    pipeClosed = true
                } else if errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK {
                    pipeClosed = true
                }
            }

            if !sawExit {
                var probe: Int32 = 0
                let result = waitpid(pid, &probe, WNOHANG)
                if result == pid {
                    sawExit = true
                    status = probe
                    drainDeadline = Date().addingTimeInterval(descendantDrainGrace)
                } else if result < 0 && errno == ECHILD {
                    // 已被回收（不该发生，但不该因此死循环）。
                    sawExit = true
                    status = 0
                    drainDeadline = Date().addingTimeInterval(descendantDrainGrace)
                }
            }

            if pipeClosed { break }
            if sawExit, let deadline = drainDeadline, Date() >= deadline { break }
        }

        // 管道先关（子进程主动关掉 stdout 但仍在跑）时补一次阻塞回收。
        if !sawExit {
            var blocking: Int32 = 0
            if waitpid(pid, &blocking, 0) == pid {
                status = blocking
                sawExit = true
            }
        }
        return (status, sawExit)
    }

    // MARK: C 互操作辅助

    /// Swift 的 `Darwin` 不导入 `WIFEXITED` / `WEXITSTATUS` 这类函数式宏，
    /// 按 Darwin 的位布局自行判定（`_WSTATUS(x) = x & 0177`）。
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 {
            return (status >> 8) & 0xff
        }
        // 被信号终止：约定 128 + 信号号 表达，与非零退出码落在同一判定里。
        return 128 + low
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        result.append(nil)
        return result
    }
}
