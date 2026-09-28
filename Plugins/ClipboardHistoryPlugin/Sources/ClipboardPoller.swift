import Foundation

// MARK: - 剪贴板轮询引擎（专用后台队列；本文件不 import AppKit、只经 ClipboardReading 抽象）
//
// 为什么不是一个挂主 RunLoop 的 Timer：主线程一卡（SwiftUI 渲染、抽屉动画），
// Timer 的"发现变化"就被推迟，macOS 还会把它与别的定时器合并（timer coalescing）；
// 而"发现变化"到"读取内容"之间只要经过主线程，窗口里用户再复制一次，剪贴板已被
// 覆盖、前一次物理上不可恢复。于是整条采集路径都搬到**专用串行队列**：
// 「探测 changeCount → 门控 → 读载荷」全程不碰主线程，只有结论回主线程落库。
//
// 没有公开的事件驱动 API 可用（macOS 的 pboard 是 pull-only broker），轮询是唯一
// 正解，问题只在把它做稳：固定 0.5s（changeCount 单次约 10µs Mach IPC，可忽略）、
// 常驻（随插件启用/禁用起停，与放置实例、抽屉可见性无关）、严格有序（串行队列）。

/// 轮询队列与主线程之间的共享状态（NSLock 保护的小盒子）。
///
/// 放进锁盒而不是两边各持一份：`lastSeen` / `writeBack` / `paused` 两边都要读写，
/// 分成两份必然漂移。`writing` 是"主线程正在写回剪贴板"的互斥标记：写回期间跳过一拍，
/// 避免把宿主自己的写回当成一次外部复制记下来。
final class ClipboardPollState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSeen: Int?
    private var writeBack: Int?
    private var paused = false
    private var writing = false
    private var running = false

    var isRunning: Bool { lock.withLock { running } }
    /// 最近一次见到的计数；`applyCurrentEntryMatch` 用它判断异步读载荷期间剪贴板是否已变。
    var latestChangeCount: Int? { lock.withLock { lastSeen } }

    func setRunning(_ value: Bool) { lock.withLock { running = value } }
    func setPaused(_ value: Bool) { lock.withLock { paused = value } }

    /// 主线程自写回前的互斥标记；`cancelWrite` 用于写回失败时解锁。
    func beginWrite() { lock.withLock { writing = true } }
    func cancelWrite() { lock.withLock { writing = false } }

    /// 写回完成：置写回快照 + 前移计数，并解锁。轮询下一拍会凭 `writeBack` 认出
    /// 这次变化是自循环、只认领不记录。
    func finishWrite(_ changeCount: Int) {
        lock.withLock {
            writeBack = changeCount
            lastSeen = changeCount
            writing = false
        }
    }

    /// 重新认领当前计数（启动 / 恢复记录）：不补记此前的任何变化。
    func reseed(using reader: any ClipboardReading) {
        lock.withLock {
            lastSeen = reader.probe().changeCount
            writeBack = nil
            writing = false
        }
    }

    /// 原子一拍：锁内探测 + 判定 + 前移计数。
    ///
    /// 探测必须在锁内——否则与主线程的 `finishWrite` 交错时，会拿旧的 `lastSeen` 把
    /// 宿主刚写回的内容判成一次外部复制。
    func decide(using reader: any ClipboardReading) -> ClipboardPollDecision {
        lock.withLock {
            guard !writing else { return .unchanged }
            let probe = reader.probe()
            let decision = ClipboardHistoryLogic.pollDecision(
                changeCount: probe.changeCount,
                typeNames: probe.typeNames,
                lastSeen: lastSeen,
                writeBack: writeBack,
                isPaused: paused
            )
            lastSeen = probe.changeCount
            if case .selfLoop = decision { writeBack = nil }
            return decision
        }
    }
}

/// 采集器：在专用串行队列上跑「探测 → 门控 → 读载荷」，把结论交回主线程。
final class ClipboardPoller: @unchecked Sendable {
    /// 一拍结论。
    enum Outcome: Equatable {
        case unchanged
        case selfLoop
        case clearHighlight
        case captured(ClipboardPayload)
    }

    /// 固定节拍。0.5s 是"甜点档"（0.3s 为实用下限）：远快于人手连续复制的间隔，
    /// 又不至于为人类工作流做无谓的亚秒探测。
    static let interval: TimeInterval = 0.5
    /// 允许系统合并唤醒的松弛量（省电）；抖动量级远小于人手动复制的间隔。
    static let leeway: TimeInterval = 0.1

    private let reader: any ClipboardReading
    private let state: ClipboardPollState
    private let queue = DispatchQueue(label: "com.notchcenter.clipboard.poll", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// 采集结论回主线程的唯一出口（在主线程被调用）。
    var onOutcome: (@MainActor @Sendable (Outcome) -> Void)?

    init(reader: any ClipboardReading, state: ClipboardPollState) {
        self.reader = reader
        self.state = state
    }

    var isRunning: Bool { state.isRunning }

    /// 起表（插件启用时调用）。`running` 同步翻转，好让调用方在返回后立刻断言；
    /// 计时器本身在专用队列上创建。
    func start() {
        guard !state.isRunning else { return }
        state.setRunning(true)
        queue.async { [weak self] in
            guard let self, self.state.isRunning else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + Self.interval,
                repeating: Self.interval,
                leeway: .milliseconds(Int(Self.leeway * 1000))
            )
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// 停表（插件禁用时调用）。
    func stop() {
        guard state.isRunning else { return }
        state.setRunning(false)
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// 写回剪贴板后调用：请轮询把这次变化认作自循环。
    func acknowledgeWriteBack(_ changeCount: Int) {
        state.finishWrite(changeCount)
    }

    /// 重新认领当前计数（启动 / 恢复记录）。
    func reseed() {
        state.reseed(using: reader)
    }

    /// 同步跑一拍并返回结论（internal 供测试直注；生产由计时器在专用队列上驱动，
    /// 见 `tick()`）。
    func pollOnce() -> Outcome {
        switch state.decide(using: reader) {
        case .unchanged:
            return .unchanged
        case .selfLoop:
            return .selfLoop
        case .clearHighlight:
            return .clearHighlight
        case .capture(let changeCount):
            let payload = reader.readPayload()
            // 读取期间剪贴板又变了：丢弃这次，交给下一拍收新内容，避免把新内容贴旧计数。
            guard reader.probe().changeCount == changeCount else { return .unchanged }
            return .captured(payload)
        }
    }

    private func tick() {
        guard state.isRunning else { return }
        let outcome = pollOnce()
        switch outcome {
        case .unchanged, .selfLoop:
            return
        case .clearHighlight, .captured:
            guard let handler = onOutcome else { return }
            Task { @MainActor in handler(outcome) }
        }
    }
}
