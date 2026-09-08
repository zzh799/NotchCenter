import SwiftUI

// MARK: - 峰谷阶段色的 SwiftUI 表达（全插件唯一转换点）
//
// `PeakClockLogic` 只持逻辑层色分量（Foundation，便于单测），这里统一转成
// SwiftUI `Color`：块视图的峰/谷图标与浮窗的表盘/时钟/图例共用同一对颜色，
// 禁止再各自 `Color(red:)` 转换（历史上同一文件内曾出现两份一字不差的重复定义）。

enum PeakClockPalette {
    /// 峰时（红 #e5484d）。
    static let peak = Color(
        red: PeakClockLogic.peakColor.red,
        green: PeakClockLogic.peakColor.green,
        blue: PeakClockLogic.peakColor.blue
    )
    /// 谷时（绿 #2e9e5b）。
    static let offPeak = Color(
        red: PeakClockLogic.offPeakColor.red,
        green: PeakClockLogic.offPeakColor.green,
        blue: PeakClockLogic.offPeakColor.blue
    )
}
