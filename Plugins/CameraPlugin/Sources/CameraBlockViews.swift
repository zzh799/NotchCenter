import AVFoundation
import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 布局常量（探针与视图同源）

enum CameraBlockMetrics {
    static let inset: CGFloat = 10
    static let headerHeight: CGFloat = 18
    static let spacing: CGFloat = 6
    static let statusRowHeight: CGFloat = 22
    /// 预览区最小高度（小尺寸下仍要能看到画面）。
    static let previewMinHeight: CGFloat = 60
}

// MARK: - 摄像头镜像块

/// 一键预览摄像头画面。未授权时渲染权限引导态（不崩不报错）。
struct CameraMirrorBlockView: View {
    let context: BlockContext
    @ObservedObject private var store = CameraStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: CameraBlockMetrics.spacing) {
            header
            content
        }
        .padding(CameraBlockMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.refreshAuthorization(hostController: context.hostController) }
        .onDisappear { store.stopSession() }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "camera")
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(L("mirror.title"))
                .font(NotchTokens.Text.system(11, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.body)
            Spacer(minLength: 0)
            if store.isRunning {
                Button {
                    store.toggleSession()
                } label: {
                    Text(store.isPaused ? L("mirror.resume") : L("mirror.pause"))
                        .font(NotchTokens.Text.system(9, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: CameraBlockMetrics.headerHeight)
    }

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

    private var preview: some View {
        ZStack {
            CameraPreviewLayer(session: store.session)
                .clipShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous))
            if !store.isRunning {
                // 未开始采集时给一个明确的"点一下就开始"，而不是一块黑。
                Button {
                    store.toggleSession()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "video.fill")
                            .font(NotchTokens.Text.system(16))
                        Text(L("mirror.start"))
                            .font(NotchTokens.Text.system(9, weight: .semibold))
                    }
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: CameraBlockMetrics.previewMinHeight)
        .background {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(NotchTokens.Surface.fill)
        }
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
                    .font(NotchTokens.Text.system(12))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(title)
                    .font(NotchTokens.Text.system(11, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                    .lineLimit(1)
            }
            Text(message)
                .font(NotchTokens.Text.system(9))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openGuide) {
                Text(L("gate.openSettings"))
                    .font(NotchTokens.Text.system(9, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                    .fill(NotchTokens.Surface.fillHighlighted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openGuide() {
        if let hostController {
            hostController.presentPermissions([permission])
        } else {
            NSWorkspace.shared.open(SystemSettingsURL.url(for: permission))
        }
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

/// `AVCaptureSession` 的跨线程搬运盒。
///
/// `AVCaptureSession` 未标 `Sendable`（它是 Objective-C 遗留类型），但 Apple 的
/// 文档明确 start/stopRunning 可从任意线程调用。这里做一次显式豁免，
/// 把"我知道我在做什么"写进类型名而不是散在调用点。
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

/// 摄像头会话与授权状态的唯一持有者。
@MainActor
final class CameraStore: ObservableObject {
    static let shared = CameraStore()

    @Published private(set) var authorization: PermissionStatus = .notDetermined
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false

    /// 会话实例（跨视图副本共享同一个）。
    let session = AVCaptureSession()

    private var isConfigured = false
    private weak var hostController: (any HostController)?

    private init() {}

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
        // `startRunning()` 是阻塞调用，必须离开主线程。`AVCaptureSession` 未标
        // `Sendable`，但 Apple 明确它可在任意线程安全地启停；用 `SessionBox`
        // 的 `@unchecked Sendable` 承载（与 NotesImageStore 同族的显式豁免）。
        let box = SessionBox(session)
        Task.detached(priority: .userInitiated) {
            if !box.session.isRunning {
                box.session.startRunning()
            }
        }
        isRunning = true
        isPaused = false
    }

    func stopSession() {
        guard isRunning else { return }
        let box = SessionBox(session)
        Task.detached(priority: .utility) {
            if box.session.isRunning { box.session.stopRunning() }
        }
        isRunning = false
        isPaused = true
    }

    /// 首次启动时配置输入（只需一次）。
    func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        guard let device = CameraDevices.preferredDevice(),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
    }
}
