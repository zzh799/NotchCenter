import CoreGraphics
import Foundation
import Testing

@testable import ClockPlugin

// MARK: - 指针时钟块纯逻辑回归
//
// 覆盖三块可测逻辑（不渲染 SwiftUI、不依赖 AppKit）：指针角度的连续推进、
// 整分刷新锚点、比例几何与探针。锚点用 2026-09-20 16:26 —— 参考截图拍下的
// 那一刻：时针落在 4 与 5 之间的 133°、分针在 158°（26 分），两针同指向右下。

/// 固定时区的公历：避免测试受运行环境影响。
private func shanghaiCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.locale = Locale(identifier: "zh_CN")
    return calendar
}

private func shanghaiDate(
    _ year: Int, _ month: Int, _ day: Int,
    hour: Int, minute: Int, second: Int = 0
) -> Date {
    shanghaiCalendar().date(from: DateComponents(
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second))!
}

/// 默认格下的 1×1 物理尺寸；也是本块声明的三档值。
private let sizeOneByOne = CGSize(width: 150, height: 120)

struct ClockFaceGeometryTests {

    // MARK: 指针角度

    @Test func anglesMatchTheReferenceScreenshotMoment() {
        // 16:26:20 → 时针 4 + 26.33/60 小时 = 133.17°，分针 26.33/60 圈 = 158.0°。
        let angles = ClockHandAngles.angles(
            for: shanghaiDate(2026, 9, 20, hour: 16, minute: 26, second: 20),
            calendar: shanghaiCalendar())

        #expect(abs(angles.hour - 133.166_666) < 0.001)
        #expect(abs(angles.minute - 158.0) < 0.001)
    }

    @Test func bothHandsPointAtTwelveAtNoon() {
        let angles = ClockHandAngles.angles(
            for: shanghaiDate(2026, 9, 20, hour: 12, minute: 0),
            calendar: shanghaiCalendar())

        #expect(angles.hour == 0)
        #expect(angles.minute == 0)
    }

    @Test func hourHandAdvancesWithMinutesNotOnlyOnTheHour() {
        let calendar = shanghaiCalendar()
        let atFour = ClockHandAngles.angles(
            for: shanghaiDate(2026, 9, 20, hour: 4, minute: 0), calendar: calendar)
        let atHalfPastFour = ClockHandAngles.angles(
            for: shanghaiDate(2026, 9, 20, hour: 4, minute: 30), calendar: calendar)

        // 时针连续推进（不是整点跳）：半小时恰好走 15°。
        #expect(atFour.hour == 120)
        #expect(abs(atHalfPastFour.hour - 135) < 0.001)
        #expect(atHalfPastFour.minute == 180)
    }

    @Test func handsWrapTowardsMidnightWithoutNegativeAngles() {
        // 11:59:30 → 时针 359.75°、分针 357°：越过 360 必须回到 [0, 360)。
        let angles = ClockHandAngles.angles(
            for: shanghaiDate(2026, 9, 20, hour: 23, minute: 59, second: 30),
            calendar: shanghaiCalendar())

        #expect(abs(angles.hour - 359.75) < 0.001)
        #expect(abs(angles.minute - 357.0) < 0.001)
        #expect(angles.hour >= 0 && angles.hour < 360)
    }

    // MARK: 整分刷新锚点

    @Test func waitsUntilTheNextFullMinute() {
        let calendar = shanghaiCalendar()

        #expect(abs(ClockHandAngles.secondsUntilNextMinute(
            after: shanghaiDate(2026, 9, 20, hour: 16, minute: 26, second: 20),
            calendar: calendar) - 40) < 0.001)

        // 正落在整分上：等满一整分钟，不是立刻返回。
        #expect(abs(ClockHandAngles.secondsUntilNextMinute(
            after: shanghaiDate(2026, 9, 20, hour: 16, minute: 26),
            calendar: calendar) - 60) < 0.001)

        // 分针跳变前一刻：等待时间趋近 0，但下限 0.25s 兜住病态紧密循环。
        let justBefore = shanghaiDate(2026, 9, 20, hour: 16, minute: 26, second: 59).addingTimeInterval(0.9)
        let wait = ClockHandAngles.secondsUntilNextMinute(after: justBefore, calendar: calendar)
        #expect(wait >= 0.25 && wait <= 0.5)
    }

    // MARK: 比例几何

    @Test func geometryAtOneByOneIsCenteredOnTheShortSide() {
        let snapshot = ClockFaceSnapshot(
            date: shanghaiDate(2026, 9, 20, hour: 16, minute: 26),
            size: sizeOneByOne,
            calendar: shanghaiCalendar(),
            locale: Locale(identifier: "zh_CN"))

        // 表盘内切于短边（120）的 0.884；宽出的 30pt 是卡片两侧留白。
        #expect(abs(snapshot.diameter - 106.08) < 0.001)
        let faceRect = snapshot.faceRect
        #expect(abs(faceRect.midX - sizeOneByOne.width / 2) < 0.001)
        #expect(abs(faceRect.midY - sizeOneByOne.height / 2) < 0.001)
        #expect(abs(faceRect.width - snapshot.diameter) < 0.001)
    }

    @Test func everyMetricScalesWithTheDiameter() {
        // 用户把格子调大（2 倍）→ 全表盘等比放大，没有一个度量走偏。
        let small = ClockFaceSnapshot(
            date: Date(timeIntervalSince1970: 0),
            size: sizeOneByOne,
            calendar: shanghaiCalendar(),
            locale: Locale(identifier: "zh_CN"))
        let large = ClockFaceSnapshot(
            date: Date(timeIntervalSince1970: 0),
            size: CGSize(width: 300, height: 240),
            calendar: shanghaiCalendar(),
            locale: Locale(identifier: "zh_CN"))

        #expect(abs(large.diameter - small.diameter * 2) < 0.001)
        #expect(abs(large.tickOuterRadius - small.tickOuterRadius * 2) < 0.001)
        #expect(abs(large.numeralFontSize - small.numeralFontSize * 2) < 0.001)
        #expect(abs(large.minuteHandLength - small.minuteHandLength * 2) < 0.001)
        #expect(abs(large.hubStrokeWidth - small.hubStrokeWidth * 2) < 0.001)
    }

    // MARK: 表盘内部不越界（探针只声明外接矩形的依据）

    @Test func numeralsStayClearOfTheTickRing() {
        let snapshot = ClockFaceSnapshot(
            date: Date(timeIntervalSince1970: 0),
            size: sizeOneByOne,
            calendar: shanghaiCalendar(),
            locale: Locale(identifier: "zh_CN"))

        // 数字外缘（环心 + 半个字高，字高按保守的 0.75em 估）必须落在刻度环内缘里，
        // 否则数字会压上刻度——这正是"整张脸只声明一个外接矩形探针"的前提。
        let numeralOuterEdge = snapshot.numeralRadius + snapshot.numeralFontSize * 0.75 / 2
        #expect(numeralOuterEdge < snapshot.tickInnerRadius)
        // 刻度环外缘与两针也都留在表盘圆内。
        #expect(snapshot.tickOuterRadius < snapshot.diameter / 2)
        #expect(snapshot.minuteHandLength < snapshot.diameter / 2)
        #expect(snapshot.hourHandLength < snapshot.minuteHandLength)
        // 数字环心本身也必须落在刻度环内缘以内（不是"数字环骑在刻度上"）。
        #expect(snapshot.numeralRadius < snapshot.tickInnerRadius)
    }

    @Test func probeRectMatchesTheViewAndFitsTheDeclaredMinimum() {
        let minimum = sizeOneByOne
        let rect = ClockFaceMetrics.faceRect(for: minimum)

        // 探针盒 = 声明的最小尺寸内容盒：外接矩形必须完整落在里面（否则最小尺寸下
        // 内容会伸到邻居块上）。
        #expect(rect.minX >= 0 && rect.minY >= 0)
        #expect(rect.maxX <= minimum.width && rect.maxY <= minimum.height)

        // 探针与视图同源：同一个尺寸下两者必须给出同一个矩形。
        let snapshot = ClockFaceSnapshot(
            date: Date(timeIntervalSince1970: 0),
            size: minimum,
            calendar: shanghaiCalendar(),
            locale: Locale(identifier: "zh_CN"))
        #expect(snapshot.faceRect == rect)
    }

    // MARK: 无障碍用的数字时间

    @Test func digitalTimeFollowsLocaleHourCycle() {
        let date = shanghaiDate(2026, 9, 20, hour: 16, minute: 26)
        let calendar = shanghaiCalendar()

        let chinese = ClockFaceSnapshot(
            date: date, size: sizeOneByOne, calendar: calendar,
            locale: Locale(identifier: "zh_CN"))
        #expect(chinese.digitalTime == "16:26")

        // en-US 走 12 小时制；ICU 的 AM/PM 前可能是窄不换行空格，故不断言整串。
        let english = ClockFaceSnapshot(
            date: date, size: sizeOneByOne, calendar: calendar,
            locale: Locale(identifier: "en_US"))
        #expect(english.digitalTime.contains("4:26"))
        #expect(english.digitalTime.uppercased().contains("PM"))
    }
}
