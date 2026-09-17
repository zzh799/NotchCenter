import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 让内置屏的**最新截图**随时待命。
///
/// 上游 Mac-Duo 的 `ScreenSnapshotter`,原样移植。
///
/// 构建一个 `SCContentFilter` 要枚举屏幕上所有窗口,所以 filter 会被缓存,只在
/// 显示器变化时重建。
///
/// 这是**权限降级档**的数据源:拿不到屏幕录制权限时实时流不可用,效果退化为
/// 合盖瞬间的一张静帧。
@MainActor
final class ScreenSnapshotter {

    private(set) var latestImage: CGImage?
    private(set) var latestScreen: NSScreen?

    private var filter: SCContentFilter?
    private var filterDisplayID: CGDirectDisplayID?
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private var lastLoggedGeometry: String?

    /// 屏幕录制权限查询。注入点只服务单测(默认读真实 TCC 状态,查询本身不弹窗)。
    private let permissionCheck: () -> Bool

    init(permissionCheck: @escaping () -> Bool = CGPreflightScreenCaptureAccess) {
        self.permissionCheck = permissionCheck
    }

    /// 是否正在预热抓帧。
    var isPrewarming: Bool { timer != nil }

    /// 屏幕录制权限是否已授予。
    var hasPermission: Bool { permissionCheck() }

    /// 开始按 `interval` 持续刷新截图。合盖即将发生时调用。
    func beginPrewarm(interval: TimeInterval = 0.2) {
        // 没权限就没有 filter 可建,开了定时器也只是空转。
        guard timer == nil, hasPermission else { return }
        startCapture()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.startCapture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 停止预热。
    func endPrewarm() {
        timer?.invalidate()
        timer = nil
    }

    /// 丢掉持有的截图。
    func discard() {
        latestImage = nil
        latestScreen = nil
    }

    /// 等一次截图落地。正在跑的预热抓帧也算。
    func captureOnce() async {
        await startCapture().value
    }

    /// 只构建抓帧 filter,不真的截图。
    func warmFilter() async {
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { return }
        if filter == nil || filterDisplayID != displayID {
            await rebuildFilter(displayID: displayID)
        }
    }

    /// 丢掉缓存的 filter，下次重建（权限恢复、显示器热插拔后调用）。
    func invalidateFilter() {
        filter = nil
        filterDisplayID = nil
    }

    @discardableResult
    private func startCapture() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            await self?.performCapture()
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    private func performCapture() async {
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { return }
        if filter == nil || filterDisplayID != displayID {
            await rebuildFilter(displayID: displayID)
        }
        guard let activeFilter = filter else { return }

        // 抓帧同样要在 detached 任务里做:`captureImage` 是 nonisolated async,
        // 把非 Sendable 的 filter 从主 actor 递出去会被严格并发拦下。filter 与
        // 尺寸(都不是 Sendable)在这里先取成值,闭包只捕获值 + 信封,不碰 self。
        let boxed = ScreenCaptureFilterBox(filter: activeFilter)
        let contentWidth = activeFilter.contentRect.width
        let contentHeight = activeFilter.contentRect.height
        let pixelScale = activeFilter.pointPixelScale
        let started = CFAbsoluteTimeGetCurrent()
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
            let configuration = SCStreamConfiguration()
            configuration.width = Int(contentWidth * CGFloat(pixelScale))
            configuration.height = Int(contentHeight * CGFloat(pixelScale))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: boxed.filter,
                    configuration: configuration
                )
                return .success(image)
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case let .success(image):
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            latestImage = image
            latestScreen = screen
            LidDepthLog.geometry.debug("captureImage took \(elapsed, format: .fixed(precision: 1)) ms")
            let geometry = String(
                format: "screen %.0fx%.0f pt at (%.0f, %.0f), backingScale %.2f, contentRect %.0fx%.0f, pointPixelScale %.2f, got %dx%d px",
                screen.frame.width, screen.frame.height,
                screen.frame.origin.x, screen.frame.origin.y,
                screen.backingScaleFactor,
                contentWidth, contentHeight,
                CGFloat(pixelScale),
                image.width, image.height
            )
            if geometry != lastLoggedGeometry {
                lastLoggedGeometry = geometry
                LidDepthLog.geometry.notice("capture: \(geometry, privacy: .public)")
            }
        case let .failure(error):
            // 典型原因:权限被撤销、显示器热插拔。清掉 filter 让下次重建。
            LidDepthLog.geometry.error(
                "capture failed: \(String(describing: error), privacy: .public)"
            )
            filter = nil
            filterDisplayID = nil
        }
    }

    private func rebuildFilter(displayID: CGDirectDisplayID) async {
        // 没授权就一次都不碰 ScreenCaptureKit:`SCShareableContent` 本身就是系统
        // 授权窗的触发点(启动期预热 = 每次开机弹窗),权限只能由用户在宿主的
        // 「权限管理」弹窗里显式申请(授权后需重启 App 生效)。
        guard hasPermission else { return }
        // `SCShareableContent` 与 `SCDisplay`/`SCRunningApplication` 都不是 `Sendable`,
        // 不能从 nonisolated 的 async 调用跨回主 actor(Swift 6 严格并发;上游编译在
        // Swift 5 模式没有这个约束)。所以枚举与挑选全在 detached 任务里做完,只把
        // 结论——一个 `SCContentFilter`(它本身是 Sendable)——带回来。
        let bundleID = Bundle.main.bundleIdentifier
        let resolved = await Task.detached(priority: .userInitiated) { () -> ScreenCaptureFilterBox? in
            do {
                let started = CFAbsoluteTimeGetCurrent()
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                LidDepthLog.geometry.notice(
                    "SCShareableContent took \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms"
                )
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    return nil
                }
                // 把自己排除掉,否则残留的覆盖窗会进到下一次截图里。
                let ownApplications = content.applications.filter { $0.bundleIdentifier == bundleID }
                return ScreenCaptureFilterBox(filter: SCContentFilter(
                    display: display,
                    excludingApplications: ownApplications,
                    exceptingWindows: []
                ))
            } catch {
                LidDepthLog.geometry.error(
                    "snapshot filter failed: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }.value

        if let resolved {
            filter = resolved.filter
            filterDisplayID = displayID
        } else {
            filter = nil
            filterDisplayID = nil
        }
    }
}
