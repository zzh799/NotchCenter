import Foundation
import QuartzCore
import os

/// 上盖开合状态。
///
/// 这是本库相对上游 `LidAngleKit` 的**新增能力**:上游只有裸读数,合盖语义散落在
/// `LidController` 的速度阈值里。这里把它下沉成库的一部分,使任何插件都能直接问
/// "盖子是合上的吗",而不用自己实现一套阈值/去抖。
public enum LidState: String, Sendable, CaseIterable {
    /// 上盖完全合拢(角度已到闭合阈值以下)。
    case closed
    /// 正在合上(角度在闭合阈值以上,但正以足够速度下降)。
    case closing
    /// 正常打开。
    case open

    /// 用户视角下"盖子算是合上了":包含正在合拢的过程,便于 UI 提前响应。
    public var isShutting: Bool { self != .open }
}

/// 一份盖角采样 + 由它推出的状态。
public struct LidReading: Sendable, Equatable {
    /// 当前盖角(度)。读取失败时为 `nil`,此时状态沿用上一次判定。
    public var angle: Double?
    public var state: LidState
    /// 盖角变化速度(度/秒),负值表示正在合上。
    public var velocity: Double
    /// 本次判定是否来自真实传感器读数(否则为预测/沿用值)。
    public var isFresh: Bool

    public init(angle: Double?, state: LidState, velocity: Double, isFresh: Bool) {
        self.angle = angle
        self.state = state
        self.velocity = velocity
        self.isFresh = isFresh
    }
}

/// 合盖判定的阈值。默认值与 Mac-Duo 的 `Preferences` 工厂值一致,保持观感一致。
public struct LidThresholds: Sendable, Equatable {
    /// 低于此角度视为完全合上(度)。
    public var closedAngle: Double
    /// 角速度低于此值(更负)视为"正在合上"(度/秒)。静止的盖子读数在 0.5 以内。
    public var closingSpeed: Double

    public init(closedAngle: Double = 3, closingSpeed: Double = 12) {
        self.closedAngle = closedAngle
        self.closingSpeed = closingSpeed
    }
}

/// 周期性轮询 `LidAngleSensor`,把裸读数变成带状态的 `LidReading` 流。
///
/// 线程约定:实例**不绑定主线程**,可在任意线程创建与调用;`onReading` 在
/// `start(on:)` 指定的队列上回调(默认主队列)。传感器读取是同步阻塞的,所以
/// 默认节拍刻意宽松——只有需要跟随合盖动画时才由使用方调高到 `activeInterval`。
public final class LidAngleMonitor: @unchecked Sendable {

    /// 空闲节拍:每秒 8 次。足够响应"盖子开始动了",又不至于白烧 CPU。
    public static let idleInterval: TimeInterval = 1.0 / 8
    /// 活动节拍:每秒 30 次。跟随合盖动画时使用。
    public static let activeInterval: TimeInterval = 1.0 / 30

    /// 读数回调。在主队列(或 `start(on:)` 指定队列)上调用。
    public var onReading: (@Sendable (LidReading) -> Void)?

    private let sensor: LidAngleSensor
    private let thresholds: LidThresholds
    private let log = Logger(subsystem: "com.notchcenter.app", category: "lidangle")

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var queue: DispatchQueue = .main
    private var interval: TimeInterval = LidAngleMonitor.idleInterval

    private var lastAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0
    private var state: LidState = .open
    private var velocity: Double = 0
    private var consecutiveFailures = 0

    /// 传感器是否可用(设备未找到时为 false,此时 `start` 不会产生读数)。
    public var isAvailable: Bool { sensor.isAvailable }

    /// 传感器使用的档位,用于设置页展示诊断。
    public var resolution: LidAngleSensor.Resolution? { sensor.resolution }

    public init(thresholds: LidThresholds = LidThresholds()) {
        self.thresholds = thresholds
        self.sensor = LidAngleSensor()
    }

    deinit {
        timer?.cancel()
    }

    /// 开始轮询。已在运行时只切换节拍,不重复建定时器。
    /// - Parameters:
    ///   - queue: 回调队列,默认主队列。
    ///   - interval: 节拍,默认 `idleInterval`。
    ///
    /// **注意**:定时器是 `DispatchSourceTimer`,派发到 `queue` 上执行。传主队列时
    /// **主线程的 run loop 必须在转**(普通 App 恒成立),否则事件永远不被派发、
    /// 读数一次都不来——这不会报错,只会安静地什么都不发生。在批处理/阻塞主线程的
    /// 场景(例如 XCTest 的 `wait(for:)`)请显式传自己的队列。
    public func start(on queue: DispatchQueue = .main, interval: TimeInterval = LidAngleMonitor.idleInterval) {
        lock.lock()
        self.queue = queue
        lock.unlock()
        // setInterval 自己取锁:NSLock 不可重入,在持锁时调它会自死锁。
        setInterval(interval)
    }

    /// 停止轮询并取消定时器。
    public func stop() {
        lock.lock()
        let existing = timer
        timer = nil
        lock.unlock()
        existing?.cancel()
    }

    /// 调整节拍。定时器是 `DispatchSourceTimer`,改节拍无需重建。
    public func setInterval(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard self.interval != interval || timer == nil else { return }
        self.interval = interval

        if let timer {
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    /// 用一次真实读数重建基线。系统唤醒后必须调用:否则"几乎合着醒过来"会被
    /// 误判成正在合盖。
    public func resetBaseline() {
        lock.lock()
        lastAngle = nil
        velocity = 0
        consecutiveFailures = 0
        lock.unlock()
        _ = sample(isResetting: true)
    }

    /// 采样一次并按阈值推出状态。可在任意线程调用(传感器内部有锁)。
    @discardableResult
    public func sampleNow() -> LidReading {
        sample(isResetting: false)
    }

    private func poll() {
        let reading = sample(isResetting: false)
        onReading?(reading)
    }

    private func sample(isResetting: Bool) -> LidReading {
        let now = CACurrentMediaTime()
        let fresh = sensor.angle()

        lock.lock()
        defer { lock.unlock() }

        guard let fresh else {
            consecutiveFailures += 1
            // 连续失败超过 1 秒(约 8 次空闲采样)才降级为 open,避免单次抖动
            // 造成状态跳变;此时 isFresh=false,使用方可据此不更新重活。
            if consecutiveFailures > 8, state != .open {
                log.notice("sensor read failed \(self.consecutiveFailures) times, resetting state to open")
                state = .open
                velocity = 0
            }
            return LidReading(angle: lastAngle, state: state, velocity: velocity, isFresh: false)
        }
        consecutiveFailures = 0

        if isResetting {
            lastAngle = fresh
            lastChangeTime = now
            velocity = 0
            state = fresh <= thresholds.closedAngle ? .closed : .open
            return LidReading(angle: fresh, state: state, velocity: 0, isFresh: true)
        }

        if let previous = lastAngle, previous != fresh {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (fresh - previous) / dt
                // 传感器是 ~10 Hz 的阶梯信号,一阶低通后速度才可用。
                velocity = 0.5 * instant + 0.5 * velocity
            }
            lastAngle = fresh
            lastChangeTime = now
        } else if lastAngle == nil {
            lastAngle = fresh
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            // 读数停更 0.4 s 以上,视为静止:否则一个陈旧的负速度会让
            // "closing" 永远挂在那里。
            velocity = 0
        }

        if fresh <= thresholds.closedAngle {
            state = .closed
        } else if velocity <= -thresholds.closingSpeed {
            state = .closing
        } else {
            state = .open
        }

        return LidReading(angle: fresh, state: state, velocity: velocity, isFresh: true)
    }
}
