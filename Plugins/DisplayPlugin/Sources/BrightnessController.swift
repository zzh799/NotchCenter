import Combine
import CoreGraphics
import Foundation

// MARK: - 亮度控制器（插件级共享单例）
//
// 多屏抽屉的同实例视图副本观察同一个控制器（面板与抽屉.md 共享状态约束）；
// 预览副本（isPreview）不触发枚举与写入。枚举在首个激活副本出现时进行，
// v1 不监听显示器热插拔（可调屏一个都不在时重开抽屉会重新枚举一次）。

/// 单台显示器的可观察亮度状态。
@MainActor
final class BrightnessDisplayModel: ObservableObject, Identifiable {
    enum State {
        /// 初值回读中。
        case probing
        /// 就绪（含回读失败但按缓存 / 50% 回退的情况）。
        case ready
        /// DDC 写入连续失败，本屏不可调节（不显示行）。
        case failed
    }

    let display: ExternalDisplay
    /// 亮度百分比 0...100（相对显示器自身量程）。
    @Published var percent: Double = 0
    /// 显示器亮度量程上限（回读获得，回读失败前按 100）。
    @Published var maxLuminance: Int = 100
    @Published var state: State = .probing
    /// 用户拖动中（区分拖动与程序回写，决定是否触发 DDC 写入）。
    var isDragging = false

    /// 展示排序用标识（display 为不可变 Sendable 值，可非隔离访问）。
    nonisolated var id: CGDirectDisplayID { display.id }

    init(display: ExternalDisplay) {
        self.display = display
    }
}

@MainActor
final class BrightnessController: ObservableObject {
    static let shared = BrightnessController(backend: DisplayDDC.makeBackend())

    /// 枚举顺序即展示顺序。
    @Published private(set) var orderedIDs: [CGDirectDisplayID] = []
    @Published private(set) var models: [CGDirectDisplayID: BrightnessDisplayModel] = [:]

    private let backend: DisplayDDCBackend?
    private lazy var channel: DDCWriteChannel? = backend.map(DDCWriteChannel.init)
    private var enumerationTask: Task<Void, Never>?
    private var suspended = false
    /// 连续写入失败计数（≥2 判定该屏 DDC 不可写，隐藏滑杆行）。
    private var writeFailures: [CGDirectDisplayID: Int] = [:]
    /// 内存级最近值缓存：初值回读失败时的回退（不持久化）。
    private var cachedValues: [CGDirectDisplayID: (percent: Double, max: Int)] = [:]

    init(backend: DisplayDDCBackend?) {
        self.backend = backend
    }

    /// 展示行：初值回读中的屏也显示（滑杆禁用），仅隐藏判定不可调节的屏。
    var rows: [BrightnessDisplayModel] {
        orderedIDs.compactMap { models[$0] }.filter { $0.state != .failed }
    }

    // MARK: 枚举与初值

    /// 首个激活副本出现时枚举显示器并回读初值；幂等、可重入（多屏并发调用安全）。
    func startIfNeeded() async {
        if let task = enumerationTask {
            await task.value
            return
        }
        if !rows.isEmpty { return }
        let task = Task { await self.runEnumeration() }
        enumerationTask = task
        await task.value
        enumerationTask = nil
    }

    private func runEnumeration() async {
        guard !suspended, let backend else { return }
        let displays = await backend.listDisplays()
        // 以最新枚举结果为准：新增的建模型，消失的移除；已就绪的保留状态。
        orderedIDs = displays.map(\.id)
        var next: [CGDirectDisplayID: BrightnessDisplayModel] = [:]
        for display in displays {
            if let existing = models[display.id] {
                next[display.id] = existing
            } else {
                next[display.id] = BrightnessDisplayModel(display: display)
            }
        }
        models = next
        for display in displays {
            guard let model = models[display.id], model.state != .ready else { continue }
            probe(model, backend: backend)
        }
    }

    /// 初值回读：300ms 超时，失败回退内存缓存或 50%（部分屏不支持回读，
    /// 回读失败不代表不可调节——那是写入连续失败的判定）。
    private func probe(_ model: BrightnessDisplayModel, backend: DisplayDDCBackend) {
        let display = model.display
        Task {
            do {
                let reading = try await withTimeout(.milliseconds(300)) {
                    try await backend.readLuminance(display)
                }
                model.maxLuminance = max(reading.max, 1)
                model.percent = Self.percent(value: reading.value, upperBound: model.maxLuminance)
                model.state = .ready
                cachedValues[display.id] = (model.percent, model.maxLuminance)
            } catch {
                let cached = cachedValues[display.id]
                model.maxLuminance = cached?.max ?? 100
                model.percent = cached?.percent ?? 50
                model.state = .ready
            }
        }
    }

    // MARK: 写入

    func requestWrite(_ model: BrightnessDisplayModel, percent: Double) {
        guard !suspended, let channel else { return }
        let clamped = min(max(percent, 0), 100)
        model.percent = clamped
        let value = Self.ddcValue(percent: clamped, upperBound: model.maxLuminance)
        cachedValues[model.display.id] = (clamped, model.maxLuminance)
        let display = model.display
        Task {
            let ok = await channel.submit(WriteRequest(display: display, value: value))
            guard !suspended else { return }
            if ok {
                writeFailures[display.id] = nil
            } else {
                let failures = (writeFailures[display.id] ?? 0) + 1
                writeFailures[display.id] = failures
                if failures >= 2 {
                    models[display.id]?.state = .failed
                    orderedIDs.removeAll { $0 == display.id }
                }
            }
        }
    }

    // MARK: 生命周期

    func suspend() {
        suspended = true
        Task { await channel?.cancel() }
    }

    /// 插件重新启用后恢复写入通道；下一次块出现会按需重新枚举。
    func resume() {
        suspended = false
        Task { await channel?.resume() }
    }

    // MARK: 值映射（纯逻辑，回归 DisplayPluginTests）

    /// 百分比 → DDC 原始值（四舍五入、夹紧量程；量程非法按 0）。
    /// 参数名用 upperBound，避免遮蔽全局 max() 函数。
    nonisolated static func ddcValue(percent: Double, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return min(max(Int((percent / 100 * Double(upperBound)).rounded()), 0), upperBound)
    }

    /// DDC 原始值 → 百分比。
    nonisolated static func percent(value: Int, upperBound: Int) -> Double {
        guard upperBound > 0 else { return 0 }
        return min(max(Double(value) / Double(upperBound) * 100, 0), 100)
    }
}

// MARK: - 超时原语

/// 初值回读超时。
struct DDCProbeTimeout: Error {}

/// 带超时的并发原语：超时后本调用抛错；后台操作自然结束（不中断在途 IO）。
func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw DDCProbeTimeout()
        }
        guard let first = try await group.next() else { throw DDCProbeTimeout() }
        group.cancelAll()
        return first
    }
}
