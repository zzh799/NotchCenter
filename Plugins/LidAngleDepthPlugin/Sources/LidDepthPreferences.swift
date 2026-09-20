import Foundation
import NotchCenterKit

/// 合盖效果的用户设置。
///
/// **与上游的差异(D4)**:上游 Mac-Duo 的 `Preferences` 直接写 `UserDefaults`,
/// 那在本仓库是红线——插件状态一律走注入的 `StateStore`(按 pluginID 隔离、
/// 原子写、核心里不暴露路径)。这里保持同一份键与同一组工厂默认值,只换落盘通道,
/// 因此观感默认值与上游一致(唯一例外是总开关 `isEnabled` 默认关闭,见 `Factory`)。
@MainActor
public final class LidDepthPreferences: ObservableObject {

    private enum Key {
        static let isEnabled = "isEnabled"
        static let thresholdAngle = "thresholdAngle"
        static let blurSpan = "blurSpan"
        static let maxBlurRadius = "maxBlurRadius"
        static let maxDim = "maxDim"
        static let viewingDistance = "viewingDistance"
        static let recession = "recession"
        static let blurEvenness = "blurEvenness"
        static let dimReach = "dimReach"
        static let isLivePicture = "isLivePicture"
        static let showsAngleInMenuBar = "showsAngleInMenuBar"
    }

    /// 工厂默认值。除 `isEnabled` 外与上游 `Preferences.factory` 逐项一致,保证开箱观感相同。
    ///
    /// `isEnabled` 刻意改为 `false`(上游为 `true`):效果是一层盖满内置屏的全屏覆盖且需要
    /// 屏幕录制权限,首次启动就默认接管过于突兀,改为由用户在控制台或设置里主动开启。
    private enum Factory {
        static let isEnabled = false
        static let thresholdAngle = 90.0
        static let blurSpan = 60.0
        static let maxBlurRadius = 135.0
        static let maxDim = 1.0
        static let viewingDistance = 6.0
        static let recession = 1.0
        static let blurEvenness = 0.0
        static let dimReach = 0.5
        static let isLivePicture = true
        static let showsAngleInMenuBar = false
    }

    private let stateStore: StateStore

    /// 总开关。
    @Published public var isEnabled: Bool { didSet { persist(isEnabled, Key.isEnabled) } }
    /// 合到此角度以下就开始效果(度)。
    @Published public var thresholdAngle: Double { didSet { persist(thresholdAngle, Key.thresholdAngle) } }
    /// 阈值往下多少度内模糊到达满强度。
    @Published public var blurSpan: Double { didSet { persist(blurSpan, Key.blurSpan) } }
    /// 满效果时的高斯模糊半径(点)。
    @Published public var maxBlurRadius: Double { didSet { persist(maxBlurRadius, Key.maxBlurRadius) } }
    /// 模糊满强度处的黑色叠加强度,0...1。
    @Published public var maxDim: Double { didSet { persist(maxDim, Key.maxDim) } }
    /// 眼睛到屏幕中部的距离,以屏幕高度为单位。
    @Published public var viewingDistance: Double { didSet { persist(viewingDistance, Key.viewingDistance) } }
    /// 盖子每合 1 度画面转过的度数。1 表示画面在房间里保持不动。
    @Published public var recession: Double { didSet { persist(recession, Key.recession) } }
    /// 铰链边模糊量占远端模糊量的比例。
    @Published public var blurEvenness: Double { didSet { persist(blurEvenness, Key.blurEvenness) } }
    /// 变暗达到满强度的高度占比。
    @Published public var dimReach: Double { didSet { persist(dimReach, Key.dimReach) } }
    /// 用实时流(需要屏幕录制权限);关闭则用合盖瞬间的单帧静图。
    @Published public var isLivePicture: Bool { didSet { persist(isLivePicture, Key.isLivePicture) } }
    /// 是否把盖角显示在状态栏菜单标题上。
    @Published public var showsAngleInMenuBar: Bool { didSet { persist(showsAngleInMenuBar, Key.showsAngleInMenuBar) } }

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
        // `didSet` 在 init 里不触发,所以不会有"读回来又写回去"的抖动。
        isEnabled = stateStore.object(Bool.self, forKey: Key.isEnabled) ?? Factory.isEnabled
        thresholdAngle = stateStore.object(Double.self, forKey: Key.thresholdAngle) ?? Factory.thresholdAngle
        blurSpan = stateStore.object(Double.self, forKey: Key.blurSpan) ?? Factory.blurSpan
        maxBlurRadius = stateStore.object(Double.self, forKey: Key.maxBlurRadius) ?? Factory.maxBlurRadius
        maxDim = stateStore.object(Double.self, forKey: Key.maxDim) ?? Factory.maxDim
        viewingDistance = stateStore.object(Double.self, forKey: Key.viewingDistance) ?? Factory.viewingDistance
        recession = stateStore.object(Double.self, forKey: Key.recession) ?? Factory.recession
        blurEvenness = stateStore.object(Double.self, forKey: Key.blurEvenness) ?? Factory.blurEvenness
        dimReach = stateStore.object(Double.self, forKey: Key.dimReach) ?? Factory.dimReach
        isLivePicture = stateStore.object(Bool.self, forKey: Key.isLivePicture) ?? Factory.isLivePicture
        showsAngleInMenuBar = stateStore.object(Bool.self, forKey: Key.showsAngleInMenuBar) ?? Factory.showsAngleInMenuBar
    }

    /// 合成一帧所需的调节参数。
    public var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: viewingDistance,
            recession: recession,
            blurEvenness: blurEvenness,
            dimReach: dimReach,
            maxBlurRadius: maxBlurRadius,
            maxDim: maxDim
        )
    }

    /// 恢复到上游同款出厂值。
    public func resetToFactoryDefaults() {
        isEnabled = Factory.isEnabled
        thresholdAngle = Factory.thresholdAngle
        blurSpan = Factory.blurSpan
        maxBlurRadius = Factory.maxBlurRadius
        maxDim = Factory.maxDim
        viewingDistance = Factory.viewingDistance
        recession = Factory.recession
        blurEvenness = Factory.blurEvenness
        dimReach = Factory.dimReach
        isLivePicture = Factory.isLivePicture
        showsAngleInMenuBar = Factory.showsAngleInMenuBar
    }

    private func persist<T: Codable>(_ value: T, _ key: String) {
        try? stateStore.setObject(value, forKey: key)
    }
}
