import Foundation

// MARK: - MediaRemote 桥（借 /usr/bin/perl 进程代读私有框架）
//
// 为什么不能自己读：macOS 15.4 起系统只放行 bundle id 以 com.apple.* 开头的进程访问
// MediaRemote。宿主是无沙盒、ad-hoc 签名的进程，直连查询恒返回空（本机实测：同一份
// 二进制在自建 .app 里返回空、在 /usr/bin/perl 里返回数据）。可用且被社区验证的绕行
// 方式是让 /usr/bin/perl（bundle id 恰是 com.apple.perl）加载 helper framework 代跑
// 查询，把结果打成 JSON 写 stdout 给宿主读。机制与判定依据见
// docs/agents/系统集成与多语言.md 的「私有框架访问」一节。
//
// 桥资源（helper framework + mediaremote-adapter.pl，源码 vendored 在
// Vendor/mediaremote-adapter）由 build.sh 编译并复制进插件 bundle 的
// Contents/Resources/Bridge/，本类型只负责起停子进程与逐行转发。

/// 桥子进程的事件。
enum MediaRemoteBridgeEvent {
    /// 一行 JSON 输出（stream 每次变化一行）。
    case line(String)
    /// 桥不可用：资源缺失、子进程启动失败、或观测期间子进程结束。
    /// 主动 `stop()` 不会产生该事件（会话已作废）。
    case unavailable
}

@MainActor
final class MediaRemoteBridge {
    private static let resourceDirectoryName = "Bridge"
    private static let scriptName = "mediaremote-adapter.pl"
    private static let frameworkName = "MediaRemoteAdapter.framework"

    /// stream 输出去抖（毫秒）：播放器高频刷新进度时不必逐帧转发。
    private static let streamDebounceMilliseconds = 200

    /// 会话号：`stop()` 与下一次 `start()` 都会递增，用来丢弃旧子进程的迟到回调
    /// （`terminationHandler` 在后台线程、可能晚于 stop 到达）。
    private var session = 0
    private var streamProcess: Process?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer: [UInt8] = []
    /// 短命的 send 子进程。必须持有到退出：Process 不 retain 的话子进程会变成僵尸。
    private var commandProcesses: [Process] = []

    /// 桥资源是否随包就位（纯本地检查，不启动子进程）。
    var hasResources: Bool { Self.locateResources() != nil }

    // MARK: 观测

    func start(_ handler: @escaping @MainActor (MediaRemoteBridgeEvent) -> Void) {
        guard streamProcess == nil else { return }
        guard let paths = Self.locateResources() else {
            handler(.unavailable)
            return
        }

        session += 1
        let currentSession = session
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // --no-diff：整份 payload 逐行给，省掉本地合并差分的状态机（上游默认是差分）。
        // 多打的那点字节由 `--debounce` 与控制器自身的"只在变化时发布"吸收。
        // --no-artwork：本组件只展示应用图标，不需要曲目封面（那是每帧几百 KB 的 base64）。
        process.arguments = [
            paths.script.path,
            paths.framework.path,
            "stream",
            "--no-diff",
            "--no-artwork",
            "--debounce=\(Self.streamDebounceMilliseconds)",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.session == currentSession else { return }
                self.teardownStream()
                handler(.unavailable)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.session == currentSession else { return }
                self.consume(data, handler: handler)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            handler(.unavailable)
            return
        }
        streamProcess = process
        stdoutHandle = pipe.fileHandleForReading
    }

    func stop() {
        guard streamProcess != nil || stdoutHandle != nil else { return }
        session += 1
        teardownStream()
    }

    private func teardownStream() {
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stdoutBuffer.removeAll()
        // 上游实现只在收到 SIGTERM 时退出，`terminate()` 发的正是 SIGTERM。
        streamProcess?.terminate()
        streamProcess = nil
    }

    /// 按行切分 stdout：管道每次回调给的字节数没有行边界保证，必须自己缓冲。
    private func consume(_ data: Data, handler: @escaping @MainActor (MediaRemoteBridgeEvent) -> Void) {
        stdoutBuffer.append(contentsOf: data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineBytes = stdoutBuffer[0..<newline]
            stdoutBuffer.removeFirst(newline + 1)
            guard let line = String(bytes: lineBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces),
                !line.isEmpty
            else { continue }
            handler(.line(line))
        }
    }

    // MARK: 控制

    /// 投递一次控制命令（短命子进程，发完即退）。
    /// 返回是否成功启动子进程；命令本身是否被播放器接受不在返回值里。
    @discardableResult
    func send(commandID: Int) -> Bool {
        guard let paths = Self.locateResources() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script.path, paths.framework.path, "send", "\(commandID)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        commandProcesses.append(process)
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.commandProcesses.removeAll { $0 === finished }
            }
        }
        return true
    }

    // MARK: 资源定位

    private struct Paths {
        let script: URL
        let framework: URL
    }

    /// 定位插件 bundle 内的桥资源；缺任一即视为不可用。
    private static func locateResources() -> Paths? {
        guard let resources = Bundle(for: MediaControlsPlugin.self).resourceURL else { return nil }
        let bridge = resources.appendingPathComponent(resourceDirectoryName, isDirectory: true)
        let script = bridge.appendingPathComponent(scriptName)
        let framework = bridge.appendingPathComponent(frameworkName, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: script.path),
              fileManager.fileExists(atPath: framework.path)
        else { return nil }
        return Paths(script: script, framework: framework)
    }
}
