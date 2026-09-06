import Foundation
import QuartzCore

// MARK: - 滑动切页自驱弹簧驱动器

/// 落位/回弹弹簧的**自驱**驱动器：解析解阻尼弹簧逐帧把表现值写进会话状态，
/// 收敛拍由自己的数学触发——绝不依赖 `withAnimation(completion:)`（触控板
/// 通路经 `NSPanel.sendEvent` 进入时 completion 实测不保证触发，会被无限
/// 推迟，兜底时钟方案正是为它而生；本驱动器让那一整套机制失去存在必要）。
///
/// 自驱的核心收益是**状态值 ≡ 屏幕表现值**：动画进行中任何一帧都能读到带
/// 当前真实位置，新手势接管（grab）只需取消驱动器、以当前状态值为种子续接
/// ——零瞬移、零估算。若用 SwiftUI spring，表现值藏在渲染树里读不到，接管
/// 只能靠复刻弹簧数学估算，误差直接变成可见跳变。
///
/// 弹簧参数与 `DrawerAnimation.spring`（response 0.3 / dampingFraction 0.86）
/// 同源映射：`ω_n = 2π / response`、`ζ = dampingFraction`（CASpring 标准映
/// 射，单位质量）。解析解逐帧求值，Timer 抖动不积累误差——迟到的 tick 算
/// 出的仍是该时刻的精确表现值。
///
/// 时钟与调度都可注入：生产用 `CACurrentMediaTime` + 主 RunLoop（`.common`
/// 模式——触控板手势期间主线程在 event tracking mode，默认模式 Timer 不点
/// 火），单测注入假时钟后手动 `tick()` 逐帧重放，与 `DrawerPageScrollTracker`
/// 注入 `NSEvent.timestamp` 同一风格。
@MainActor
final class DrawerSwipeSpringDriver {

    /// 装订 tick 的调度器，返回取消闭包（停止/收敛/接管时调用）。
    typealias Scheduler = (@escaping @MainActor () -> Void) -> () -> Void

    /// 收敛判据：位移进入半像素内且速度低于可感阈值。到点后**精确贴到目标**
    /// 再触发收敛拍——落位像素重合交接要求 offset 精确等于 arrivalOffset。
    private static let settlePositionEpsilon: Double = 0.5
    private static let settleVelocityEpsilon: Double = 8
    /// 安全上限：解析解不会发散，上限只防极端初值下的长尾。
    private static let maxDuration: TimeInterval = 1.2

    private let omegaN: Double
    private let zeta: Double
    private let now: () -> TimeInterval
    private let schedule: Scheduler

    private var startTime: TimeInterval = 0
    private var x0: Double = 0
    private var v0: Double = 0
    private var target: Double = 0
    private var token: UUID?
    private var onFrame: ((CGFloat) -> Void)?
    private var onSettle: (() -> Void)?
    private var cancelTicks: (() -> Void)?

    var isRunning: Bool { token != nil }

    init(
        response: Double = 0.3,
        dampingFraction: Double = 0.86,
        now: @escaping () -> TimeInterval = CACurrentMediaTime,
        schedule: @escaping Scheduler = DrawerSwipeSpringDriver.mainRunLoopScheduler
    ) {
        precondition(dampingFraction > 0 && dampingFraction < 1, "欠阻尼假设（解析解按 ζ<1 推导）")
        omegaN = 2 * .pi / response
        zeta = dampingFraction
        self.now = now
        self.schedule = schedule
    }

    /// 从 `from`（带初速 `velocity`）弹向 `to`。`token` 是会话身份：会话被
    /// 换绑/清场后 tick 空跑（帧回调与收敛拍都不会送达过期身份）。
    func run(
        from: CGFloat,
        velocity: CGFloat = 0,
        to: CGFloat,
        token: UUID,
        onFrame: @escaping (CGFloat) -> Void,
        onSettle: @escaping () -> Void
    ) {
        stopTicks()
        x0 = Double(from)
        v0 = Double(velocity)
        target = Double(to)
        self.token = token
        self.onFrame = onFrame
        self.onSettle = onSettle
        startTime = now()
        cancelTicks = schedule { [weak self] in self?.tick() }
    }

    /// 接管/清场：停在当前状态。自驱弹簧每帧都把表现值写进状态，取消后
    /// 状态值就是屏幕上的真实位置——接管零瞬移的根据。
    func cancel() {
        stopTicks()
    }

    /// 单帧推进（Timer 与测试共用）：按当前时钟求表现值，收敛则贴到目标并
    /// 触发收敛拍。内部使用，`@testable` 可手动驱动。
    func tick() {
        guard token != nil else { return }
        let t = now() - startTime
        let (x, v) = Self.sample(
            x0: x0, v0: v0, target: target, omegaN: omegaN, zeta: zeta, at: t
        )
        let converged = abs(x - target) < Self.settlePositionEpsilon
            && abs(v) < Self.settleVelocityEpsilon
        if converged || t >= Self.maxDuration {
            let frame = onFrame
            let settle = onSettle
            stopTicks()
            frame?(CGFloat(target))
            settle?()
        } else {
            onFrame?(CGFloat(x))
        }
    }

    private func stopTicks() {
        token = nil
        onFrame = nil
        onSettle = nil
        cancelTicks?()
        cancelTicks = nil
    }

    /// 阻尼弹簧解析解（欠阻尼，ζ < 1，单位质量）：
    /// `x(t) = target + e^(-ζω_n t) (A cos ω_d t + B sin ω_d t)`，
    /// `A = x0 - target`、`B = (v0 + ζω_n A) / ω_d`；速度为其导数
    ///（衰减因子只作用于整体，不得重复乘入首项——那是初版写错的坑）。
    static func sample(
        x0: Double,
        v0: Double,
        target: Double,
        omegaN: Double,
        zeta: Double,
        at t: Double
    ) -> (x: Double, v: Double) {
        let zetaOmega = zeta * omegaN
        let omegaD = omegaN * (1 - zeta * zeta).squareRoot()
        let a = x0 - target
        let b = (v0 + zetaOmega * a) / omegaD
        let decay = Foundation.exp(-zetaOmega * t)
        let phase = omegaD * t
        let cos = Foundation.cos(phase)
        let sin = Foundation.sin(phase)
        let amplitude = a * cos + b * sin
        let x = target + decay * amplitude
        let v = decay * (-zetaOmega * amplitude - a * omegaD * sin + b * omegaD * cos)
        return (x, v)
    }

    /// 生产调度：120Hz 重复 Timer 挂主 RunLoop `.common` 模式。触控板手势
    /// 期间主线程在 event tracking mode，默认模式不点火（ `.common` 是唯一
    /// 保证）。Timer 回调跑在主线程，`assumeIsolated` 只是把它告诉编译器。
    private nonisolated static func mainRunLoopScheduler(
        _ tick: @escaping @MainActor () -> Void
    ) -> () -> Void {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick()
            }
        }
        timer.tolerance = 1.0 / 240
        RunLoop.main.add(timer, forMode: .common)
        return { [timer] in timer.invalidate() }
    }
}
