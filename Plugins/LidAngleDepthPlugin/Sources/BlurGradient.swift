import Foundation

/// 给定高度上画面**有多虚**、**损失了多少光**。高度 0 在铰链边,1 在远端。
///
/// 上游 Mac-Duo 的 `BlurGradient`,原样移植。
public struct BlurGradient {

    /// 合盖行程的指数。大于 1 表示起手慢。
    public var blurCurve: Double = 1.6

    /// 变暗行程的指数。
    public var dimCurve: Double = 0.7

    /// 铰链边的变暗量,占远端变暗量的比例。
    public var dimHingeFloor: Double = 0.2

    public init() {}

    public func blurStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), blurCurve)
    }

    public func dimStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), dimCurve)
    }
}
