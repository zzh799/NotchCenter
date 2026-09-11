import ScreenCaptureKit

/// 把 `SCContentFilter` 搬过并发边界的信封。
///
/// `SCContentFilter` 在 macOS 15 SDK 里没有标注 `Sendable`,但它在构造完成后就是
/// **不可变**的:只描述"抓哪块屏、排除哪些应用",不含可变状态,`SCStream` /
/// `SCScreenshotManager` 只读它。Swift 6 严格并发下没标注的框架类型一律拒收,
/// 所以这里显式承担这个保证(上游编译在 Swift 5 模式,不需要这一步)。
///
/// 纪律:信封只在"后台枚举窗口 → 主 actor 持有 filter"这一次交接中使用,之后
/// filter 只被主 actor 触碰。
struct ScreenCaptureFilterBox: @unchecked Sendable {
    let filter: SCContentFilter
}

/// 把 `SCStream` 搬过并发边界的信封。
///
/// `startCapture()` / `stopCapture()` 是 nonisolated `async` 方法:调用它们会把
/// `SCStream` 本身递出主 actor,而它同样没有标注 `Sendable`。`SCStream` 的启停是
/// 线程安全的设计(Apple 文档明确 `startCapture` 可在任意队列调用,回调走
/// `sampleHandlerQueue`),这里显式承担该保证。
///
/// 纪律:信封只用于 `begin`/`stop` 里那两次启停调用;`SCStream` 的引用本身仍只由
/// 主 actor 持有。
struct ScreenStreamBox: @unchecked Sendable {
    let stream: SCStream
}

/// 把流输出接收端搬过并发边界的信封。
///
/// `SCStreamOutput` 的 `stream(_:didOutputSampleBuffer:of:)` 会在
/// `sampleHandlerQueue` 上被调用,所以接收端在设计上本来就要跨队列;它内部用
/// `NSLock` 保护最新帧(`ScreenStreamer.Receiver` 的既有约定)。
struct ScreenStreamOutputBox: @unchecked Sendable {
    let output: SCStreamOutput
}
