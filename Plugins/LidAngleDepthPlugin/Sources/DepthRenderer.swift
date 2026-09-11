import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

/// 用 Metal 绘制画面。
///
/// 上游 Mac-Duo 的 `DepthRenderer`,原样移植(仅日志入口改为本插件自己的)。
///
/// 画面连同一圈黑边放在一张纹理里,上面盖着高斯金字塔。每帧一次全屏 pass。
@MainActor
final class DepthRenderer {

    /// 画面四周的黑边,单位点。始终大于最大模糊半径,这样每一侧都能模糊到真黑。
    nonisolated private static let paddingInPoints: CGFloat = 120

    private struct Uniforms {
        var column0: SIMD4<Float>
        var column1: SIMD4<Float>
        var column2: SIMD4<Float>
        var screenAndOrigin: SIMD4<Float>
        var paddedAndBlur: SIMD4<Float>
        var shape: SIMD4<Float>
        var light: SIMD4<Float>
    }

    /// 一张已备好的画面,在主线程之外构建、在主线程上采用。
    struct PreparedPicture {
        let texture: MTLTexture
        let colourSpace: CGColorSpace
        let paddedOrigin: CGPoint
        let paddedSize: CGSize
        let maxLevel: Float
        let pixelScale: CGFloat
        let screenSize: CGSize
    }

    /// 下一帧画到哪。一个 layer 同时只属于一个 view,所以每个覆盖窗都要有自己的。
    private(set) var layer = CAMetalLayer()

    /// Metal 设备与命令队列。上传静帧要在主线程之外做(一张整屏纹理的 draw 有几十
    /// 毫秒),所以这两个被 `nonisolated` 方法 `makePicture` 用到。
    ///
    /// Swift 6 严格并发下 `MTLDevice`/`MTLCommandQueue` 都不是 `Sendable`,不能直接
    /// 作为 `@MainActor` 类的 `nonisolated` 存储属性(上游编译在 Swift 5 模式,没有这个
    /// 约束)。这里把它们装进一个不可变盒子:`init` 之后不再改动,`makePicture` 只从
    /// 盒子读取对象引用,不上传任何可变状态——上传用的 `staging` 缓冲是该方法内的局部
    /// 变量。
    private struct MetalHandles: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
    }

    private let handles: MetalHandles
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var screenSize: CGSize = .zero
    private var pixelScale: CGFloat = 2
    private var paddedOrigin: CGPoint = .zero
    private var paddedSize: CGSize = .zero
    private var maxLevel: Float = 0

    /// 实时流写入的那张画面。`makePicture` 会自己建一张,所以两者同时只有一者在用。
    private var liveTexture: MTLTexture?
    private var liveSize: CGSize = .zero
    private var liveScale: CGFloat = 0
    private var isLiveSource = false
    /// 最新的实时帧,等下一次绘制取走。
    private var pendingFrame: MTLTexture?
    /// 一张待用的静帧,等同一个时机。先到的实时帧会赢,因为它更新。
    private var pendingSeed: (buffer: MTLBuffer, width: Int, height: Int)?
    private static var hasReportedPyramidFailure = false
    /// 只建一次,每帧重新编码。
    private lazy var livePyramid = MPSImageGaussianPyramid(device: handles.device, centerWeight: 0.375)

    /// 画面是否已就绪(可以开始绘制)。
    var isReady: Bool { texture != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.handles = MetalHandles(device: device, queue: queue)

        do {
            let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "depthFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            LidDepthLog.geometry.error("metal pipeline failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        configure(layer)
    }

    /// 为新的覆盖窗做一张全新 layer。之后的帧都画到它上面。
    func makeLayer() -> CAMetalLayer {
        let fresh = CAMetalLayer()
        configure(fresh)
        layer = fresh
        return fresh
    }

    private func configure(_ target: CAMetalLayer) {
        target.device = handles.device
        target.pixelFormat = .bgra8Unorm_srgb
        target.framebufferOnly = true
        // 一个不透明的 layer 盖住屏幕会让窗口服务器把它后面的每个窗口都标成
        // hidden,应用就不再绘制了。着色器处处写 alpha 1,所以走混合得到同样的画面。
        target.isOpaque = false
        // 在这里等刷新会阻塞主线程。实时流把本 App 排除在自己画面之外时,窗口服务器
        // 要画两遍屏幕,drawable 回来得晚,等待就落到再下一次刷新:60fps 变 32fps。
        // 绘制节拍已经由 display link 给出,这里不必再同步。
        target.displaySyncEnabled = false
        target.needsDisplayOnBoundsChange = true
    }

    /// 把画面放到黑边上、上传、建好金字塔。**在主线程之外调用**。
    nonisolated func makePicture(image: CGImage, screenSize: CGSize, pixelScale: CGFloat) -> PreparedPicture? {
        let started = CFAbsoluteTimeGetCurrent()
        let padding = Self.paddingInPoints
        let paddedSize = CGSize(
            width: screenSize.width + 2 * padding,
            height: screenSize.height + 2 * padding
        )
        let width = Int((paddedSize.width * pixelScale).rounded())
        let height = Int((paddedSize.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4

        let device = handles.device
        guard let staging = device.makeBuffer(length: byteCount, options: .storageModeShared) else { return nil }

        let colourSpace: CGColorSpace
        if let space = image.colorSpace, space.model == .rgb {
            colourSpace = space
        } else {
            colourSpace = CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(
            data: staging.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let contextReady = CFAbsoluteTimeGetCurrent()

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let inset = padding * pixelScale
        context.draw(image, in: CGRect(
            x: inset,
            y: inset,
            width: CGFloat(width) - 2 * inset,
            height: CGFloat(height) - 2 * inset
        ))
        let drawn = CFAbsoluteTimeGetCurrent()

        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard var texture = device.makeTexture(descriptor: descriptor),
              let commands = handles.queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: width * 4,
            sourceBytesPerImage: byteCount,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
            .encode(commandBuffer: commands, inPlaceTexture: &texture, fallbackCopyAllocator: nil)
        commands.commit()
        commands.waitUntilCompleted()
        let finished = CFAbsoluteTimeGetCurrent()

        LidDepthLog.geometry.notice(
            """
            metal texture \(width)x\(height) px, \(levels) levels: \
            context \((contextReady - started) * 1000, format: .fixed(precision: 1)) ms, \
            draw \((drawn - contextReady) * 1000, format: .fixed(precision: 1)) ms, \
            gpu \((finished - drawn) * 1000, format: .fixed(precision: 1)) ms
            """
        )
        return PreparedPicture(
            texture: texture,
            colourSpace: colourSpace,
            paddedOrigin: CGPoint(x: -padding, y: -padding),
            paddedSize: paddedSize,
            maxLevel: Float(levels - 1),
            pixelScale: pixelScale,
            screenSize: screenSize
        )
    }

    // MARK: - 实时源

    /// 为实时流准备画面。黑边只填一次;之后每帧只覆盖内部。第一帧到达前不画任何东西。
    @discardableResult
    func beginLive(screenSize: CGSize, pixelScale: CGFloat) -> Bool {
        let padding = Self.paddingInPoints
        let padded = CGSize(
            width: screenSize.width + 2 * padding,
            height: screenSize.height + 2 * padding
        )
        let width = Int((padded.width * pixelScale).rounded())
        let height = Int((padded.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return false }

        if liveTexture == nil || liveSize != padded || liveScale != pixelScale {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width,
                height: height,
                mipmapped: true
            )
            // `renderTarget` 只为那一次把黑边涂黑的 clear 存在。
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let fresh = handles.device.makeTexture(descriptor: descriptor) else { return false }
            clearToBlack(fresh)
            liveTexture = fresh
            liveSize = padded
            liveScale = pixelScale
        }

        texture = nil
        isLiveSource = true
        self.screenSize = screenSize
        self.pixelScale = pixelScale
        paddedOrigin = CGPoint(x: -padding, y: -padding)
        paddedSize = padded
        maxLevel = Float(Int(floor(log2(Double(max(width, height))))))
        layer.colorspace = CGColorSpace(name: ScreenStreamer.colourSpaceName)
        layer.drawableSize = CGSize(
            width: screenSize.width * pixelScale,
            height: screenSize.height * pixelScale
        )
        return true
    }

    /// 用一张持有的静帧把实时画面起个头。流的第一帧会把它盖掉。
    @discardableResult
    func seed(image: CGImage) -> Bool {
        guard isLiveSource, liveTexture != nil else { return false }
        let inset = Int((Self.paddingInPoints * pixelScale).rounded())
        let width = Int((screenSize.width * pixelScale).rounded())
        let height = Int((screenSize.height * pixelScale).rounded())
        guard width > 0, height > 0, inset >= 0 else { return false }
        let bytesPerRow = width * 4
        guard let staging = handles.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              // 用流自己的色彩空间,交接时颜色才不会偏。
              let space = CGColorSpace(name: ScreenStreamer.colourSpaceName),
              let context = CGContext(
                data: staging.contents(),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pendingSeed = (staging, width, height)
        texture = liveTexture
        return true
    }

    /// 收下一帧实时画面,等下一次绘制用。
    func absorb(_ frame: MTLTexture) {
        guard isLiveSource, liveTexture != nil else { return }
        pendingFrame = frame
        pendingSeed = nil
        // 下一次 pass 读的就是这个纹理对象,拷进它的动作排在那个 pass 之前编码。
        texture = liveTexture
    }

    /// 把最新的帧拷进画面并重建金字塔。
    private func absorbPending(into commands: MTLCommandBuffer) {
        guard var target = liveTexture, pendingFrame != nil || pendingSeed != nil else { return }
        let inset = Int((Self.paddingInPoints * pixelScale).rounded())
        guard let blit = commands.makeBlitCommandEncoder() else { return }
        if let frame = pendingFrame {
            let width = min(frame.width, target.width - 2 * inset)
            let height = min(frame.height, target.height - 2 * inset)
            guard width > 0, height > 0 else { blit.endEncoding(); return }
            blit.copy(
                from: frame,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
            )
        } else if let seed = pendingSeed {
            let width = min(seed.width, target.width - 2 * inset)
            let height = min(seed.height, target.height - 2 * inset)
            guard width > 0, height > 0 else { blit.endEncoding(); return }
            blit.copy(
                from: seed.buffer,
                sourceOffset: 0,
                sourceBytesPerRow: seed.width * 4,
                sourceBytesPerImage: seed.width * 4 * seed.height,
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
            )
        }
        pendingFrame = nil
        pendingSeed = nil
        blit.endEncoding()
        let built = livePyramid.encode(
            commandBuffer: commands,
            inPlaceTexture: &target,
            fallbackCopyAllocator: nil
        )
        if !built, !Self.hasReportedPyramidFailure {
            Self.hasReportedPyramidFailure = true
            LidDepthLog.geometry.error("live pyramid in place encode returned false")
        }
        liveTexture = target
        texture = target
    }

    /// 释放实时画面。
    func discardLive() {
        pendingFrame = nil
        pendingSeed = nil
        if isLiveSource { texture = nil }
        isLiveSource = false
        liveTexture = nil
        liveSize = .zero
        liveScale = 0
    }

    private func clearToBlack(_ target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let commands = handles.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }

    // MARK: - 静帧源

    /// 采用一张备好的画面。
    func adopt(_ picture: PreparedPicture) {
        isLiveSource = false
        texture = picture.texture
        // 不打标签的话窗口服务器会当成 sRGB 再转成显示空间,颜色就偏了。
        layer.colorspace = picture.colourSpace
        paddedOrigin = picture.paddedOrigin
        paddedSize = picture.paddedSize
        maxLevel = picture.maxLevel
        pixelScale = picture.pixelScale
        screenSize = picture.screenSize
        layer.drawableSize = CGSize(
            width: picture.screenSize.width * picture.pixelScale,
            height: picture.screenSize.height * picture.pixelScale
        )
    }

    /// 丢弃当前画面,但保留实时纹理。
    func release() {
        texture = nil
    }

    /// 画一帧。
    /// - Parameter corners: 画面四角投影到屏幕上的位置,单位点,顺序为
    ///   左下、右下、右上、左上。
    func render(
        corners: [CGPoint],
        blurStrength: Double,
        dimStrength: Double,
        hingeFloor: Double,
        dimHingeFloor: Double,
        dimReach: Double,
        maxBlurRadius: Double,
        maxDim: Double
    ) {
        guard let commands = handles.queue.makeCommandBuffer() else { return }
        absorbPending(into: commands)
        guard let texture, screenSize.width > 0, screenSize.height > 0,
              let drawable = layer.nextDrawable() else {
            commands.commit()
            return
        }

        let forward = Homography.matrix(
            width: Double(screenSize.width),
            height: Double(screenSize.height),
            to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        )
        let inverse = forward.inverse

        func column(_ index: Int) -> SIMD4<Float> {
            let c = inverse[index]
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
        }
        var uniforms = Uniforms(
            column0: column(0),
            column1: column(1),
            column2: column(2),
            screenAndOrigin: SIMD4(
                Float(screenSize.width), Float(screenSize.height),
                Float(paddedOrigin.x), Float(paddedOrigin.y)
            ),
            paddedAndBlur: SIMD4(
                Float(paddedSize.width), Float(paddedSize.height),
                Float(maxBlurRadius * Double(pixelScale)), Float(blurStrength)
            ),
            shape: SIMD4(Float(hingeFloor), Float(maxDim), Float(pixelScale), maxLevel),
            light: SIMD4(Float(dimHingeFloor), Float(dimStrength), Float(dimReach), 0)
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            commands.commit()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
