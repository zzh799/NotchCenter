import Metal
import QuartzCore
import simd

/// 合盖瞬间画面四角的投影。
///
/// 上游把这个计算放在 `DepthOverlay` 里,这里抽成纯函数——抽屉块的示意条也要用
/// 同一个投影,两边必须同源,否则"预览"与真实效果会不一致。
enum DepthProjection {

    /// 给一次瞬时状态,算出画面四角(点)。
    static func corners(
        startAngle: Double,
        currentAngle: Double,
        tuning: DepthTuning,
        screenSize: CGSize,
        geometry: DepthGeometry = DepthGeometry()
    ) -> [CGPoint] {
        geometry.corners(
            startAngle: startAngle,
            currentAngle: currentAngle,
            viewingDistanceRatio: tuning.viewingDistance,
            recession: tuning.recession,
            screenSize: screenSize
        )
    }
}
