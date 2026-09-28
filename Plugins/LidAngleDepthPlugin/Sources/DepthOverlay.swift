import AppKit
import Metal
import NotchCenterKit
import QuartzCore

/// 一个盖在一切之上(含菜单栏与全屏空间)的无边框窗口。它从不获取焦点、从不接点击。
///
/// **与上游的差异(D3)**:上游用 `CGShieldingWindowLevel()`,那是屏保/屏蔽层级,
/// 会盖住宿主自己的刘海面板(宿主面板在 `.statusBar` 级)与插件管理窗口。
/// 这里改用 **屏保层级之下、状态栏之上** 的一档:效果依然盖住普通应用与菜单栏,
/// 但宿主自己的面板仍在最上面,用户可以随时把抽屉拉出来关掉效果。
final class DepthOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 覆盖窗层级：层级阶梯里的 `effectOverlay`（屏保层下一档），高于宿主全部界面。
    static var overlayLevel: NSWindow.Level { HostWindowLevel.effectOverlay }
}

private final class MetalHostView: NSView {
    init(layer metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// layer 要跟着 view 一起缩放,否则窗口改尺寸后画面会停在旧大小。
    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

/// 拥有**一次效果运行**的覆盖窗。
///
/// 上游 Mac-Duo 的 `DepthOverlay`,原样移植。
@MainActor
final class DepthOverlay {

    private var window: DepthOverlayWindow?
    /// 上一次运行正在淡出的窗口。AppKit 会让它活过淡出动画,所以新一轮运行
    /// 必须自己把它收掉。
    private var fadingWindow: DepthOverlayWindow?
    private var presenceWindow: DepthOverlayWindow?
    /// 只建一次并保留。
    private var renderer: DepthRenderer?
    private var hasTriedToBuildRenderer = false
    private var buildToken = 0
    private let buildQueue = DispatchQueue(label: "NotchCenter.LidDepth.pictureUpload", qos: .userInteractive)

    private var screenSize: CGSize = .zero
    private var startAngle: Double = 90
    private var geometry = DepthGeometry()
    private var gradient = BlurGradient()
    private var tuning = DepthTuning()
    private var fadeIn: TimeInterval = 0.07
    private var hasRevealed = false

    /// 覆盖窗是否在屏上。
    var isVisible: Bool { window != nil }
    /// 画面是否已就绪。
    var isPictureReady: Bool { renderer?.isReady ?? false }
    /// 承载画面的窗口。display link 要挂在它上面。
    var hostWindow: NSWindow? { window }

    /// 提前把渲染器建起来(Metal 设备与管线编译有成本)。
    @discardableResult
    func warmUp() -> Bool {
        if !hasTriedToBuildRenderer {
            hasTriedToBuildRenderer = true
            renderer = DepthRenderer()
        }
        keepPresence()
        return renderer != nil
    }

    /// 一个点大小的空窗口。
    ///
    /// ScreenCaptureKit 只列出拥有窗口的应用,而流必须点名本应用才能把覆盖窗
    /// 排除在自己的画面之外。
    private func keepPresence() {
        guard presenceWindow == nil else { return }
        let window = DepthOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.alphaValue = 0.004
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        presenceWindow = window
    }

    /// 为实时流立一个窗口。第一帧被吸收之前它一直是透明的。
    @discardableResult
    func showLive(
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) -> Bool {
        dismiss(animated: false)
        guard warmUp(), let renderer else { return false }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size

        let pixelScale = Double(screen.backingScaleFactor)
        guard renderer.beginLive(screenSize: screenSize, pixelScale: CGFloat(pixelScale)) else { return false }
        buildToken += 1
        makeWindow(on: screen, pixelScale: pixelScale)
        return window != nil
    }

    /// 把一帧实时画面交给渲染器,并在第一帧落地后揭幕。
    func absorb(_ frame: MTLTexture) {
        guard window != nil, let renderer else { return }
        renderer.absorb(frame)
        reveal()
    }

    /// 用一张持有的静帧起头。
    func seed(image: CGImage) {
        guard window != nil, let renderer, renderer.seed(image: image) else { return }
        reveal()
    }

    /// 释放实时画面。
    func discardLive() {
        renderer?.discardLive()
    }

    /// 用一张**静帧**显示效果(无屏幕录制实时流,或实时流还没起来时)。
    func show(
        image: CGImage,
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) {
        dismiss(animated: false)
        guard warmUp(), let renderer else { return }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size

        let pixelScale = screen.frame.width > 0
            ? Double(image.width) / Double(screen.frame.width)
            : Double(screen.backingScaleFactor)

        makeWindow(on: screen, pixelScale: pixelScale)
        guard let window else { return }

        buildToken += 1
        let token = buildToken
        let size = screenSize
        // 上传与建金字塔要几十毫秒,放主线程会卡住合盖动画的头几帧。
        buildQueue.async { [weak self, weak renderer] in
            guard let renderer else { return }
            let picture = renderer.makePicture(image: image, screenSize: size, pixelScale: CGFloat(pixelScale))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.buildToken == token, self.window === window,
                          let picture else { return }
                    renderer.adopt(picture)
                    self.update(progress: 0, currentAngle: self.startAngle, tuning: self.tuning)
                    self.reveal()
                }
            }
        }
    }

    private func makeWindow(on screen: NSScreen, pixelScale: Double) {
        guard let renderer else { return }
        let view = MetalHostView(layer: renderer.makeLayer(), scale: CGFloat(pixelScale))
        view.frame = NSRect(origin: .zero, size: screenSize)
        view.autoresizingMask = [.width, .height]

        let window = DepthOverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 效果是"看的",不是"点的":点击照旧穿到下面的应用。
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = DepthOverlayWindow.overlayLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        hasRevealed = false
        self.window = window
    }

    /// 在画面有东西可画之后淡入,且只淡入一次。
    private func reveal() {
        guard let window, !hasRevealed, renderer?.isReady == true else { return }
        hasRevealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// 更新一帧。
    func update(progress: Double, currentAngle: Double, tuning: DepthTuning) {
        guard let renderer, renderer.isReady else { return }
        self.tuning = tuning
        renderer.render(
            corners: DepthProjection.corners(
                startAngle: startAngle,
                currentAngle: currentAngle,
                tuning: tuning,
                screenSize: screenSize,
                geometry: geometry
            ),
            blurStrength: gradient.blurStrength(progress: progress),
            dimStrength: gradient.dimStrength(progress: progress),
            hingeFloor: tuning.blurEvenness,
            dimHingeFloor: gradient.dimHingeFloor,
            dimReach: tuning.dimReach,
            maxBlurRadius: tuning.maxBlurRadius,
            maxDim: tuning.maxDim
        )
    }

    /// 收掉覆盖窗。
    func dismiss(animated: Bool, duration: TimeInterval = 0.22) {
        closeFadingWindow()
        guard let window else { return }
        self.window = nil
        buildToken += 1
        renderer?.release()

        guard animated else {
            window.orderOut(nil)
            window.close()
            return
        }

        fadingWindow = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.fadingWindow === window { self.fadingWindow = nil }
                window.orderOut(nil)
                window.close()
            }
        }
    }

    /// 收掉正在淡出的窗口。
    private func closeFadingWindow() {
        guard let fadingWindow else { return }
        self.fadingWindow = nil
        fadingWindow.orderOut(nil)
        fadingWindow.close()
    }

    /// 插件被禁用时彻底拆掉,包括那个 1 点存在窗口。
    func shutdown() {
        dismiss(animated: false)
        presenceWindow?.orderOut(nil)
        presenceWindow?.close()
        presenceWindow = nil
    }
}
