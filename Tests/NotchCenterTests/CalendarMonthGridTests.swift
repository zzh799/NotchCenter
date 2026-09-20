import Foundation
import Testing

@testable import CalendarPlugin

// MARK: - 日历块纯逻辑回归
//
// 覆盖三块可测逻辑（不渲染 SwiftUI、不依赖 AppKit）：月网格与前导空槽、
// 农历中文名映射、版式常量与今日圆的分配规则。锚点用 2026-09-20（参考截图
// 那一天：周日、八月初十，据此锁死周首日与农历两处映射）。

/// 固定时区 / locale 的日历，避免测试受运行环境影响。
private func shanghaiGregorian(firstWeekday: Int? = nil) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.locale = Locale(identifier: "zh_CN")
    if let firstWeekday { calendar.firstWeekday = firstWeekday }
    return calendar
}

private func shanghaiDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    shanghaiGregorian().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private let size150 = CGSize(width: 150, height: 150)

struct CalendarMonthGridTests {
    @Test func september2026HasSundayFirstLeadingBlanksAndFiveRows() {
        let calendar = shanghaiGregorian()
        let date = shanghaiDate(2026, 9, 20)
        let grid = CalendarMonthBuilder.grid(for: date, calendar: calendar, today: date)

        // 2026-09-01 是周二；zh-CN 首日周日 → 前导两格空。
        #expect(grid.rowCount == 5)
        #expect(grid.weeks[0][0] == nil)
        #expect(grid.weeks[0][1] == nil)
        #expect(grid.weeks[0][2] == CalendarDayCell(day: 1, isToday: false))
        // 9-20 是周日且为今天 → 第四行第一列。
        #expect(grid.weeks[3][0] == CalendarDayCell(day: 20, isToday: true))
        #expect(grid.weeks[3][1] == CalendarDayCell(day: 21, isToday: false))
        // 月末补空格：30 天 + 2 前导 = 32 槽 → 补到 35。
        #expect(grid.weeks[4][6] == nil)
    }

    @Test func august2026NeedsSixRows() {
        let calendar = shanghaiGregorian()
        let date = shanghaiDate(2026, 8, 1)
        let grid = CalendarMonthBuilder.grid(for: date, calendar: calendar, today: date)

        #expect(grid.rowCount == 6)
        #expect(grid.weeks[0][6] == CalendarDayCell(day: 1, isToday: true))
        #expect(grid.weeks[5][0] == CalendarDayCell(day: 30, isToday: false))
    }

    @Test func todayInAnotherMonthMarksNothing() {
        let calendar = shanghaiGregorian()
        let grid = CalendarMonthBuilder.grid(
            for: shanghaiDate(2026, 8, 1),
            calendar: calendar,
            today: shanghaiDate(2026, 9, 20))

        #expect(!grid.weeks.flatMap { $0 }.contains { $0?.isToday == true })
    }

    @Test func firstWeekdayFollowsCalendarSetting() {
        let date = shanghaiDate(2026, 9, 20)
        let mondayFirst = CalendarMonthBuilder.grid(
            for: date,
            calendar: shanghaiGregorian(firstWeekday: 2),
            today: date)
        // 周一起始时，9-01（周二）前导只剩一格空。
        #expect(mondayFirst.weeks[0][0] == nil)
        #expect(mondayFirst.weeks[0][1] == CalendarDayCell(day: 1, isToday: false))
    }

    @Test func weekdaySymbolsRotateWithFirstWeekday() {
        let sundayFirst = CalendarMonthBuilder.orderedWeekdaySymbols(calendar: shanghaiGregorian())
        #expect(sundayFirst == ["日", "一", "二", "三", "四", "五", "六"])

        let mondayFirst = CalendarMonthBuilder.orderedWeekdaySymbols(
            calendar: shanghaiGregorian(firstWeekday: 2))
        #expect(mondayFirst == ["一", "二", "三", "四", "五", "六", "日"])
    }

    @Test func monthTitleUsesLocaleTemplate() {
        let date = shanghaiDate(2026, 9, 20)
        let zh = CalendarMonthBuilder.monthTitle(
            for: date, locale: Locale(identifier: "zh_CN"), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(zh == "9月")

        let en = CalendarMonthBuilder.monthTitle(
            for: date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(en == "Sep")
    }

    @Test func weekdayNameIsLocalized() {
        let calendar = shanghaiGregorian()
        #expect(CalendarMonthBuilder.weekdayName(for: shanghaiDate(2026, 9, 20), calendar: calendar) == "星期日")
    }
}

struct CalendarLayoutMetricsTests {
    /// 四段纵向分配必须刚好等于 150：内边距 10 + 头部 15 + 间隙 2 + 星期行 13
    /// + 网格 100。上下边距相等是「六行月份不压内部边距」的算法保证。
    @Test func verticalBandsFillTheBlockExactly() {
        #expect(CalendarMonthMetrics.headerRect(for: size150).minY == 10)
        #expect(CalendarMonthMetrics.headerRect(for: size150).height == 15)
        #expect(CalendarMonthMetrics.weekdayRect(for: size150).minY == 27)
        #expect(CalendarMonthMetrics.weekdayRect(for: size150).maxY == 40)
        #expect(CalendarMonthMetrics.gridContentHeight(for: size150) == 100)
        // 网格区带并入底部内边距 → 恰好触底。
        #expect(CalendarMonthMetrics.gridRect(for: size150).maxY == 150)
    }

    @Test func rowHeightSplitsRemainingHeightByRowCount() {
        #expect(CalendarMonthMetrics.rowHeight(for: size150, rowCount: 5) == 20)
        #expect(abs(CalendarMonthMetrics.rowHeight(for: size150, rowCount: 6) - 100.0 / 6) < 0.0001)
        // 任意行数下 行高 × 行数 都铺满网格内容高 → 无底部留白。
        for rows in 4...6 {
            let total = CalendarMonthMetrics.rowHeight(for: size150, rowCount: rows) * CGFloat(rows)
            #expect(abs(total - CalendarMonthMetrics.gridContentHeight(for: size150)) < 0.0001)
        }
    }

    @Test func todayCircleShrinksWithRowHeight() {
        let fiveRows = CalendarMonthMetrics.todayCircleDiameter(for: size150, rowCount: 5)
        let sixRows = CalendarMonthMetrics.todayCircleDiameter(for: size150, rowCount: 6)

        #expect(fiveRows == 18)
        #expect(sixRows < fiveRows)
        // 圆必须留在行内（行高 − 2pt 余量），否则六行月份会压到相邻行。
        for rows in 5...6 {
            let rowHeight = CalendarMonthMetrics.rowHeight(for: size150, rowCount: rows)
            #expect(CalendarMonthMetrics.todayCircleDiameter(for: size150, rowCount: rows) <= rowHeight - 2)
        }
    }
}

struct ChineseLunarFormatterTests {
    @Test func anchorsMatchKnownDates() {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        // 参考截图那天：2026-09-20 = 农历八月初十、丙午年。
        let anchor = shanghaiDate(2026, 9, 20)
        #expect(ChineseLunarFormatter.monthDayName(for: anchor, chineseCalendar: chinese) == "八月初十")
        #expect(ChineseLunarFormatter.fullName(for: anchor, chineseCalendar: chinese) == "丙午年八月初十")

        // 春节当天为 正月初一；2026-01-10 仍属乙巳年冬月（换年由系统按春节切）。
        #expect(
            ChineseLunarFormatter.monthDayName(
                for: shanghaiDate(2026, 2, 17), chineseCalendar: chinese) == "正月初一")
        #expect(
            ChineseLunarFormatter.fullName(
                for: shanghaiDate(2026, 1, 10), chineseCalendar: chinese) == "乙巳年冬月廿二")
    }

    @Test func dayNamesCoverAllThirtyDays() {
        #expect(ChineseLunarFormatter.dayNames.count == 30)
        #expect(ChineseLunarFormatter.monthDayName(month: 8, day: 1) == "八月初一")
        #expect(ChineseLunarFormatter.monthDayName(month: 8, day: 10) == "八月初十")
        #expect(ChineseLunarFormatter.monthDayName(month: 8, day: 11) == "八月十一")
        #expect(ChineseLunarFormatter.monthDayName(month: 8, day: 20) == "八月二十")
        #expect(ChineseLunarFormatter.monthDayName(month: 8, day: 21) == "八月廿一")
        #expect(ChineseLunarFormatter.monthDayName(month: 8, day: 30) == "八月三十")
    }

    @Test func leapMonthAndMonthNamesAreCorrect() {
        #expect(ChineseLunarFormatter.monthNames.count == 12)
        #expect(ChineseLunarFormatter.monthNames.first == "正月")
        #expect(ChineseLunarFormatter.monthNames.last == "腊月")
        #expect(ChineseLunarFormatter.monthDayName(month: 6, day: 1, isLeapMonth: true) == "闰六月初一")
    }

    /// 越界输入不得崩（`.chinese` 日历在某些年份可能给出 13 月或 31 日）。
    @Test func outOfRangeInputFallsBackToNumbers() {
        #expect(ChineseLunarFormatter.monthDayName(month: 0, day: 0) == "0/0")
        #expect(ChineseLunarFormatter.monthDayName(month: 13, day: 30) == "13/30")
        #expect(ChineseLunarFormatter.cycleYearName(0) == "")
    }
}
