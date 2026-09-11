import CoreGraphics
import Foundation

/// 画面落在玻璃上的位置。
///
/// 上游 Mac-Duo 的 `DepthGeometry`,原样移植。
///
/// 画面是铰接在屏幕下边、随盖子转过的角度在空间中向后翻的一张纸。玻璃在眼下转动
/// 而眼睛不动,所以投影同时要用到当前盖角与眼睛的位置。
public struct DepthGeometry {

    /// 超过 90 度后画面就背对玻璃了。
    public var maxSeparationDegrees: Double = 88

    public init() {}

    /// 画面四角在屏幕上的位置,单位点。
    ///
    /// 顺序:左下、右下、右上、左上。
    public func corners(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        recession: Double,
        screenSize: CGSize
    ) -> [CGPoint] {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        let travel = max(startAngle - currentAngle, 0)
        let separation = min(recession * travel, maxSeparationDegrees) * .pi / 180

        // 世界坐标系里的眼睛,铰链在原点。
        let reach = height * viewingDistanceRatio + height / 2 * cos(start)
        let rise = height / 2 * sin(start)

        // 同一只眼睛,换成沿玻璃量与离玻璃量。
        let along = reach * cos(current) + rise * sin(current)
        // 下限保证不会投影到平面之后(那会让画面整个翻掉)。
        let depth = max(reach * sin(current) - rise * cos(current), height / 10)

        let half = width / 2
        func project(_ x: Double, _ y: Double) -> CGPoint {
            let scale = depth / (depth + y * sin(separation))
            return CGPoint(
                x: half + (x - half) * scale,
                y: along + (y * cos(separation) - along) * scale
            )
        }
        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }

    /// 纯函数:给一组参数,算出投影后画面相对屏幕的**纵向压缩比**(0...1)。
    ///
    /// 效果本身没有"数值化"的呈现,抽屉块用这个值画一个会随盖角收缩的示意条,
    /// 让用户在小尺寸下也能看出透视在发生什么。与 `corners` 同源推导。
    public func verticalCompression(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        recession: Double,
        screenSize: CGSize
    ) -> Double {
        guard screenSize.height > 0 else { return 1 }
        let projected = corners(
            startAngle: startAngle,
            currentAngle: currentAngle,
            viewingDistanceRatio: viewingDistanceRatio,
            recession: recession,
            screenSize: screenSize
        )
        // 远边(索引 2/3)相对近边(索引 0/1)的高度差,就是可见的压缩。
        let near = (projected[0].y + projected[1].y) / 2
        let far = (projected[2].y + projected[3].y) / 2
        let ratio = (far - near) / Double(screenSize.height)
        return min(max(ratio, 0), 1)
    }
}

/// 塑造一帧画面的设置。
///
/// 上游 Mac-Duo 的 `DepthTuning`,原样移植。
public struct DepthTuning: Sendable, Equatable {
    /// 眼睛到屏幕中部的距离,以屏幕高度为单位。
    public var viewingDistance: Double = 2.7
    /// 盖子每合上 1 度,画面在空间中转过的度数。1 表示画面在房间里保持不动。
    public var recession: Double = 2
    /// 铰链边模糊量占远端模糊量的比例。
    public var blurEvenness: Double = 0.4
    /// 变暗达到满强度的高度占比。
    public var dimReach: Double = 0.7
    /// 满效果时的高斯模糊半径,单位点。
    public var maxBlurRadius: Double = 55
    /// 模糊满强度处的黑色叠加强度,0...1。
    public var maxDim: Double = 0.4

    public init(
        viewingDistance: Double = 2.7,
        recession: Double = 2,
        blurEvenness: Double = 0.4,
        dimReach: Double = 0.7,
        maxBlurRadius: Double = 55,
        maxDim: Double = 0.4
    ) {
        self.viewingDistance = viewingDistance
        self.recession = recession
        self.blurEvenness = blurEvenness
        self.dimReach = dimReach
        self.maxBlurRadius = maxBlurRadius
        self.maxDim = maxDim
    }
}
