import CoreGraphics
import Foundation

// MARK: - 表盘几何（比例源自参考截图实测）
//
// 所有尺寸都是**表盘直径 D 的比例**，不是绝对点值：宿主允许用户改格子尺寸
// （单元宽 20–280），同一块 1×1 的物理尺寸随格漂移，等比是唯一稳定的解——
// 表盘在任意物理尺寸下都只是同一张脸的缩放，没有版式分支。
//
// 比值取自参考截图（366×362 @2x，即 183×181pt）：表盘圆 D = 290px（145pt）、
// 卡片 164pt；刻度环 r 129–140px、粗 2px；数字环 r 105px、em ≈ 34.3px；
// 分针 122px、时针 80px、针宽 10px；中心环外径 19px、环宽 6px。
// 测量过程与配色取舍见 docs/agent-notes/proposed/2026-09-20-clock-analog-block.md。

/// 表盘比例表与纯几何推导。探针（`ClockPlugin.blocks`）与视图
/// （`ClockFaceSnapshot`）同源取用，避免"同一事实两处写"。
enum ClockFaceMetrics {
    /// 表盘直径 / 内容盒短边（截图 145 / 164 = 0.884）。
    static let diameterRatio: CGFloat = 0.884
    /// 刻度环外缘 / 内缘半径（截图 140 / 129 px）。
    static let tickOuterRadiusRatio: CGFloat = 0.4828
    static let tickInnerRadiusRatio: CGFloat = 0.4448
    /// 刻度粗细（截图 2px）。
    static let tickWidthRatio: CGFloat = 0.0069
    /// 数字环中心半径（截图 105px）。
    static let numeralRadiusRatio: CGFloat = 0.3621
    /// 数字字号（截图 cap 高 25px；SF 的 cap/em ≈ 0.729）。
    static let numeralFontSizeRatio: CGFloat = 0.118
    /// 指针长度（截图分针 122px / 时针 80px）与针宽（10px）。
    static let hourHandLengthRatio: CGFloat = 0.2759
    static let minuteHandLengthRatio: CGFloat = 0.4207
    static let handWidthRatio: CGFloat = 0.0345
    /// 中心环外径（19px）与环宽（6px）——截图中心是**孔**不是实心点。
    static let hubOuterDiameterRatio: CGFloat = 0.0655
    static let hubStrokeWidthRatio: CGFloat = 0.0207

    /// 表盘直径：内切于内容盒短边（宽出的部分即卡片两侧留白）。
    static func diameter(for size: CGSize) -> CGFloat {
        max(min(size.width, size.height), 0) * diameterRatio
    }

    /// 表盘外接矩形（块本地坐标，原点 = 内容区左上，居中）。打包期遮挡校验的
    /// 探针与视图都用它——表盘是圆，外接矩形就是内容可达边界。
    static func faceRect(for size: CGSize) -> CGRect {
        let diameter = diameter(for: size)
        return CGRect(
            x: (size.width - diameter) / 2,
            y: (size.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
    }
}

// MARK: - 指针角度（纯函数，ClockFaceGeometryTests 覆盖）

enum ClockHandAngles {
    /// 时/分针角度（度，0 = 12 点方向，顺时针）。
    ///
    /// 两针都按秒级精度**连续**推进：时针不是整点跳，而是 4:26 时落在 4 与 5
    /// 之间（133°）——与截图（16:26 拍的）实测一致。
    static func angles(for date: Date, calendar: Calendar) -> (hour: Double, minute: Double) {
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = Double(parts.hour ?? 0)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1_000_000_000
        let minuteProgress = (minute + second / 60) / 60
        let hourProgress = (hour.truncatingRemainder(dividingBy: 12) + minuteProgress) / 12
        return (hour: hourProgress * 360, minute: minuteProgress * 360)
    }

    /// 到下一个整分的秒数（块视图的刷新锚点）。下限 0.25s 防病态紧密循环：
    /// 恰在整分上取值时剩余秒数会落到 0 附近。
    static func secondsUntilNextMinute(after date: Date, calendar: Calendar) -> TimeInterval {
        let parts = calendar.dateComponents([.second, .nanosecond], from: date)
        let second = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1_000_000_000
        return max(60 - second, 0.25)
    }
}

// MARK: - 渲染快照（`date` + 块尺寸的纯函数，无隐藏状态）

/// 一次渲染所需的全部派生量：比例换算后的点值与指针角度。视图只读它，
/// 测试也直接断言它（不渲染 SwiftUI 即可覆盖角度与全部尺寸）。
struct ClockFaceSnapshot: Equatable {
    let size: CGSize
    let diameter: CGFloat
    let tickOuterRadius: CGFloat
    let tickInnerRadius: CGFloat
    let tickWidth: CGFloat
    let numeralRadius: CGFloat
    let numeralFontSize: CGFloat
    let hourHandLength: CGFloat
    let minuteHandLength: CGFloat
    let handWidth: CGFloat
    let hubOuterDiameter: CGFloat
    let hubStrokeWidth: CGFloat
    /// 指针角度（度，0 = 12 点方向，顺时针）。
    let hourAngle: Double
    let minuteAngle: Double
    /// 无障碍文案用的数字时间（跟随 locale 的 12/24 小时制）。
    let digitalTime: String

    var faceRect: CGRect { ClockFaceMetrics.faceRect(for: size) }

    init(date: Date, size: CGSize, calendar: Calendar, locale: Locale) {
        let diameter = ClockFaceMetrics.diameter(for: size)
        self.size = size
        self.diameter = diameter
        tickOuterRadius = diameter * ClockFaceMetrics.tickOuterRadiusRatio
        tickInnerRadius = diameter * ClockFaceMetrics.tickInnerRadiusRatio
        tickWidth = diameter * ClockFaceMetrics.tickWidthRatio
        numeralRadius = diameter * ClockFaceMetrics.numeralRadiusRatio
        numeralFontSize = diameter * ClockFaceMetrics.numeralFontSizeRatio
        hourHandLength = diameter * ClockFaceMetrics.hourHandLengthRatio
        minuteHandLength = diameter * ClockFaceMetrics.minuteHandLengthRatio
        handWidth = diameter * ClockFaceMetrics.handWidthRatio
        hubOuterDiameter = diameter * ClockFaceMetrics.hubOuterDiameterRatio
        hubStrokeWidth = diameter * ClockFaceMetrics.hubStrokeWidthRatio

        let angles = ClockHandAngles.angles(for: date, calendar: calendar)
        hourAngle = angles.hour
        minuteAngle = angles.minute
        digitalTime = Self.digitalTime(for: date, calendar: calendar, locale: locale)
    }

    /// 数字时间：`j:mm` 模板让 12/24 小时制跟随 locale（zh-Hans 出 16:26，
    /// en-US 出 4:26 PM），表盘上的 1–12 数字不受影响。
    private static func digitalTime(for date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }
}
