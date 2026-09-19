import Foundation

// MARK: - 结构化调度规则（决策 2：不做 cron，UI 全是选择器）
//
// 为什么不是 cron 字符串：这个 UI 长在抽屉格子里（最小 480×340），用户在那种
// 地方不该敲字符串；选择器天然要求结构化模型，cron 字符串会逼着在它上面再糊
// 一层「选择器 → 字符串」的翻译，纯亏。表达力缺口（如「工作日 9:00–18:00 每
// 5 分钟」）出现时再加可选高级字段，不丢数据。详见 Agent Note
// 2026-09-19-command-scheduler-plugin 决策 2。

/// 一条调度规则。用例名做 Codable 的键（关联值全部带标签，JSON 形如
/// `{"dailyAt":{"hour":9,"minute":30}}`），磁盘形状稳定、可读、可手改。
public enum ScheduleRule: Codable, Equatable, Hashable, Sendable {
    /// 每 N 分钟，与整分对齐（N=30 → 每小时 :00 与 :30），非「从创建时刻起算」。
    case everyMinutes(minutes: Int)
    /// 每小时第 M 分。
    case hourlyAt(minute: Int)
    /// 每天 HH:MM。
    case dailyAt(hour: Int, minute: Int)
    /// 每周指定星期（`Calendar` 的 weekday：1=周日 … 7=周六）的 HH:MM。
    case weeklyAt(weekdays: [Int], hour: Int, minute: Int)
    /// 每月指定日 HH:MM；该月没有这一天（如 31 日在 4 月）时**该月不触发**。
    case monthlyAt(day: Int, hour: Int, minute: Int)
}

extension ScheduleRule {
    /// 每 N 分钟的取值域；也用于把损坏数据夹回合法区间。
    public static let minuteStepRange = 1...720
    /// 每月日期的取值域。
    public static let dayOfMonthRange = 1...31
    /// `Calendar` weekday 的取值域。
    public static let weekdayRange = 1...7

    /// 把外部输入（用户编辑 / 损坏的磁盘数据）夹进合法域；返回可直接使用的规则。
    ///
    /// 不做「抛错」：调度器手里握着的是历史数据，一条畸形规则不该让整份任务表
    /// 罢工。夹紧的代价是语义被悄悄改动，因此 `normalized` 与 `self` 不等时 UI
    /// 侧要如实呈现（表单保存时也走这里，用户看到的就是落盘的）。
    public func normalized() -> ScheduleRule {
        switch self {
        case let .everyMinutes(minutes):
            return .everyMinutes(minutes: minutes.clamped(to: Self.minuteStepRange))
        case let .hourlyAt(minute):
            return .hourlyAt(minute: ScheduleModel.clampMinute(minute))
        case let .dailyAt(hour, minute):
            return .dailyAt(hour: ScheduleModel.clampHour(hour), minute: ScheduleModel.clampMinute(minute))
        case let .weeklyAt(weekdays, hour, minute):
            let days = Set(weekdays.map { $0.clamped(to: Self.weekdayRange) }).sorted()
            return .weeklyAt(
                // 空集合会让规则永不触发（且无法在 UI 上解释），兜底为周一。
                weekdays: days.isEmpty ? [2] : days,
                hour: ScheduleModel.clampHour(hour),
                minute: ScheduleModel.clampMinute(minute)
            )
        case let .monthlyAt(day, hour, minute):
            return .monthlyAt(
                day: day.clamped(to: Self.dayOfMonthRange),
                hour: ScheduleModel.clampHour(hour),
                minute: ScheduleModel.clampMinute(minute)
            )
        }
    }

    /// 是否为「每月指定日且日期 > 28」——这类规则在部分月份不触发，表单须提示。
    public var maySkipMonths: Bool {
        if case let .monthlyAt(day, _, _) = self { return day > 28 }
        return false
    }
}

extension Comparable {
    /// 把值夹进闭区间（自带默认实现的辅助，避免各调用点各写一遍 min/max）。
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - 下次触发时刻（纯函数，单测穷举）

/// 调度时刻计算。**全插件唯一在无睡眠假设下做时间数学的地方**，因此只接收
/// 显式的 `after` / `calendar`，不读 `Date()`、不读 `Calendar.current`——
/// 可被单测喂任意时区、任意夏令时切换日。
public enum ScheduleModel {
    /// 逐日推进的搜索上限。`每月 31 日` 在连续小月后最长需要跨 2 个月命中
    /// （4 月无 31 → 5 月 31），weekly 恒 ≤ 8 天；400 天是「规则永不触发」的
    /// 兜底出口（返回 nil 而不是无限循环）。
    static let maxDayLookahead = 400

    public static func clampHour(_ value: Int) -> Int { value.clamped(to: 0...23) }
    public static func clampMinute(_ value: Int) -> Int { value.clamped(to: 0...59) }

    /// 严格晚于 `after` 的下一次触发时刻；规则永不触发（如 31 日在连续小月后
    /// 仍无解、或逐日搜索超出上限）时返回 nil。
    public static func next(
        after: Date,
        rule: ScheduleRule,
        calendar: Calendar = .current
    ) -> Date? {
        let rule = rule.normalized()
        switch rule {
        case let .everyMinutes(minutes):
            return nextAlignedMinute(after: after, step: minutes, calendar: calendar)
        case let .hourlyAt(minute):
            return nextHourly(after: after, minute: minute, calendar: calendar)
        case let .dailyAt(hour, minute):
            return nextDayStepped(after: after, calendar: calendar, time: (hour, minute)) { _ in true }
        case let .weeklyAt(weekdays, hour, minute):
            let wanted = Set(weekdays)
            return nextDayStepped(after: after, calendar: calendar, time: (hour, minute)) { day in
                wanted.contains(calendar.component(.weekday, from: day))
            }
        case let .monthlyAt(day, hour, minute):
            return nextDayStepped(after: after, calendar: calendar, time: (hour, minute)) { candidate in
                calendar.component(.day, from: candidate) == day
            }
        }
    }

    // MARK: 各档实现

    /// 每 N 分钟：从下一个整分起，跳到下一个与整分对齐且「当日分钟序号 % N == 0」
    /// 的时刻。用「跳一格」而不是逐分钟扫描——N 很大时扫描会很浪费（N=720 时
    /// 逐分钟要扫半天，跳一格最多两次）。
    private static func nextAlignedMinute(after: Date, step: Int, calendar: Calendar) -> Date? {
        let step = step.clamped(to: ScheduleRule.minuteStepRange)
        guard var candidate = minuteBoundary(after: after, calendar: calendar) else { return nil }
        // 四轮是宽松上界：每轮把候选推到当日对齐点；correction 跨过午夜时
        // 新的一天对齐偏移会变（1440 % step != 0 的 step），下一轮再修一次即可。
        for _ in 0..<4 {
            let minuteOfDay = calendar.component(.hour, from: candidate) * 60
                + calendar.component(.minute, from: candidate)
            let remainder = minuteOfDay % step
            if remainder == 0 { return candidate }
            guard let advanced = calendar.date(
                byAdding: .minute, value: step - remainder, to: candidate
            ) else { return nil }
            candidate = advanced
        }
        return nil
    }

    /// 每小时第 M 分：分钟值在 60 分钟内必然出现一次，所以最多向前扫 61 分钟。
    private static func nextHourly(after: Date, minute: Int, calendar: Calendar) -> Date? {
        let minute = clampMinute(minute)
        guard var candidate = minuteBoundary(after: after, calendar: calendar) else { return nil }
        for _ in 0..<61 {
            if calendar.component(.minute, from: candidate) == minute { return candidate }
            guard let advanced = calendar.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
            candidate = advanced
        }
        return nil
    }

    /// 逐日推进：找到第一个「日谓词成立且 HH:MM 在该日真实存在」的日期。
    ///
    /// 夏令时跳时日的处理是**跳过该日**（`bySettingHour` 在 02:30 不存在时会
    /// 顺移到 03:00，校验 hour/minute 不符即判定该日无此时刻），不顺延——
    /// 「每天 02:30」在跳时那天本就没有 02:30，挪到别处会让运行时刻悄悄漂移。
    private static func nextDayStepped(
        after: Date,
        calendar: Calendar,
        time: (hour: Int, minute: Int),
        matchesDay: (Date) -> Bool
    ) -> Date? {
        let hour = clampHour(time.hour)
        let minute = clampMinute(time.minute)
        let today = calendar.startOfDay(for: after)
        for offset in 0...maxDayLookahead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            guard matchesDay(day) else { continue }
            guard let candidate = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: day
            ) else { continue }
            // 顺移会让 hour/minute 对不上，且可能跑到隔天（月末 23:xx 顺移跨月）。
            guard calendar.component(.hour, from: candidate) == hour,
                  calendar.component(.minute, from: candidate) == minute,
                  calendar.isDate(candidate, inSameDayAs: day) else { continue }
            guard candidate > after else { continue }
            return candidate
        }
        return nil
    }

    /// 严格晚于 `after` 的下一个整分（秒归零）。
    private static func minuteBoundary(after: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: after)
        guard let floored = calendar.date(from: components) else { return nil }
        return floored > after ? floored : calendar.date(byAdding: .minute, value: 1, to: floored)
    }
}
