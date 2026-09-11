import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit

/// 内置屏的**实时画面**,以 Metal 纹理形式交出。
///
/// 上游 Mac-Duo 的 `ScreenStreamer`,原样移植。
///
/// 帧由 `IOSurface` 支撑,所以包成纹理不复制任何数据。`startCapture` 耗时较长,
/// 因此流必须在盖子还在合的过程中就起来,而不是等到触发角才开始。
@MainActor
final class ScreenStreamer {

    /// Display P3 与 sRGB 用同一条传输函数,所以着色器的 sRGB 像素格式能正确解码。
    static let colourSpaceName = CGColorSpace.displayP3

    /// 帧在流自己的队列上到达。最新的那张在锁下保存、由主线程取走;
    /// 纹理缓存只在流队列上动。
    private final class Receiver: NSObject, SCStreamOutput {
        private let cache: CVMetalTextureCache
        private let lock = NSLock()
        private var newest: CVMetalTexture?
        private var newestID: UInt64 = 0

        init?(device: MTLDevice) {
            var made: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &made) == kCVReturnSuccess,
                  let made else { return nil }
            cache = made
            super.init()
        }

        /// 最新的帧及其编号;第一帧到达前是 nil。
        func latest() -> (texture: MTLTexture, id: UInt64)? {
            lock.lock()
            defer { lock.unlock() }
            guard let newest, let texture = CVMetalTextureGetTexture(newest) else { return nil }
            return (texture, newestID)
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen,
                  CMSampleBufferIsValid(sampleBuffer),
                  let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // 放开没人持有的 surface,让池子继续回收。
            CVMetalTextureCacheFlush(cache, 0)

            var wrapped: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixels,
                nil,
                .bgra8Unorm_srgb,
                CVPixelBufferGetWidth(pixels),
                CVPixelBufferGetHeight(pixels),
                0,
                &wrapped
            )
            guard result == kCVReturnSuccess, let wrapped else { return }

            lock.lock()
            newest = wrapped
            newestID &+= 1
            lock.unlock()
        }
    }

    private let device: MTLDevice?
    private var stream: SCStream?
    private var receiver: Receiver?
    private var startTask: Task<Void, Never>?
    /// 枚举屏幕上每个窗口要花约 70 ms,所以 filter 在一次运行之间保留,只在显示器变化时重建。
    private var filter: SCContentFilter?
    private var filterDisplayID: CGDirectDisplayID?
    private var consumedID: UInt64 = 0
    private var lastHandOver: CFTimeInterval = 0

    /// 帧的交出间隔下限。刚起的流会以远高于设定帧率的速率吐一阵子。
    private static let minimumHandOverInterval: TimeInterval = 1.0 / 32

    private(set) var isStarted = false
    private(set) var screen: NSScreen?

    /// 屏幕录制权限查询。注入点只服务单测(默认读真实 TCC 状态,查询本身不弹窗)。
    private let permissionCheck: () -> Bool

    init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        permissionCheck: @escaping () -> Bool = CGPreflightScreenCaptureAccess
    ) {
        self.device = device
        self.permissionCheck = permissionCheck
    }

    /// 开始抓取;已在运行时什么都不做。
    func start() {
        guard !isStarted, startTask == nil, device != nil else { return }
        // 没授权就不启动:`SCShareableContent` 与 `startCapture` 都会碰 TCC,
        // 未授权时调用等于替用户拉起系统授权窗(启动期调用 = 每次开机弹窗)。
        guard permissionCheck() else { return }
        guard let target = NSScreen.builtIn, let displayID = target.displayID else { return }
        screen = target
        isStarted = true
        startTask = Task { [weak self] in
            await self?.begin(displayID: displayID, on: target)
            self?.startTask = nil
        }
    }

    /// 停止抓取。
    func stop() {
        guard isStarted || stream != nil else { return }
        isStarted = false
        startTask?.cancel()
        startTask = nil
        let closing = stream
        stream = nil
        receiver = nil
        consumedID = 0
        lastHandOver = 0
        LidDepthLog.geometry.notice("stream stopped")
        guard let closing else { return }
        let boxed = ScreenStreamBox(stream: closing)
        Task { try? await boxed.stream.stopCapture() }
    }

    /// 只构建抓帧 filter,不启动任何东西。
    func warmFilter() async {
        guard permissionCheck() else { return }
        guard let displayID = NSScreen.builtIn?.displayID else { return }
        guard filter == nil || filterDisplayID != displayID else { return }
        await rebuildFilter(displayID: displayID)
    }

    /// 丢掉缓存的 filter,下次启动时重新枚举窗口。
    func invalidateFilter() {
        filter = nil
        filterDisplayID = nil
    }

    /// 最新的帧,**只取一次**。自上次调用以来没有新帧时返回 nil。
    func newFrame() -> MTLTexture? {
        let now = CACurrentMediaTime()
        guard now - lastHandOver >= Self.minimumHandOverInterval else { return nil }
        guard let latest = receiver?.latest(), latest.id != consumedID else { return nil }
        consumedID = latest.id
        lastHandOver = now
        return latest.texture
    }

    private func begin(displayID: CGDirectDisplayID, on target: NSScreen) async {
        guard let device, let receiver = Receiver(device: device) else {
            isStarted = false
            return
        }
        do {
            if filter == nil || filterDisplayID != displayID {
                await rebuildFilter(displayID: displayID)
            }
            guard isStarted, let activeFilter = filter else { return }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(activeFilter.contentRect.width * CGFloat(activeFilter.pointPixelScale))
            configuration.height = Int(activeFilter.contentRect.height * CGFloat(activeFilter.pointPixelScale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = Self.colourSpaceName
            configuration.showsCursor = false
            configuration.queueDepth = 5
            configuration.scalesToFit = false

            let fresh = SCStream(filter: activeFilter, configuration: configuration, delegate: nil)
            try fresh.addStreamOutput(
                ScreenStreamOutputBox(output: receiver).output,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "NotchCenter.LidDepth.frames", qos: .userInteractive)
            )
            let started = CFAbsoluteTimeGetCurrent()
            // 启停是 nonisolated async,会把 SCStream 递出主 actor;它没标 Sendable,
            // 所以走信封交接(理由见 ScreenStreamBox 的注释)。
            let boxed = ScreenStreamBox(stream: fresh)
            try await boxed.stream.startCapture()
            guard isStarted else {
                try? await boxed.stream.stopCapture()
                return
            }
            self.receiver = receiver
            self.stream = fresh
            self.screen = target
            LidDepthLog.geometry.notice(
                """
                stream started \(configuration.width)x\(configuration.height) px in \
                \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms
                """
            )
        } catch {
            LidDepthLog.geometry.error("stream failed: \(String(describing: error), privacy: .public)")
            invalidateFilter()
            isStarted = false
        }
    }

    private func rebuildFilter(displayID: CGDirectDisplayID) async {
        // 同 ScreenSnapshotter:非 Sendable 的 SCShareableContent 全程留在 detached
        // 任务内,只把选好的 SCContentFilter 带回来。
        let bundleID = Bundle.main.bundleIdentifier
        let resolved = await Task.detached(priority: .userInitiated) { () -> ScreenCaptureFilterBox? in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    return nil
                }
                // 把自己排除掉,否则覆盖窗会喂回自己的画面。
                let ownApplications = content.applications.filter { $0.bundleIdentifier == bundleID }
                if ownApplications.isEmpty {
                    LidDepthLog.geometry.error("stream cannot exclude this app: it owns no window yet")
                }
                return ScreenCaptureFilterBox(filter: SCContentFilter(
                    display: display,
                    excludingApplications: ownApplications,
                    exceptingWindows: []
                ))
            } catch {
                LidDepthLog.geometry.error("stream filter failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value

        if let resolved {
            filter = resolved.filter
            filterDisplayID = displayID
        } else {
            invalidateFilter()
        }
    }
}
