import Foundation

/// 把传感器 10 Hz 的阶梯读数变成**按屏幕刷新率平滑变化**的值。
///
/// 上游 Mac-Duo 的 `CriticallyDampedSpring`,原样移植。
///
/// 半隐式欧拉在 `frequency * dt < 2` 时稳定,故调用方必须夹住 `dt`。
public struct CriticallyDampedSpring {

    /// 当前值。
    public var value: Double
    /// 当前速度。
    public var velocity: Double = 0

    /// 弧度/秒。越高跟随越快、平滑越少。
    public var frequency: Double = 16

    public init(value: Double = 0) {
        self.value = value
    }

    /// 朝 `target` 推进一步。
    public mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    /// 直接把值钉到 `newValue` 并清速度(合盖动作刚开始时用)。
    public mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}
