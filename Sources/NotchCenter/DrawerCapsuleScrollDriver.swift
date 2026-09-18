import Foundation
import QuartzCore

// MARK: - 胶囊行边缘自动滚驱动器

/// 拖动会话期的胶囊行**边缘自动滚**：指针进滚动区两侧边带就按速率滚行，
/// 压入越深越快，离开边带或松手即停。
///
/// 为什么必须是计时器：边缘驻留 = 指针静止，此时没有任何鼠标事件流入，
/// 逐事件推进行（与 `CapsuleDwellTimer` 同一真机教训）。tick 必须挂主
/// RunLoop `.common` 模式——拖动/触控板手势期间主线程在 event tracking
/// mode，默认模式的 Timer 不点火（`DrawerSwipeSpringDriver` 踩过同一条）。
///
/// 驱动器**不自持偏移**：渲染真源是 `PanelUIState.drawerCapsuleScrollOffset`，
/// 每帧经 `Environment` 现取现写（与自驱弹簧"状态值 ≡ 屏幕表现值"同一取向，
/// 但这里没有插值数学，只有步进 + 夹紧）。偏移与几何都不冻结：拖动期滑动
/// 会话与拖拽互斥，面板宽度不插值，逐帧现取恒等于屏幕上的值。
///
/// 时钟与调度可注入：生产用 `CACurrentMediaTime` + 主 RunLoop，单测注入假
/// 时钟后手动 `tick()` 逐帧重放（与 `DrawerSwipeSpringDriver` 同一风格）。
@MainActor
final class DrawerCapsuleScrollDriver {

    /// 装订 tick 的调度器，返回取消闭包。
    typealias Scheduler = (@escaping @MainActor () -> Void) -> () -> Void

    /// 一帧的环境：指针位置（屏幕坐标）、滚动区几何与偏移读写口。
    struct Environment {
        /// 指针屏幕 x。
        var pointerX: CGFloat
        /// 滚动区左缘屏幕 x（与 `pointerX` 同坐标系）。
        var regionLeft: CGFloat
        var regionWidth: CGFloat
        var pageCount: Int
        /// 当前偏移（渲染真源）。
        var offset: () -> CGFloat
        /// 写入新偏移（已夹紧）。
        var apply: (CGFloat) -> Void
    }

    /// 单帧时长上限：迟到的 tick 不跳步（慢一帧只滚一帧的量）。
    private static let maxStep: TimeInterval = 1.0 / 30

    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private var environment: Environment?
    private var lastTick: TimeInterval = 0
    private var cancelTicks: (() -> Void)?

    var isRunning: Bool { cancelTicks != nil }

    init(
        now: @escaping () -> TimeInterval = CACurrentMediaTime,
        schedule: @escaping Scheduler = DrawerCapsuleScrollDriver.mainRunLoopScheduler
    ) {
        self.now = now
        self.schedule = schedule
    }

    /// 指针上报（同坐标系）：边带内起表、边带外停表；已在表上只刷新几何。
    /// 传 nil = 拖动结束，直接停表。
    func update(_ environment: Environment?) {
        guard let environment,
              DrawerPagePillLayout.autoScrollVelocity(
                  pointerX: environment.pointerX,
                  regionLeft: environment.regionLeft,
                  regionWidth: environment.regionWidth
              ) != 0 else {
            stop()
            return
        }
        self.environment = environment
        guard cancelTicks == nil else { return }
        lastTick = now()
        cancelTicks = schedule { [weak self] in self?.tick() }
    }

    func stop() {
        environment = nil
        cancelTicks?()
        cancelTicks = nil
    }

    /// 单帧推进（Timer 与测试共用）。顶到端点即停表：指针不动时留一枚
    /// 空转计时器没有意义，指针再动会经 `update` 重起。
    func tick() {
        guard let environment else {
            stop()
            return
        }
        let velocity = DrawerPagePillLayout.autoScrollVelocity(
            pointerX: environment.pointerX,
            regionLeft: environment.regionLeft,
            regionWidth: environment.regionWidth
        )
        guard velocity != 0 else {
            stop()
            return
        }
        let t = now()
        let dt = min(max(t - lastTick, 0), Self.maxStep)
        lastTick = t
        let current = environment.offset()
        let extent = DrawerPagePillLayout.scrollExtent(
            regionWidth: environment.regionWidth,
            pageCount: environment.pageCount
        )
        guard (velocity > 0 && current < extent) || (velocity < 0 && current > -extent) else {
            stop()
            return
        }
        let next = DrawerPagePillLayout.clampedOffset(
            current + velocity * CGFloat(dt),
            regionWidth: environment.regionWidth,
            pageCount: environment.pageCount
        )
        guard next != current else { return }
        environment.apply(next)
    }

    /// 生产调度：120Hz 重复 Timer 挂主 RunLoop `.common` 模式（默认模式在
    /// event tracking mode 下不点火，见类注释）。
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
