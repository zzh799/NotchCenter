import CoreGraphics
import Foundation

// MARK: - DDC 后端抽象与共享纯逻辑

/// 一台经枚举确认的外接显示器。
struct ExternalDisplay: Hashable, Sendable {
    /// CoreGraphics 显示器标识（会话内稳定，显示重配后可能变化）。
    let id: CGDirectDisplayID
    /// 展示名：EDID 产品名优先，取不到用本地化兜底名。
    let name: String
}

/// 一次亮度回读结果（当前值与 VCP 特征量程上限）。
struct LuminanceReading: Equatable, Sendable {
    let value: Int
    let max: Int
}

/// DDC 传输 / 解码错误。
enum DDCError: Error, Equatable {
    case shortReply(count: Int)
    case badReplySource(UInt8)
    case badReplyCommand(UInt8)
    case badReplyVCP(UInt8)
    case badReplyChecksum
    case transportFailed(code: Int)
    case displayGone
}

/// 亮度控制的 DDC 后端抽象。实现须把真实 IO 串行化到自己的队列上。
protocol DisplayDDCBackend: Sendable {
    /// 枚举外接可调显示器（实现自行排除内建屏 / 虚拟屏 / 无 DDC 通道的屏）。
    func listDisplays() async -> [ExternalDisplay]
    /// 回读亮度（显示器不支持回读时抛错，不作为「不可调节」的判定）。
    func readLuminance(_ display: ExternalDisplay) async throws -> LuminanceReading
    /// 写入亮度。
    func writeLuminance(_ display: ExternalDisplay, value: Int) async throws
}

/// DDC 后端选择：优先 IOAVService（Apple Silicon 符号存在即用）；
/// 符号缺失（Intel 切片）回退 IOI2C 路线。
enum DisplayDDC {
    static func makeBackend() -> DisplayDDCBackend? {
        if let backend = IOAVServiceBackend.makeIfAvailable() { return backend }
        return IOI2CBackend()
    }
}

/// CG 在线列表 → 可调外接屏候选（纯逻辑，双后端共用；回归 DisplayPluginTests）。
enum DisplayListFilter {
    static func externalCandidates(
        _ displays: [(id: CGDirectDisplayID, isBuiltin: Bool, isMirrored: Bool, isMain: Bool)]
    ) -> [CGDirectDisplayID] {
        displays
            .filter { candidate in
                if candidate.isBuiltin { return false }
                // 镜像组只保留主显示器，避免同一物理屏出现两行滑杆。
                if candidate.isMirrored && !candidate.isMain { return false }
                return true
            }
            .map(\.id)
    }
}

/// 写入合并状态机（纯逻辑；由 `DDCWriteChannel` 驱动，回归 DisplayPluginTests）。
///
/// 滑杆拖动以远快于 DDC 写入（约 10–50ms/次）的频率产生新值：在途写入期间
/// 只保留最新一个待写值，写入完成后补写终值——最终状态与滑杆一致，且
/// 任一时刻至多一次 DDC 传输在途（多数显示器无法承受并发 DDC 会话）。
struct CoalescedWriteStateMachine: Equatable {
    private(set) var inFlight: Int?
    private(set) var pending: Int?

    /// 新目标值到达。返回 true 表示机器空闲、需要驱动一次写入。
    mutating func submit(_ value: Int) -> Bool {
        if inFlight != nil {
            pending = value
            return false
        }
        inFlight = value
        return true
    }

    /// 在途写入结束。返回下一个待写值；nil 表示机器回到空闲。
    mutating func finishFlight() -> Int? {
        let next = pending
        pending = nil
        inFlight = next
        return next
    }
}

/// 一次待提交的亮度写入。
struct WriteRequest: Sendable {
    let display: ExternalDisplay
    let value: Int
}

/// 写入合并通道：串行 actor，任一时刻至多一次 DDC 写入在途；在途期间新值
/// 只保留最新，写完补写终值。两次写入起始至少间隔 `minInterval`，避免
/// 拖动时把 DDC 总线打满。
actor DDCWriteChannel {
    static let minInterval: Duration = .milliseconds(80)

    private let backend: DisplayDDCBackend
    private var machine = CoalescedWriteStateMachine()
    private var lastWriteStart = ContinuousClock.now
    private var cancelled = false

    init(backend: DisplayDDCBackend) {
        self.backend = backend
    }

    /// 提交目标值；空闲时由本调用驱动写入直至队列清空。
    /// 返回「本调用是否直接驱动了写入且全部成功」；合并进既有驱动循环的
    /// 提交一律返回 true（成败由驱动那次提交的调用方反馈）。
    func submit(_ request: WriteRequest) async -> Bool {
        guard !cancelled else { return false }
        guard machine.submit(request.value) else { return true }
        var ok = true
        var current = request.value
        while true {
            guard !cancelled else { return ok }
            await pace()
            do {
                try await backend.writeLuminance(request.display, value: current)
            } catch {
                ok = false
            }
            guard let next = machine.finishFlight() else { break }
            current = next
        }
        return ok
    }

    /// 停止驱动新写入（插件禁用时）；在途传输自然结束后通道静默。
    func cancel() {
        cancelled = true
    }

    /// 重新允许写入（插件重新启用）。
    func resume() {
        cancelled = false
    }

    /// 两次写入起始至少间隔 `minInterval`。
    private func pace() async {
        let elapsed = ContinuousClock.now - lastWriteStart
        if elapsed < Self.minInterval {
            try? await Task.sleep(for: Self.minInterval - elapsed)
        }
        lastWriteStart = ContinuousClock.now
    }
}
