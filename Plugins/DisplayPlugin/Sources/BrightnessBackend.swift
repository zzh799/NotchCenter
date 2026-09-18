import CoreGraphics
import Foundation

// MARK: - 亮度后端抽象与共享纯逻辑
//
// 两条控制通道（决策见 Agent Note 2026-09-19-builtin-brightness-system-path）：
// 外接屏走 DDC/CI（显示器侧的外部 I2C 总线，Apple Silicon 经 IOAVService、
// Intel 经 IOI2C）；内建屏没有那条总线，走系统亮度通道（DisplayServices，
// 与系统亮度键同一个值，见 SystemBrightnessBackend）。通道差异只体现在
// `BrightnessDisplay.control`，其余枚举 / 回读 / 写入 / 区间映射 / 合并写入
// 全部共用。

/// 一台可控显示器：标识、展示名与控制通道。
struct BrightnessDisplay: Hashable, Sendable {
    /// 亮度控制通道。
    enum Control: Hashable, Sendable {
        /// 外接屏：DDC/CI 外部 I2C 通道。
        case ddc
        /// 内建屏：DisplayServices 系统亮度通道（背光由系统接管）。
        case system
    }

    /// CoreGraphics 显示器标识（会话内稳定，显示重配后可能变化）。
    let id: CGDirectDisplayID
    /// 展示名：EDID 产品名优先，取不到用本地化兜底名。
    let name: String
    /// 控制通道，决定读写落到哪个后端。
    let control: Control

    init(id: CGDirectDisplayID, name: String, control: Control = .ddc) {
        self.id = id
        self.name = name
        self.control = control
    }
}

/// 一次亮度回读结果（当前值与量程上限）。
struct LuminanceReading: Equatable, Sendable {
    let value: Int
    let max: Int
}

/// 亮度读写 / 传输错误。
enum BrightnessError: Error, Equatable {
    case shortReply(count: Int)
    case badReplySource(UInt8)
    case badReplyCommand(UInt8)
    case badReplyVCP(UInt8)
    case badReplyChecksum
    case transportFailed(code: Int)
    case displayGone
    /// 该显示器不属于本后端负责的通道（后端装配错误，不应出现在正常路径）。
    case controlPathUnavailable
    /// 系统拒绝读写该屏亮度（DisplayServices 返回非 0）。
    case unsupported
}

/// 亮度变化观察句柄：`invalidate` 撤销注册，幂等。
protocol BrightnessChangeObservation: AnyObject {
    func invalidate()
}

/// 亮度控制后端。实现须把真实 IO 串行化到自己的队列上。
protocol DisplayBrightnessBackend: Sendable {
    /// 枚举本后端可调的显示器。
    func listDisplays() async -> [BrightnessDisplay]
    /// 回读亮度（显示器不支持回读时抛错，不作为「不可调节」的判定）。
    func readLuminance(_ display: BrightnessDisplay) async throws -> LuminanceReading
    /// 写入亮度。
    func writeLuminance(_ display: BrightnessDisplay, value: Int) async throws
    /// 观察外部（系统亮度键 / 自动调节 / 其它 App）造成的亮度变化。
    /// 返回 nil 表示本通道没有变化回调（DDC 外接屏即如此）。
    func observeBrightnessChanges(
        _ handler: @escaping @Sendable (CGDirectDisplayID, Double) -> Void
    ) -> BrightnessChangeObservation?
}

extension DisplayBrightnessBackend {
    /// 默认无观察能力。注意：本方法必须留在协议**要求**里（此处只给默认实现），
    /// 否则经存在类型调用时遵守类的实现会被静态分发遮蔽、永不执行
    /// （宿主的 `PluginServicesHookTests` 曾踩过同一坑）。
    func observeBrightnessChanges(
        _ handler: @escaping @Sendable (CGDirectDisplayID, Double) -> Void
    ) -> BrightnessChangeObservation? { nil }
}

// MARK: - 后端装配

/// DDC 后端选择：优先 IOAVService（Apple Silicon 符号存在即用）；
/// 符号缺失（Intel 切片）回退 IOI2C 路线。
enum DDCBackendFactory {
    static func make() -> DisplayBrightnessBackend? {
        if let backend = IOAVServiceBackend.makeIfAvailable() { return backend }
        return IOI2CBackend()
    }
}

/// 插件唯一的后端入口：两条通道合流成一张显示器列表。
enum BrightnessBackendFactory {
    static func make() -> DisplayBrightnessBackend {
        CompositeBackend(
            system: SystemBrightnessBackend.makeIfAvailable(),
            ddc: DDCBackendFactory.make())
    }
}

/// 两通道合流：内建屏（系统通道）排在前面，外接屏（DDC）随后；
/// 读写按 `control` 分发，观察只来自系统通道（DDC 侧没有变化回调）。
struct CompositeBackend: DisplayBrightnessBackend {
    let system: DisplayBrightnessBackend?
    let ddc: DisplayBrightnessBackend?

    func listDisplays() async -> [BrightnessDisplay] {
        var result: [BrightnessDisplay] = []
        if let system { result += await system.listDisplays() }
        if let ddc { result += await ddc.listDisplays() }
        return result
    }

    func readLuminance(_ display: BrightnessDisplay) async throws -> LuminanceReading {
        try await backend(for: display).readLuminance(display)
    }

    func writeLuminance(_ display: BrightnessDisplay, value: Int) async throws {
        try await backend(for: display).writeLuminance(display, value: value)
    }

    func observeBrightnessChanges(
        _ handler: @escaping @Sendable (CGDirectDisplayID, Double) -> Void
    ) -> BrightnessChangeObservation? {
        system?.observeBrightnessChanges(handler)
    }

    private func backend(for display: BrightnessDisplay) throws -> any DisplayBrightnessBackend {
        switch display.control {
        case .system:
            guard let system else { throw BrightnessError.controlPathUnavailable }
            return system
        case .ddc:
            guard let ddc else { throw BrightnessError.controlPathUnavailable }
            return ddc
        }
    }
}

// MARK: - 显示器候选过滤（纯逻辑，双通道共用；回归 DisplayPluginTests）

/// CG 在线列表的一行（纯逻辑单测直接构造；真机侧由 `online()` 填充）。
struct DisplayDescriptor: Equatable, Sendable {
    let id: CGDirectDisplayID
    let isBuiltin: Bool
    let isMirrored: Bool
    let isMain: Bool
}

extension DisplayDescriptor {
    /// 当前在线显示器（三个后端的唯一构造点）。
    static func online() -> [DisplayDescriptor] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplayDescriptor(
                id: id,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                isMain: id == CGMainDisplayID())
        }
    }
}

/// 候选过滤。
enum DisplayListFilter {
    /// 内建屏候选：系统亮度通道的适用对象（笔记本只有一块内建屏；合盖或
    /// Mac mini 类无内建屏的机器返回空）。
    static func builtinCandidates(_ displays: [DisplayDescriptor]) -> [CGDirectDisplayID] {
        visible(displays).filter(\.isBuiltin).map(\.id)
    }

    /// 外接屏候选：排除内建屏。
    static func externalCandidates(_ displays: [DisplayDescriptor]) -> [CGDirectDisplayID] {
        visible(displays).filter { !$0.isBuiltin }.map(\.id)
    }

    /// 镜像组只保留主显示器，避免同一物理屏出现两行滑杆。
    private static func visible(_ displays: [DisplayDescriptor]) -> [DisplayDescriptor] {
        displays.filter { !($0.isMirrored && !$0.isMain) }
    }
}

// MARK: - 写入合并

/// 写入合并状态机（纯逻辑；由 `BrightnessWriteChannel` 驱动，回归 DisplayPluginTests）。
///
/// 滑杆拖动以远快于硬件写入（DDC 约 10–50ms/次）的频率产生新值：在途写入期间
/// 只保留最新一个待写值，写入完成后补写终值——最终状态与滑杆一致，且
/// 任一时刻至多一次写入在途（多数显示器无法承受并发 DDC 会话）。
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
    let display: BrightnessDisplay
    let value: Int
}

/// 写入合并通道：串行 actor，任一时刻至多一次写入在途；在途期间新值
/// 只保留最新，写完补写终值。两次写入起始至少间隔 `minInterval`，避免
/// 拖动时把 DDC 总线打满。
actor BrightnessWriteChannel {
    static let minInterval: Duration = .milliseconds(80)

    private let backend: DisplayBrightnessBackend
    private var machine = CoalescedWriteStateMachine()
    private var lastWriteStart = ContinuousClock.now
    private var cancelled = false

    init(backend: DisplayBrightnessBackend) {
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
