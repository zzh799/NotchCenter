import Foundation
import SwiftUI

// MARK: - 调度与状态的文案派生（纯函数，单测覆盖）

/// 把结构化规则渲染成人读摘要。
///
/// 摘要**只用于实时显示**，不进命令快照——快照里存规则本身，因为文案随语言变，
/// 历史不该变。
enum ScheduleText {
    /// 规则摘要（如 "Daily at 09:30" / "每天 09:30"）。
    static func summary(for rule: ScheduleRule, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch rule.normalized() {
        case let .everyMinutes(minutes):
            return LF("scheduler.rule.everyMinutes", minutes)
        case let .hourlyAt(minute):
            return LF("scheduler.rule.hourly", minute)
        case let .dailyAt(hour, minute):
            return LF("scheduler.rule.daily", hour, minute)
        case let .weeklyAt(weekdays, hour, minute):
            return LF("scheduler.rule.weekly", weekdayList(weekdays, locale: locale), hour, minute)
        case let .monthlyAt(day, hour, minute):
            return LF("scheduler.rule.monthly", day, hour, minute)
        }
    }

    /// 星期缩写的逗号列表（按 `Calendar` 的短符号表，跟随系统语言）。
    static func weekdayList(_ weekdays: [Int], locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortWeekdaySymbols
        return weekdays
            .sorted()
            .compactMap { index -> String? in
                guard index >= 1, index <= symbols.count else { return nil }
                return symbols[index - 1]
            }
            .joined(separator: ", ")
    }

    /// 星期选择器用的短符号表（1=周日 … 7=周六）。
    static func weekdaySymbols(locale: Locale) -> [(weekday: Int, symbol: String)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.shortWeekdaySymbols.enumerated().map { (offset, symbol) in
            (weekday: offset + 1, symbol: symbol)
        }
    }
}

/// 时长与相对时间的紧凑格式（列表里空间紧张，一律短格式）。
enum RunText {
    /// 时长分档（纯值，单测覆盖）。
    ///
    /// 分档与文案分开：文案依赖插件 `.bundle` 的 strings 资源，在单测进程里
    /// 拿不到（测试链的是 dylib 而不是组装后的 bundle），所以能被断言的必须
    /// 是分档本身，而不是格式化结果。
    enum DurationBucket: Equatable {
        case none
        case seconds(Int)
        case minutes(minutes: Int, seconds: Int)
        case hours(hours: Int, minutes: Int)
    }

    static func durationBucket(_ seconds: TimeInterval?) -> DurationBucket {
        guard let seconds, seconds >= 0 else { return .none }
        let total = Int(seconds.rounded())
        if total < 60 { return .seconds(total) }
        if total < 3600 { return .minutes(minutes: total / 60, seconds: total % 60) }
        return .hours(hours: total / 3600, minutes: (total % 3600) / 60)
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        switch durationBucket(seconds) {
        case .none: return L("scheduler.duration.none")
        case let .seconds(total): return LF("scheduler.duration.seconds", total)
        case let .minutes(minutes, remainder): return LF("scheduler.duration.minutes", minutes, remainder)
        case let .hours(hours, minutes): return LF("scheduler.duration.hours", hours, minutes)
        }
    }

    /// 绝对时刻 `HH:mm`（今天）或 `M/d HH:mm`（其它日期）。
    static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, inSameDayAs: now) ? "Hm" : "MdHm"
        )
        return formatter.string(from: date)
    }

    /// 相对时间（"3m" / "2h" / "1d"），用于「上次成功」这类滚动信息。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L("scheduler.relative.now") }
        if seconds < 3600 { return LF("scheduler.relative.minutes", Int(seconds / 60)) }
        if seconds < 86_400 { return LF("scheduler.relative.hours", Int(seconds / 3600)) }
        return LF("scheduler.relative.days", Int(seconds / 86_400))
    }

    static func status(_ status: TaskRun.Status) -> String {
        switch status {
        case .running: return L("scheduler.status.running")
        case .succeeded: return L("scheduler.status.succeeded")
        case .failed: return L("scheduler.status.failed")
        case .timedOut: return L("scheduler.status.timedOut")
        case .aborted: return L("scheduler.status.aborted")
        case .interrupted: return L("scheduler.status.interrupted")
        }
    }

    static func skipReason(_ reason: SkipLog.Reason) -> String {
        switch reason {
        case .running: return L("scheduler.skip.running")
        case .offline: return L("scheduler.skip.offline")
        }
    }

    /// 退出码展示（nil = 无退出码，如超时/被杀）。
    static func exitCode(_ code: Int32?) -> String {
        guard let code else { return L("scheduler.exitCode.none") }
        return LF("scheduler.exitCode.value", code)
    }
}

// MARK: - ANSI 剥离

/// 输出里的 ANSI 转义序列在渲染前剥离（**存储保留原文**）。
///
/// 存储留原文是为了不丢信息；渲染必须剥，否则日志里会混着一堆
/// `[0;32m` 之类的控制码，比彩色本身更难看。
enum ANSIText {
    /// 覆盖 CSI（颜色/光标）、OSC（标题/超链接）与单字符 ESC 序列。
    static func stripped(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var output = String()
        output.reserveCapacity(text.count)
        var iterator = Array(text.unicodeScalars)
        var index = 0
        while index < iterator.count {
            let scalar = iterator[index]
            guard scalar == "\u{1B}" else {
                output.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < iterator.count else { break }
            switch iterator[index] {
            case "[":
                // CSI：吃掉参数字节（0x30–0x3F）与中间字节（0x20–0x2F），
                // 停在终止字节（0x40–0x7E）。
                index += 1
                while index < iterator.count, (0x30...0x3F).contains(iterator[index].value) { index += 1 }
                while index < iterator.count, (0x20...0x2F).contains(iterator[index].value) { index += 1 }
                if index < iterator.count, (0x40...0x7E).contains(iterator[index].value) { index += 1 }
            case "]":
                // OSC：吃到 BEL 或 ST（ESC \）为止。
                index += 1
                while index < iterator.count {
                    if iterator[index] == "\u{07}" { index += 1; break }
                    if iterator[index] == "\u{1B}", index + 1 < iterator.count, iterator[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                // 其它单字符序列（如 ESC ( B）连同下一个字符一起丢。
                index += 1
            }
        }
        return output
    }
}
