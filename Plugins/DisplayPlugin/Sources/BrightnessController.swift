import Combine
import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 亮度控制器（插件级共享单例）
//
// 多屏抽屉的同实例视图副本观察同一个控制器（面板与抽屉.md 共享状态约束）；
// 预览副本（isPreview）不触发枚举与写入。枚举在首个激活副本出现时进行，
// 显示器插拔 / 屏幕参数变化经 `refresh()` 差量重枚举（DisplayPlugin 监听
// didChangeScreenParametersNotification 后调用）：消失的屏移除、新增的屏
// 回读初值、存活屏保留状态不重复回读。内建屏与外接屏同列一张表，
// 差异只在 `BrightnessDisplay.control`（见 BrightnessBackend 文件头）。

/// 单台显示器的可观察亮度状态。
@MainActor
final class BrightnessDisplayModel: ObservableObject, Identifiable {
    enum State {
        /// 初值回读中。
        case probing
        /// 就绪（含回读失败但按缓存 / 50% 回退的情况）。
        case ready
        /// 写入连续失败，本屏不可调节（不显示行）。
        case failed
    }

    let display: BrightnessDisplay
    /// 亮度百分比 0...100（相对有效区间，无自定义即全量程，见有效区间）。
    @Published var percent: Double = 0
    /// 亮度量程上限（回读获得，回读失败前按 100）。
    @Published var maxLuminance: Int = 100
    @Published var state: State = .probing
    /// 用户拖动中（区分拖动与程序回写，决定是否触发写入）。
    var isDragging = false

    /// 展示排序用标识（display 为不可变 Sendable 值，可非隔离访问）。
    nonisolated var id: CGDirectDisplayID { display.id }

    init(display: BrightnessDisplay) {
        self.display = display
    }
}

@MainActor
final class BrightnessController: ObservableObject {
    static let shared = BrightnessController(backend: BrightnessBackendFactory.make())

    /// 本机写入后的静默窗口：期间的系统通知视为自写回声，不回灌（见回灌守卫）。
    private static let localWriteQuietPeriod: Duration = .milliseconds(250)

    /// 枚举顺序即展示顺序（内建屏在前，见 CompositeBackend）。
    @Published private(set) var orderedIDs: [CGDirectDisplayID] = []
    @Published private(set) var models: [CGDirectDisplayID: BrightnessDisplayModel] = [:]
    /// 按屏自定义写入区间（无条目即全量程；两块共用，见 DDCLuminanceRange）。
    @Published private(set) var customRanges: [CGDirectDisplayID: DDCLuminanceRange] = [:]

    private var rangeStore: StateStore?

    private let backend: DisplayBrightnessBackend?
    private lazy var channel: BrightnessWriteChannel? = backend.map(BrightnessWriteChannel.init)
    private var enumerationTask: Task<Void, Never>?
    private var suspended = false
    /// 系统亮度变化的观察（内建屏）；插件禁用时撤销。
    private var changeObservation: BrightnessChangeObservation?
    /// 连续写入失败计数（≥2 判定该屏不可写，隐藏滑杆行）。
    private var writeFailures: [CGDirectDisplayID: Int] = [:]
    /// 本机最近一次写入时刻：抑制自己写入引发的系统通知回灌（见回灌守卫）。
    private var lastLocalWrite: [CGDirectDisplayID: ContinuousClock.Instant] = [:]
    /// 内存级最近值缓存：初值回读失败时的回退（不持久化）。
    private var cachedValues: [CGDirectDisplayID: (percent: Double, max: Int)] = [:]

    init(backend: DisplayBrightnessBackend?) {
        self.backend = backend
    }

    /// 展示行：初值回读中的屏也显示（滑杆位置留空槽占位，见
    /// `DisplaySlidersBlockView`），仅隐藏判定不可调节的屏。
    var rows: [BrightnessDisplayModel] {
        orderedIDs.compactMap { models[$0] }.filter { $0.state != .failed }
    }

    // MARK: DDC 写入区间（按屏全局，两块共用）

    /// 注入插件级存储并载入已存区间（DisplayPlugin.attachServices 调用；
    /// 设置视图首现时亦可重复调用，幂等）。
    func configure(store: StateStore) {
        rangeStore = store
        let loaded = DDCLuminanceRangeLogic.loadAll(from: store)
        var next: [CGDirectDisplayID: DDCLuminanceRange] = [:]
        for (key, range) in loaded {
            guard let id = UInt32(key) else { continue }
            next[CGDirectDisplayID(id)] = range
        }
        customRanges = next
    }

    /// 该屏的有效写入区间（无自定义即 0...maxLuminance）。
    func effectiveBounds(for displayID: CGDirectDisplayID, maxLuminance: Int) -> (lower: Int, upper: Int) {
        DDCLuminanceRangeLogic.effectiveRange(
            custom: customRanges[displayID], maxLuminance: maxLuminance)
    }

    /// 设置该屏自定义区间：钳到当前已知量程，滑杆按同一硬件值重算百分比不跳变。
    func setRange(for displayID: CGDirectDisplayID, min: Int, max: Int) {
        guard let model = models[displayID] else {
            persistRange(DDCLuminanceRange(min: min, max: max), for: displayID)
            return
        }
        let oldBounds = effectiveBounds(for: displayID, maxLuminance: model.maxLuminance)
        let oldRaw = Self.ddcValue(
            percent: model.percent, lowerBound: oldBounds.lower, upperBound: oldBounds.upper)
        persistRange(DDCLuminanceRange(min: min, max: max), for: displayID)
        let newBounds = effectiveBounds(for: displayID, maxLuminance: model.maxLuminance)
        model.percent = Self.percent(
            value: oldRaw, lowerBound: newBounds.lower, upperBound: newBounds.upper)
        cachedValues[displayID] = (model.percent, model.maxLuminance)
    }

    /// 清除该屏自定义区间，回全量程（同样按硬件值重算百分比）。
    func clearRange(for displayID: CGDirectDisplayID) {
        guard let model = models[displayID] else {
            customRanges.removeValue(forKey: displayID)
            persistAllRanges()
            return
        }
        let oldBounds = effectiveBounds(for: displayID, maxLuminance: model.maxLuminance)
        let oldRaw = Self.ddcValue(
            percent: model.percent, lowerBound: oldBounds.lower, upperBound: oldBounds.upper)
        customRanges.removeValue(forKey: displayID)
        persistAllRanges()
        model.percent = Self.percent(value: oldRaw, upperBound: model.maxLuminance)
        cachedValues[displayID] = (model.percent, model.maxLuminance)
    }

    private func persistRange(_ range: DDCLuminanceRange, for displayID: CGDirectDisplayID) {
        customRanges[displayID] = range
        persistAllRanges()
    }

    private func persistAllRanges() {
        var raw: [String: DDCLuminanceRange] = [:]
        for (id, range) in customRanges {
            raw[DDCLuminanceRangeLogic.key(for: id)] = range
        }
        DDCLuminanceRangeLogic.saveAll(raw, to: rangeStore)
    }

    // MARK: 枚举与初值

    /// 首个激活副本出现时枚举显示器并回读初值；幂等、可重入（多屏并发调用安全）。
    func startIfNeeded() async {
        // 已有枚举结果时也要经过这里：插件禁用—启用往返会撤销观察，本条是重建入口。
        ensureSystemBrightnessObservation()
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
        // 消失的屏清掉连续失败计数：同 id 重插后从零计数（走写入成功即复位
        // 之外的又一入口）；内存缓存按 id 键控、体积极小，保留以便同 id 重插
        // 回退到记忆亮度（新 id 重连本也匹配不到，见 README 已知边界）。
        let live = Set(displays.map(\.id))
        writeFailures = writeFailures.filter { live.contains($0.key) }
        for display in displays {
            guard let model = models[display.id], model.state != .ready else { continue }
            probe(model, backend: backend)
        }
        ensureSystemBrightnessObservation()
    }

    /// 显示器热插拔 / 屏幕参数变化后的差量刷新：重新枚举并按 id 增删模型，
    /// 存活屏状态保留、不重复回读。幂等、可重入；与 `startIfNeeded` 并发时
    /// 两者均为全量快照，后完成者覆盖、收敛一致（后端 IO 自带串行队列）。
    func refresh() async {
        await runEnumeration()
    }

    /// 建立内建屏的系统亮度观察（幂等）：枚举结果里出现系统通道的屏时注册一次。
    /// 撤销后由 `startIfNeeded` / `runEnumeration` / `resume` 三处任一处重建，
    /// 故禁用—启用的往返不需要额外状态。
    private func ensureSystemBrightnessObservation() {
        guard changeObservation == nil, !suspended, let backend else { return }
        guard orderedIDs.contains(where: { models[$0]?.display.control == .system }) else { return }
        changeObservation = backend.observeBrightnessChanges { [weak self] displayID, brightness in
            Task { @MainActor in
                self?.applySystemBrightness(displayID: displayID, brightness: brightness)
            }
        }
    }

    /// 系统侧（亮度键 / 自动调节 / 其它 App）改了内建屏亮度：把新值回灌到滑杆。
    ///
    /// 两条抑制都必须有：本机写入**同样**触发这条通知，无脑回灌会把拖动中的
    /// 滑杆从用户手边拽回（滑杆位置与用户手指脱钩）；合并通道的尾随写入则会在
    /// 用户已松手的窗口里把滑杆拉回上一笔值。故拖动中一律丢弃，本机写入后
    /// `localWriteQuietPeriod` 内也丢弃。
    private func applySystemBrightness(displayID: CGDirectDisplayID, brightness: Double) {
        guard !suspended, let model = models[displayID], model.display.control == .system
        else { return }
        guard !model.isDragging else { return }
        if let lastWrite = lastLocalWrite[displayID],
           ContinuousClock.now - lastWrite < Self.localWriteQuietPeriod
        {
            return
        }
        model.maxLuminance = SystemBrightnessMath.fullScale
        let bounds = effectiveBounds(for: displayID, maxLuminance: model.maxLuminance)
        model.percent = Self.percent(
            value: SystemBrightnessMath.raw(fromBrightness: brightness),
            lowerBound: bounds.lower, upperBound: bounds.upper)
        cachedValues[displayID] = (model.percent, model.maxLuminance)
    }

    /// 初值回读：300ms 超时，失败回退内存缓存或 50%（部分屏不支持回读，
    /// 回读失败不代表不可调节——那是写入连续失败的判定）。
    /// 成功时按有效区间反算百分比（无自定义即全量程）。
    private func probe(_ model: BrightnessDisplayModel, backend: DisplayBrightnessBackend) {
        let display = model.display
        Task {
            do {
                let reading = try await withTimeout(.milliseconds(300)) {
                    try await backend.readLuminance(display)
                }
                model.maxLuminance = max(reading.max, 1)
                let bounds = effectiveBounds(for: display.id, maxLuminance: model.maxLuminance)
                model.percent = Self.percent(
                    value: reading.value, lowerBound: bounds.lower, upperBound: bounds.upper)
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
        // 屏已从枚举结果移除（拔出）时丢弃尾随写入：不再对消失的 transport
        // 发起无意义 IO（后端会抛 displayGone，重复失败计数也无益）。
        guard models[model.display.id] != nil else { return }
        let clamped = min(max(percent, 0), 100)
        model.percent = clamped
        let bounds = effectiveBounds(for: model.display.id, maxLuminance: model.maxLuminance)
        let value = Self.ddcValue(percent: clamped, lowerBound: bounds.lower, upperBound: bounds.upper)
        cachedValues[model.display.id] = (clamped, model.maxLuminance)
        lastLocalWrite[model.display.id] = .now
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
        // 撤销系统亮度观察：禁用期间不再接系统通知（`resume` / 下一次枚举会重建）。
        changeObservation?.invalidate()
        changeObservation = nil
        Task { await channel?.cancel() }
    }

    /// 插件重新启用后恢复写入通道；下一次块出现会按需重新枚举。
    func resume() {
        suspended = false
        // 已挂载的块不会重跑 `.task`，禁用的观察要在这里补回来（枚举仍是首次的入口）。
        ensureSystemBrightnessObservation()
        Task { await channel?.resume() }
    }

    // MARK: 值映射（纯逻辑，回归 DisplayPluginTests）

    /// 百分比 → DDC 原始值（区间版：0% 落 lower，100% 落 upper，四舍五入）。
    /// 参数名用 upperBound，避免遮蔽全局 max() 函数。
    nonisolated static func ddcValue(percent: Double, lowerBound: Int, upperBound: Int) -> Int {
        guard upperBound > lowerBound, upperBound > 0 else { return max(lowerBound, 0) }
        let lower = max(lowerBound, 0)
        let span = upperBound - lower
        return min(max(Int((percent / 100 * Double(span)).rounded()) + lower, lower), upperBound)
    }

    /// 百分比 → DDC 原始值（四舍五入、夹紧量程；量程非法按 0）。
    /// 全量程便捷版，等价于 lowerBound=0 的区间版。
    nonisolated static func ddcValue(percent: Double, upperBound: Int) -> Int {
        ddcValue(percent: percent, lowerBound: 0, upperBound: upperBound)
    }

    /// DDC 原始值 → 百分比（区间版：lower 落 0%，upper 落 100%，区间外夹紧）。
    nonisolated static func percent(value: Int, lowerBound: Int, upperBound: Int) -> Double {
        guard upperBound > lowerBound, upperBound > 0 else { return 0 }
        let lower = max(lowerBound, 0)
        let span = upperBound - lower
        guard span > 0 else { return 0 }
        return min(max(Double(value - lower) / Double(span) * 100, 0), 100)
    }

    /// DDC 原始值 → 百分比（全量程便捷版）。
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
