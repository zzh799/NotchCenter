import CoreGraphics
import Foundation

// MARK: - 版式常量（视图与打包期探针的唯一同源）

/// 150×150 固定内容盒的纵向四段分配：内边距 10 → 头部 15 → 间隙 2 → 星期行 13
/// → 网格 100（合计 150）。网格纵向均分剩余高度（5 行 20pt / 6 行 16.67pt），
/// 因此任意月份上下边距都等于 10pt。`CalendarPlugin.monthLayoutProbes` 按本组
/// 常量推导探针矩形，改动布局必须同步。
enum CalendarMonthMetrics {
    static let columnCount = 7
    /// 块内边距（值取 `NotchTokens.Space.cardPadding`，此处不引 Kit 以保持纯值可测）。
    static let padding: CGFloat = 10
    static let headerHeight: CGFloat = 15
    static let headerToWeekdayGap: CGFloat = 2
    static let weekdayHeight: CGFloat = 13
    static let headerFontSize: CGFloat = 11
    static let lunarFontSize: CGFloat = 9
    static let weekdayFontSize: CGFloat = 9
    static let dayFontSize: CGFloat = 10
    /// 今日白圆直径上限；六行月份按行高收缩（见 `todayCircleDiameter`）。
    static let todayCircleDiameterLimit: CGFloat = 19

    static func contentWidth(for size: CGSize) -> CGFloat {
        max(size.width - padding * 2, 0)
    }

    static func headerRect(for size: CGSize) -> CGRect {
        CGRect(x: padding, y: padding, width: contentWidth(for: size), height: headerHeight)
    }

    static func weekdayRect(for size: CGSize) -> CGRect {
        CGRect(
            x: padding,
            y: padding + headerHeight + headerToWeekdayGap,
            width: contentWidth(for: size),
            height: weekdayHeight)
    }

    /// 网格区带：**含底部内边距**（末段并入，让「块高小于总需求」精确判成越界）。
    static func gridRect(for size: CGSize) -> CGRect {
        let top = padding + headerHeight + headerToWeekdayGap + weekdayHeight
        return CGRect(
            x: padding,
            y: top,
            width: contentWidth(for: size),
            height: max(size.height - top, 0))
    }

    /// 网格内容高（区带去掉底部内边距）。
    static func gridContentHeight(for size: CGSize) -> CGFloat {
        max(gridRect(for: size).height - padding, 0)
    }

    static func rowHeight(for size: CGSize, rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return gridContentHeight(for: size) / CGFloat(rowCount)
    }

    /// 今日圆直径：留 2pt 行内余量，避免它与相邻行数字贴边。
    static func todayCircleDiameter(for size: CGSize, rowCount: Int) -> CGFloat {
        min(todayCircleDiameterLimit, max(rowHeight(for: size, rowCount: rowCount) - 2, 0))
    }
}

// MARK: - 月网格数据

/// 月网格中的一个日期格。
struct CalendarDayCell: Equatable {
    let day: Int
    let isToday: Bool
}

/// 一个月的网格：每行固定 7 槽，`nil` 槽表示不属于本月（月初前 / 月末后）。
struct CalendarMonthGrid: Equatable {
    let weeks: [[CalendarDayCell?]]
    var rowCount: Int { weeks.count }
}

// MARK: - 月网格构建

/// 月网格与星期头的纯函数构建（不碰 `Date()` 之外的环境，便于测试）。
enum CalendarMonthBuilder {
    /// 当月网格。周首日取 `calendar.firstWeekday`，`today` 落在同月时标记今日。
    static func grid(for date: Date, calendar: Calendar, today: Date) -> CalendarMonthGrid {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return CalendarMonthGrid(weeks: [])
        }

        let leading = (calendar.component(.weekday, from: firstOfMonth) - calendar.firstWeekday + 7) % 7
        let todayDay = calendar.isDate(firstOfMonth, equalTo: today, toGranularity: .month)
            ? calendar.component(.day, from: today)
            : nil

        var slots: [CalendarDayCell?] = Array(repeating: nil, count: leading)
        for day in dayRange {
            slots.append(CalendarDayCell(day: day, isToday: day == todayDay))
        }
        while slots.count % CalendarMonthMetrics.columnCount != 0 { slots.append(nil) }

        let weeks = stride(from: 0, to: slots.count, by: CalendarMonthMetrics.columnCount).map {
            Array(slots[$0..<($0 + CalendarMonthMetrics.columnCount)])
        }
        return CalendarMonthGrid(weeks: weeks)
    }

    /// 星期头符号：`veryShortStandaloneWeekdaySymbols` 恒按周日开头返回，
    /// 需按 `firstWeekday` 轮转后才能与网格列对齐（zh-CN 首日周日、en-US 同样）。
    static func orderedWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == CalendarMonthMetrics.columnCount else { return symbols }
        let offset = min(max(calendar.firstWeekday - 1, 0), 6)
        return (0..<CalendarMonthMetrics.columnCount).map { symbols[($0 + offset) % 7] }
    }

    /// 头部公历月份。模板必须是 `MMM` 而非 `MMMM`：zh-Hans 的宽月名会出「九月」，
    /// 而 `MMM` 出「9月」（对齐参考截图），en 出「Sep」，ja 出「9月」。
    static func monthTitle(for date: Date, locale: Locale, timeZone: TimeZone) -> String {
        formatted(date, template: "MMM", locale: locale, timeZone: timeZone)
    }

    /// 星期全名（浮窗用）。
    static func weekdayName(for date: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        let symbols = calendar.weekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }

    /// 短日期（浮窗用：zh「9月20日」、en「Sep 20」）。
    static func shortDate(for date: Date, locale: Locale, timeZone: TimeZone) -> String {
        formatted(date, template: "MMMd", locale: locale, timeZone: timeZone)
    }

    /// 本地化模板格式化。`Date.FormatStyle` 在这里不能用：它对 zh 的 `.month(.wide)`
    /// 出「九月」、纯月+日组合出「9/20」，都不是中文日历习惯的写法；模板 API 才能
    /// 拿到「9月」「9月20日」这类 ICU 本地化结果。
    private static func formatted(
        _ date: Date,
        template: String,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

// MARK: - 农历

/// 农历中文名映射：Foundation 的 `.chinese` 日历只给数字月日，
/// 「八月初十」这类中文名必须自建表（无系统 API 可用）。
enum ChineseLunarFormatter {
    static let monthNames = [
        "正月", "二月", "三月", "四月", "五月", "六月",
        "七月", "八月", "九月", "十月", "冬月", "腊月",
    ]

    static let dayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]

    static let heavenlyStems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    static let earthlyBranches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]

    /// 「八月初十」；闰月加「闰」前缀。索引越界时退化为数字形式，不崩。
    static func monthDayName(month: Int, day: Int, isLeapMonth: Bool = false) -> String {
        guard monthNames.indices.contains(month - 1), dayNames.indices.contains(day - 1) else {
            return "\(month)/\(day)"
        }
        return (isLeapMonth ? "闰" : "") + monthNames[month - 1] + dayNames[day - 1]
    }

    /// 「丙午年」：`.chinese` 的年组件是 60 甲子序号（2026 → 43），不是公历年，
    /// 因此以春节为界的换年由系统负责，1—2 月不会错成下一年。
    static func cycleYearName(_ cycleYear: Int) -> String {
        guard cycleYear > 0 else { return "" }
        let stem = heavenlyStems[(cycleYear - 1) % heavenlyStems.count]
        let branch = earthlyBranches[(cycleYear - 1) % earthlyBranches.count]
        return stem + branch + "年"
    }

    /// 某日的农历文本（「八月初十」）。
    static func monthDayName(for date: Date, chineseCalendar: Calendar) -> String {
        let components = chineseCalendar.dateComponents([.month, .day], from: date)
        return monthDayName(
            month: components.month ?? 0,
            day: components.day ?? 0,
            isLeapMonth: components.isLeapMonth ?? false)
    }

    /// 浮窗用完整文本（「丙午年八月初十」）。
    static func fullName(for date: Date, chineseCalendar: Calendar) -> String {
        let components = chineseCalendar.dateComponents([.year, .month, .day], from: date)
        let year = cycleYearName(components.year ?? 0)
        let monthDay = monthDayName(
            month: components.month ?? 0,
            day: components.day ?? 0,
            isLeapMonth: components.isLeapMonth ?? false)
        return year + monthDay
    }
}
