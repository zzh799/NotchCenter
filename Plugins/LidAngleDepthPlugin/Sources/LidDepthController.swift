import AppKit
import Combine
import LidAngleKit
import QuartzCore

/// 内置屏的身份。`NSApplication` 在背光变化时也会发屏幕变化通知,靠这个把两者分开。
struct LidScreenLayout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?
}

/// 观察盖角并驱动透视效果覆盖窗。
///
/// 上游 Mac-Duo 的 `LidController`,原样移植。
///
/// **与上游的差异**:
/// - 盖角轮询改用共享库 `LidAngleKit` 的 `LidAngleMonitor`(上游把轮询写在本类里),
///   合盖/开合状态因此也能被其它插件复用。
/// - 所有可调参数来自 `LidDepthPreferences`(`StateStore` 落盘),不再直写 `UserDefaults`。
@MainActor
final class LidDepthController: ObservableObject {

    /// 当前盖角(度)。
    @Published private(set) var currentAngle: Double = 0
    /// 传感器是否可用。不支持的机型这个值为 false,UI 走"本机不支持"降级态。
    @Published private(set) var isSensorAvailable = false
    /// 效果是否正在屏上。
    @Published private(set) var isActive = false
    /// 当前合盖状态(来自共享库)。
    @Published private(set) var lidState: LidState = .open
    /// 实时流是否真的起来了。拿不到屏幕录制权限时为 false,走静帧降级档。
    @Published private(set) var isStreaming = false

    /// 屏幕录制权限是否已授予。
    ///
    /// 两档画面(实时流与单帧抓拍)同源同权限:这个值为 false 时效果拿不到任何
    /// 屏幕内容,控制台块/设置页据此给出「权限」引导按钮(走宿主的权限弹窗)。
    var hasScreenCapturePermission: Bool { snapshotter.hasPermission }

    let snapshotter = ScreenSnapshotter()

    private let preferences: LidDepthPreferences
    private let monitor = LidAngleMonitor()
    private let overlay = DepthOverlay()
    private let streamer = ScreenStreamer()

    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPublishTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    /// 度/秒,合盖时为负。
    private var angularVelocity: Double = 0
    private var lastClosingTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var lastMovedDownTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var visualAngle = CriticallyDampedSpring()
    private var startedAt: CFTimeInterval = 0
    private var preview: PreviewRun?
    private var isSuspended = false
    private var isCapturePending = false
    private var builtInLayout = LidScreenLayout()
    private var isRunning = false

    /// 系统事件观察者 token。block 版 `addObserver` 只返回 token，必须自己摘除。
    private var systemObservers: [NSObjectProtocol] = []
    /// `preferences.isEnabled` 订阅：驱动采样门控。
    private var enabledCancellable: AnyCancellable?
    /// 采样定时器所在队列。传感器读取是同步阻塞的 `IOHIDDeviceGetReport`，
    /// 库注释明确要求别放主线程高频路径（活动档 30Hz）。
    private let sensorQueue = DispatchQueue(
        label: "com.notchcenter.lidangle.sensor",
        qos: .userInitiated
    )

    private static let fadeInDuration: TimeInterval = 0.07
    /// 高于预热区多少度时轮询提速。
    private static let fastPollMargin: Double = 20

    /// 算得上"有意合盖"的合盖速度,度/秒。静止的盖子读数在 0.5 以内。
    private static let triggerClosingSpeed: Double = 2

    /// 盖子最后一次向下移动之后,多久内仍允许启动效果。
    private static let closingMemory: TimeInterval = 1.5

    private static let predictionSpeedFloor: Double = 40

    /// 预测在读数自身年龄之外再补的传感器延迟。
    private static let predictionLatency: TimeInterval = 0.04

    /// 覆盖窗至少存在这么久。预测可能在最后一次读数还在释放角之上时就触发。
    private static let minimumEffectDuration: TimeInterval = 0.35

    /// 预热区:阈值角往上这段范围内开始抓帧。
    var prewarmCeiling: Double { 35 }
    /// 最后一次合盖后继续抓帧多久。
    var prewarmLinger: TimeInterval { 1.0 }
    /// 预热抓帧间隔。
    var prewarmInterval: TimeInterval { 0.2 }
    /// 算得上"明显在合"的速度阈值,用于决定还要不要继续抓帧预热。
    /// 比 `triggerClosingSpeed` 严得多:预热是有成本的,不能因为手抖就开。
    var prewarmClosingSpeed: Double { 12 }

    /// 一段脚本化的角度扫描,让设置面板在盖子不动时也能演示效果。
    /// 它喂进的是与真实传感器**同一条**路径。
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        let closing: CFTimeInterval = 1.4
        let hold: CFTimeInterval = 0.8
        let opening: CFTimeInterval = 0.6

        /// 运行结束后返回 nil。
        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
            if elapsed < closing + hold { return shut }
            if elapsed < closing + hold + opening {
                return shut + (open - shut) * ((elapsed - closing - hold) / opening)
            }
            return nil
        }
    }

    init(preferences: LidDepthPreferences) {
        self.preferences = preferences
    }

    // MARK: - 生命周期

    /// 开始观察。传感器不可用时直接返回,`isSensorAvailable` 保持 false。
    func start() {
        guard !isRunning else { return }
        isRunning = true

        isSensorAvailable = monitor.isAvailable
        guard isSensorAvailable else {
            LidDepthLog.lid.notice("lid angle sensor unavailable on this machine")
            return
        }

        let reading = monitor.sampleNow()
        if let angle = reading.angle {
            rawAngle = angle
            currentAngle = angle
            visualAngle.reset(to: angle)
        }
        lidState = reading.state

        monitor.onReading = { [weak self] reading in
            // 采样在 sensorQueue 上完成，回主线程再驱动 UI/覆盖窗。
            Task { @MainActor in self?.handle(reading) }
        }

        builtInLayout = LidScreenLayout(displayID: NSScreen.builtIn?.displayID, frame: NSScreen.builtIn?.frame)
        observeSystemEvents()
        observeEnabledChanges()
        overlay.warmUp()
        // 采样门控：默认关总开关时不起表（旧实现无条件 8Hz 常驻轮询）。
        updatePollingState()
        // 抓帧预热只在已授权时做:预热会枚举窗口(`SCShareableContent`),未授权时
        // 那次调用本身就是系统授权窗的触发点,装载期预热等于每次开机弹一次。
        // 授权后需重启 App 生效,重启即预热,手感不受影响。
        guard hasScreenCapturePermission else { return }
        Task {
            await snapshotter.warmFilter()
            // 等覆盖窗先把自己的存在窗口挂上去,filter 才能点名本应用、
            // 把覆盖窗排除在画面之外。
            try? await Task.sleep(nanoseconds: 500_000_000)
            await streamer.warmFilter()
        }
    }

    /// 停止观察并收掉一切。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.onReading = nil
        monitor.stop()
        stopDisplayLink()
        overlay.shutdown()
        snapshotter.endPrewarm()
        snapshotter.discard()
        streamer.stop()
        streamer.invalidateFilter()
        isActive = false
        isStreaming = false
        preview = nil
        isCapturePending = false
        enabledCancellable = nil
        // block 版 addObserver 只能凭 token 摘除。旧实现调 `removeObserver(self)`
        // （只对 selector 版生效）而 token 又没存 → 停用后唤醒仍会 resume 并重建
        // 定时器，反复启停叠加观察者。两个 center 各摘一次，摘错的是无操作。
        for observer in systemObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        systemObservers.removeAll()
    }

    /// 在当前屏幕内容上把效果演一遍。
    func runPreview() {
        guard preview == nil, !isActive, isSensorAvailable else { return }
        // 远高于触发角,让这次扫描走出与真实合盖一样的预热路径。
        preview = PreviewRun(
            startedAt: CACurrentMediaTime(),
            open: min(preferences.thresholdAngle + 35, 130),
            shut: max(preferences.thresholdAngle - preferences.blurSpan * 1.15, 5)
        )
        updatePollingState()
    }

    /// 效果是否正在播放(供快捷按钮/摘要展示)。
    var isPlayingEffect: Bool { isActive }

    // MARK: - 采样

    private func handle(_ reading: LidReading) {
        guard !isSuspended else { return }

        let angle: Double
        if let run = preview {
            guard let scripted = run.angle(at: CACurrentMediaTime()) else {
                preview = nil
                updatePollingState()
                return
            }
            angle = scripted
        } else {
            guard let read = reading.angle else { return }
            angle = read
        }

        rawAngle = angle
        lidState = reading.state
        updateVelocity(with: angle)
        publish(angle: angle)
        reconcile(angle: angle)
        updatePollingState()
    }

    /// 采样表唯一的门控点：只在「插件在跑、传感器可用、未睡眠、且（效果已开启 或
    /// 正在预览 或 效果在屏）」时轮询；按触发角远近切换空闲/活动档。
    ///
    /// 刻意**不**按 `\.isDrawerPresented` 门控：本插件的效果场景恰恰是"抽屉收起、
    /// 用户合盖"，按抽屉收起停表会直接废掉核心功能（与 Dsh/Calibre 的服务探测不同源）。
    private func updatePollingState() {
        guard isRunning, isSensorAvailable else { return }
        let shouldPoll = !isSuspended
            && (preferences.isEnabled || preview != nil || isActive)
        guard shouldPoll else {
            monitor.stop()
            return
        }
        let prewarmZone = preferences.thresholdAngle + prewarmCeiling
        let wantsFastPolling = preview != nil || isActive || rawAngle <= prewarmZone + Self.fastPollMargin
        monitor.start(
            on: sensorQueue,
            interval: wantsFastPolling ? LidAngleMonitor.activeInterval : LidAngleMonitor.idleInterval
        )
    }

    /// 这一次角度下,画面该不该在屏上。释放角被放宽,并让停在小角度上的盖子继续显示。
    private func wantsEffect(angle: Double) -> Bool {
        guard preferences.isEnabled else { return false }
        let threshold = preferences.thresholdAngle
        if isActive {
            // 效果刚起来的这一小段时间不允许被释放,否则预测会在读数还没跟上时把它关掉。
            guard CACurrentMediaTime() - startedAt > Self.minimumEffectDuration else { return true }
            return angle < threshold + hysteresis
        }
        // 停在角度以下的盖子不能自己启动效果——必须看到"正在合"这个动作。
        let closing = CACurrentMediaTime() - lastMovedDownTime < Self.closingMemory
        return closing && predictedAngle() <= threshold
    }

    /// 释放的迟滞带宽(度)。避免停在阈值上时反复开关。
    private var hysteresis: Double { 8 }

    /// 每次采样都把屏幕拉到与 `wantsEffect` 一致。截图失败的那一次运行在这里重试。
    private func reconcile(angle: Double) {
        // 缺屏幕录制权限时没有画面可画(实时流与单帧同源同权限):效果整体不启动,
        // 免得反复重试抓帧、留一扇永远透明的覆盖窗。盖角读数与其它功能不受影响。
        let wanted = hasScreenCapturePermission && wantsEffect(angle: angle)
        if wanted != isActive {
            LidDepthLog.lid.notice(
                """
                \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
                predicted \(self.predictedAngle(), format: .fixed(precision: 2)) \
                velocity \(self.angularVelocity, format: .fixed(precision: 1)) deg/s \
                snapshot \(self.snapshotter.latestImage != nil)
                """
            )
            setActive(wanted)
            return
        }
        if isActive {
            if !overlay.isVisible, !isCapturePending { presentPicture() }
            // 一个可见却没有 display link 的覆盖窗会停在第一帧上。
            if overlay.isVisible, displayLink == nil { startDisplayLink() }
        } else {
            updatePrewarm(angle: angle, ceiling: preferences.thresholdAngle + prewarmCeiling)
        }
    }

    private func updateVelocity(with angle: Double) {
        let now = CACurrentMediaTime()
        guard let last = lastAngle else {
            lastAngle = angle
            lastChangeTime = now
            return
        }
        if angle != last {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                angularVelocity = 0.5 * instant + 0.5 * angularVelocity
            }
            lastAngle = angle
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            angularVelocity = 0
        }
        if angularVelocity <= -Self.triggerClosingSpeed {
            lastMovedDownTime = now
        }
        if angularVelocity <= -prewarmClosingSpeed {
            lastClosingTime = now
        }
    }

    private var lastAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0

    /// 只在盖子正在合的时候运行,所以停住不动不会留下一个抓帧循环在跑。
    private func updatePrewarm(angle: Double, ceiling: Double) {
        let closingRecently = CACurrentMediaTime() - lastClosingTime < prewarmLinger
        guard angle <= ceiling, closingRecently else {
            snapshotter.endPrewarm()
            streamer.stop()
            updateStreamingState()
            overlay.discardLive()
            return
        }
        guard preferences.isLivePicture else {
            streamer.stop()
            updateStreamingState()
            overlay.discardLive()
            snapshotter.beginPrewarm(interval: prewarmInterval)
            return
        }
        // 只起流。同一时间去问 ScreenCaptureKit 要截图,会让它两边都伺候不好。
        snapshotter.endPrewarm()
        streamer.start()
        updateStreamingState()
    }

    private func updateStreamingState() {
        let started = streamer.isStarted && streamer.screen != nil
        if isStreaming != started { isStreaming = started }
    }

    /// 一次读数可能比实际姿态老一整个刷新周期,所以快速合盖要从盖子"将要去"的位置
    /// 判断,而不是最后一次读数。
    private func predictedAngle() -> Double {
        guard angularVelocity < -Self.predictionSpeedFloor else { return rawAngle }
        let staleness = min(CACurrentMediaTime() - lastChangeTime, 0.12)
        return rawAngle + angularVelocity * (staleness + Self.predictionLatency)
    }

    private func publish(angle: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.08 else { return }
        lastPublishTime = now
        if abs(currentAngle - angle) > 0.001 { currentAngle = angle }
    }

    // MARK: - 透视效果

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            startedAt = CACurrentMediaTime()
            visualAngle.reset(to: rawAngle)
            snapshotter.endPrewarm()
            monitor.setInterval(LidAngleMonitor.activeInterval)
            presentPicture()
        } else {
            stopDisplayLink()
            overlay.dismiss(animated: true)
            snapshotter.discard()
        }
    }

    /// 显示持有的截图,或者等一张。正在跑的预热抓帧也算"在等"。
    private func presentPicture() {
        if preferences.isLivePicture, let screen = NSScreen.builtIn,
           overlay.showLive(
               on: screen,
               startAngle: preferences.thresholdAngle,
               tuning: preferences.tuning,
               fadeIn: Self.fadeInDuration
           ) {
            startDisplayLink()
            if let frame = streamer.newFrame() {
                LidDepthLog.lid.notice("present: live, a stream frame was ready")
                overlay.absorb(frame)
                return
            }
            // 快速合盖可能在流有帧之前就到触发角了。一张截图先把画面起起来。
            if let image = snapshotter.latestImage {
                LidDepthLog.lid.notice("present: live, seeding from the pre-warm screenshot")
                overlay.seed(image: image)
                return
            }
            LidDepthLog.lid.notice("present: live, no picture yet, asking for a screenshot")
            requestSeed()
            return
        }

        // 静帧档(未开启实时流,或屏幕录制权限缺失)。
        if let image = snapshotter.latestImage, let screen = snapshotter.latestScreen {
            show(image: image, on: screen)
            return
        }
        isCapturePending = true
        Task { [weak self] in
            guard let self else { return }
            await self.snapshotter.captureOnce()
            self.isCapturePending = false
            LidDepthLog.lid.notice(
                """
                capture landed: image \(self.snapshotter.latestImage != nil) \
                on \(self.isActive) overlay \(self.overlay.isVisible)
                """
            )
            guard self.isActive, !self.overlay.isVisible,
                  let image = self.snapshotter.latestImage,
                  let screen = self.snapshotter.latestScreen else { return }
            self.show(image: image, on: screen)
        }
    }

    /// 为还没有东西可显示的实时覆盖窗抓一张截图起头。先到的流帧会让它变得不必要。
    private func requestSeed() {
        isCapturePending = true
        let started = CACurrentMediaTime()
        Task { [weak self] in
            guard let self else { return }
            await self.snapshotter.captureOnce()
            self.isCapturePending = false
            LidDepthLog.lid.notice(
                """
                seed capture landed after \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms: \
                image \(self.snapshotter.latestImage != nil) on \(self.isActive) \
                ready \(self.overlay.isPictureReady)
                """
            )
            guard self.isActive, !self.overlay.isPictureReady,
                  let image = self.snapshotter.latestImage else { return }
            self.overlay.seed(image: image)
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        overlay.show(
            image: image,
            on: screen,
            startAngle: preferences.thresholdAngle,
            tuning: preferences.tuning,
            fadeIn: Self.fadeInDuration
        )
        // display link 属于覆盖窗。
        startDisplayLink()
    }

    private func blurProgress(for angle: Double) -> Double {
        let span = max(preferences.blurSpan, 1)
        return min(max((preferences.thresholdAngle - angle) / span, 0), 1)
    }

    // MARK: - 动画

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.hostWindow else {
            LidDepthLog.lid.notice("display link skipped, no overlay window")
            return
        }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawInterval = now - lastFrameTime
        // 半隐式欧拉要求 frequency * dt < 2,这里把 dt 夹住。
        let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now
        if let frame = streamer.newFrame() {
            overlay.absorb(frame)
        }
        visualAngle.advance(to: rawAngle, dt: dt)
        applyVisual(angle: visualAngle.value)
    }

    /// 几何直接吃盖角本身,所以只有模糊会饱和。
    private func applyVisual(angle: Double) {
        let progress = blurProgress(for: angle)
        overlay.update(progress: progress, currentAngle: angle, tuning: preferences.tuning)
    }

    // MARK: - 系统事件

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
        systemObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParametersChange() }
        })
    }

    /// 总开关变化 → 重新评估采样门控（关掉即停表）。
    private func observeEnabledChanges() {
        guard enabledCancellable == nil else { return }
        enabledCancellable = preferences.$isEnabled
            .sink { [weak self] _ in
                Task { @MainActor in self?.updatePollingState() }
            }
    }

    private func handleScreenParametersChange() {
        // macOS 在背光与色彩变化时也会发这条通知。
        let screen = NSScreen.builtIn
        let layout = LidScreenLayout(displayID: screen?.displayID, frame: screen?.frame)
        guard layout != builtInLayout else {
            LidDepthLog.lid.notice("screen parameters changed, layout unchanged")
            return
        }
        LidDepthLog.lid.notice(
            "screen parameters changed, layout now \(String(describing: layout), privacy: .public)"
        )
        builtInLayout = layout
        if isActive { setActive(false) }
        streamer.stop()
        streamer.invalidateFilter()
        Task { await streamer.warmFilter() }
        overlay.discardLive()
        snapshotter.discard()
        Task { await snapshotter.warmFilter() }
    }

    private func suspend() {
        LidDepthLog.lid.notice("suspend")
        isSuspended = true
        stopDisplayLink()
        overlay.dismiss(animated: false)
        snapshotter.endPrewarm()
        snapshotter.discard()
        streamer.stop()
        updateStreamingState()
        overlay.discardLive()
        preview = nil
        isActive = false
        isCapturePending = false
        updatePollingState()
    }

    private func resume() {
        LidDepthLog.lid.notice("resume")
        isSuspended = false
        // 重建基线:否则"几乎合着醒过来"会被读成正在合盖。
        lastAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        lastMovedDownTime = -.greatestFiniteMagnitude
        monitor.resetBaseline()
        if let angle = monitor.sampleNow().angle {
            rawAngle = angle
            visualAngle.reset(to: angle)
        }
        updatePollingState()
    }
}
