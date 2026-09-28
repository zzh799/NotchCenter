import AVFoundation
import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 布局常量（探针与视图同源）

enum CameraBlockMetrics {
    /// 块内容内边距（对齐 `Space.cardPadding`，与其他官方块同值）。
    static let inset: CGFloat = NotchTokens.Space.cardPadding
    /// 预览区圆角。
    static let previewRadius: CGFloat = NotchTokens.Radius.chip
    /// 悬停浮出的启停钮内缩：与宿主编辑角标同一环（`padding(6)`），
    /// 同 ClipboardHistory 的块内角标；直径用 Kit 基元默认的 22pt。
    static let controlInset: CGFloat = 6
    /// 未启动态中央提示的图标字号。
    static let idleSymbolSize: CGFloat = 22
}

// MARK: - 摄像头镜像块

/// 一键预览摄像头画面。未授权时渲染权限引导态（不崩不报错）。
struct CameraMirrorBlockView: View {
    let context: BlockContext
    @ObservedObject private var store = CameraStore.shared

    /// 指针是否在块上：决定右上角启停钮的浮出。
    @State private var isHovering = false

    /// 抽屉是否展开。温存让 `onDisappear` 不再表示"用户看不到了"，而摄像头
    /// 会话必须随"看不到"立刻停——否则收起后继续采集、指示灯常亮。
    @Environment(\.isDrawerPresented) private var isDrawerPresented

    var body: some View {
        // 卡片壳归位：宿主 DrawerBlockContainer 只做 clipShape 与编辑态压暗，
        // 表面（填充/发丝描边）由插件自绘——本块曾漏掉这一步，是 11 个官方
        // 抽屉块里唯一的样式异类。决策见 Agent Note
        // 2026-09-20-camera-mirror-block-styling。
        BlockCard(hoverEffect: false) { _ in
            content
                .padding(CameraBlockMetrics.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // 启停钮：与 ClipboardHistory 的块内角标同一套交互——默认隐藏，鼠标
        // 悬浮组件才浮出，落位与宿主编辑角标同一环（`padding(6)` 的右上角）。
        .overlay(alignment: .topTrailing) {
            if isHovering, store.authorization == .authorized {
                toggleButton
                    .padding(CameraBlockMetrics.controlInset)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(NotchTokens.Motion.hover, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("a11y.mirror"))
        .onAppear { store.refreshAuthorization(hostController: context.hostController) }
        .onDisappear {
            // 过渡副本护栏：滑动切页的预览副本卸载不得停掉真实会话。
            guard !context.layoutInfo.isPreview else { return }
            store.stopSession()
        }
        .onChange(of: isDrawerPresented) { _, presented in
            // 幂等（stopSession 自带 isRunning 闸门）：收起与卸载各会碰到一次。
            guard !presented, !context.layoutInfo.isPreview else { return }
            store.stopSession()
        }
    }

    /// 右上角启停钮：组件默认圆形按钮（Kit `IconCircleButton`，直径 22、自带
    /// 悬停增亮/手型光标/help/a11y），未启动 `play.fill`、运行中 `stop.fill`。
    private var toggleButton: some View {
        IconCircleButton(
            systemImage: store.isRunning ? "stop.fill" : "play.fill",
            helpText: toggleHelpText
        ) {
            store.toggleSession()
        }
        // 过渡副本护栏：滑动切页的预览副本不得真的启停单例会话（同 Pomodoro）。
        .disabled(context.layoutInfo.isPreview)
    }

    /// 块内不再有标题行：画面区独占整块，未授权时换成权限引导态。
    @ViewBuilder
    private var content: some View {
        switch store.authorization {
        case .authorized:
            preview
        case .notDetermined:
            gate(title: L("gate.camera.title"), message: L("gate.camera.message"))
        case .denied:
            gate(title: L("gate.camera.denied.title"), message: L("gate.camera.denied.message"))
        case .restricted:
            gate(title: L("gate.camera.restricted.title"), message: L("gate.camera.restricted.message"))
        }
    }

    /// 画面区：块内唯一内容，整区可点即启停（README 已记载的交互），启停钮
    /// 由块级 overlay 悬浮浮出（见 `body`）。
    ///
    /// 底衬取 `Surface.track` 而非卡片常态同值的 `fill`：未启动态（因为收起
    /// 即停会话，这是本块每次展开的默认长相）必须有可见的取景器，不能是一块
    /// 同色空洞。
    private var preview: some View {
        Button {
            store.toggleSession()
        } label: {
            ZStack {
                CameraPreviewLayer(session: store.session)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: CameraBlockMetrics.previewRadius,
                            style: .continuous))
                if !store.isRunning {
                    // 未启动态没有画面：图标 + 一句话交代这块区域会出现什么。
                    // 右上角启停钮只在悬浮时出现，所以这条提示必须常驻。
                    idleHint
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 过渡副本护栏：滑动切页的预览副本不得真的启停单例会话（同 Pomodoro）。
        .disabled(context.layoutInfo.isPreview)
        .help(toggleHelpText)
        .accessibilityLabel(toggleHelpText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: CameraBlockMetrics.previewRadius, style: .continuous)
                .fill(NotchTokens.Surface.track)
        }
        .overlay {
            RoundedRectangle(cornerRadius: CameraBlockMetrics.previewRadius, style: .continuous)
                .strokeBorder(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
        }
    }

    /// 未启动态中央提示：相机图标 + 「点击打开镜子」。
    private var idleHint: some View {
        VStack(spacing: 5) {
            Image(systemName: "camera")
                .font(NotchTokens.Text.system(CameraBlockMetrics.idleSymbolSize, weight: .light))
            Text(L("mirror.start"))
                .font(NotchTokens.Text.system(12, weight: .medium))
        }
        .foregroundStyle(NotchTokens.Foreground.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 画面区/启停钮的提示与可访问性文案：停止 / 继续 / 开始三态同源于会话状态。
    private var toggleHelpText: String {
        if store.isRunning { return L("mirror.help.stop") }
        return store.isPaused ? L("mirror.help.resume") : L("mirror.help.start")
    }

    private func gate(title: String, message: String) -> some View {
        CameraPermissionGateView(
            symbolName: "camera",
            title: title,
            message: message,
            permission: .camera,
            hostController: context.hostController
        )
    }
}

// MARK: - 权限引导（本插件内共用）

struct CameraPermissionGateView: View {
    let symbolName: String
    let title: String
    let message: String
    let permission: SystemPermission
    let hostController: (any HostController)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(NotchTokens.Text.system(12, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(title)
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                    .lineLimit(1)
            }
            Text(message)
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openGuide) {
                Text(L("gate.openSettings"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(CameraPermissionButtonStyle())
            .help(L("gate.openSettings.help"))
            .accessibilityLabel(L("gate.openSettings.help"))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 只弹宿主的「权限管理」弹窗；系统设置由用户在弹窗内逐行点开，插件不代开。
    private func openGuide() {
        hostController?.presentPermissions([permission])
    }
}

/// 权限引导按钮：走 Kit 统一圆角按钮基体（DESIGN.md §9），参数与 Pomodoro 主按钮
/// 同族，字号按块内档收敛到 11。原实现是自绘
/// `RoundedRectangle(cornerRadius: Radius.thumbnail)`——4pt 属缩略图档位，
/// 圆角与常态/悬停/按下三态反馈都不该由调用点各自重画。
private struct CameraPermissionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: NotchTokens.Text.system(11, weight: .semibold),
            normalOpacity: 0.07,
            hoverOpacity: 0.11,
            pressedOpacity: 0.15,
            strokeOpacity: 0.10,
            foregroundOpacity: 0.92,
            pressedForegroundOpacity: 0.60
        )
    }
}

// MARK: - 预览层（AVCaptureVideoPreviewLayer 的 SwiftUI 包装）

/// `AVCaptureVideoPreviewLayer` 的 `NSViewRepresentable` 包装。
///
/// 视图只负责"显示 session"，会话的启停归 `CameraStore`——多屏会有多份视图副本，
/// 若每份都自己开关会话就会互相打断。
struct CameraPreviewLayer: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    /// 承载 preview layer 的宿主视图（layer-backed，随视图尺寸自动布局）。
    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(previewLayer)
            previewLayer.frame = bounds
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            // 关掉隐式动画：抽屉缩放时预览层跟随容器尺寸，带动画会"追不上"。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }

        /// 镜像显示：照镜子时左右不应反过来（前置摄像头的原始画面是镜像的，
        /// 这里按 macOS 惯例保持镜像，与 Photo Booth 一致）。
        override var isFlipped: Bool { true }
    }
}

// MARK: - 摄像头会话 store

// MARK: - 摄像头会话驱动器

/// `AVCaptureSession` 的串行驱动器。
///
/// 旧实现每次启停各派一个 `Task.detached`：并发队列上的两个任务没有顺序保证，
/// 快速「开→关」时 `stopRunning()` 可能先跑完（此时会话还没开始跑，直接返回），
/// 随后 `startRunning()` 才真正启动——会话在跑而 UI 已认为停止，指示灯常亮且
/// 再也停不掉（`stopSession` 的 `isRunning` 闸门挡住了后续收尾）。
///
/// 这里把 `configure / startRunning / stopRunning` 全部收敛到**同一条串行队列**：
/// 最后一个意图必然最后执行。`AVCaptureSession` 未标 `Sendable`，用 `@unchecked
/// Sendable` 显式豁免（Apple 明确它可在任意线程安全地启停）。
final class CameraSessionDriver: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.notchcenter.camera.session")
    private let stateLock = NSLock()
    private var configured = false

    /// 采集输入是否已成功建过。失败（取不到设备）不置位，下次启动会重试。
    var isConfigured: Bool { stateLock.withLock { configured } }

    /// 应用一个运行意图。幂等：重复 intent 只是重放同一结果。
    func setRunning(_ running: Bool) {
        queue.async { [self] in
            configureIfNeeded()
            if running {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// 首次真的要采集时才建输入（`AVCaptureDeviceInput(device:)` 会碰 TCC，
    /// 提前到装载期等于每次启动 App 弹一次系统授权窗）。只在串行队列上调用。
    /// 只有成功才置位——取不到设备时下次启动重试，而不是永远放弃。
    private func configureIfNeeded() {
        guard !isConfigured else { return }
        guard let device = CameraDevices.preferredDevice(),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        stateLock.withLock { configured = true }
    }
}

/// 摄像头会话与授权状态的唯一持有者。
@MainActor
final class CameraStore: ObservableObject {
    static let shared = CameraStore()

    @Published private(set) var authorization: PermissionStatus = .notDetermined
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false

    private let driver = CameraSessionDriver()

    /// 会话实例（跨视图副本共享同一个）。
    var session: AVCaptureSession { driver.session }

    /// 采集输入是否已建。只读暴露给回归测试：装载期不得为 true。
    var isConfigured: Bool { driver.isConfigured }
    private weak var hostController: (any HostController)?
    /// 激活观察（单例全程存活，无需摘除）。
    private var activationObserver: NSObjectProtocol?

    private init() {
        // 用户去授权（系统窗或「权限管理」弹窗）后切回来时重取状态，否则块会一直
        // 停在引导态，等于权限把功能多锁了一会儿。查询无副作用，安全。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                CameraStore.shared.authorization = Self.currentAuthorization()
            }
        }
    }

    // MARK: 授权

    func refreshAuthorization(hostController: any HostController) {
        self.hostController = hostController
        authorization = Self.currentAuthorization()
    }

    static func currentAuthorization() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: 会话

    func toggleSession() {
        if isRunning {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        guard authorization == .authorized else { return }
        // 采集输入到这一步才建（`AVCaptureDeviceInput(device:)` 会碰 TCC）。
        // 会话的 configure / start / stop 全在驱动器的串行队列上执行，快速切停
        // 不会错序（见 `CameraSessionDriver`）。
        isRunning = true
        isPaused = false
        driver.setRunning(true)
    }

    func stopSession() {
        guard isRunning else { return }
        isRunning = false
        isPaused = true
        driver.setRunning(false)
    }
}
