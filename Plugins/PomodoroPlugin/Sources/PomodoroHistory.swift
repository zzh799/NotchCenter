import Foundation

// MARK: - 番茄钟明细（StateStore 键 "history"）
//
// 取代旧 `PomodoroStats`（单条 {day, completed}）：只有"每天几个番茄"不足以
// 复盘——每次专注的体验打分、每条微休息的效果都无从谈起。数据模型的分叉
// 与取舍见 Agent Note 2026-09-10-plugin-page-blocks。

/// 一次专注会话的明细。
struct PomodoroFocusSession: Codable, Equatable, Identifiable {
    /// 会话结果。
    enum Outcome: String, Codable {
        /// 自然完成——**唯一**触发评分的路径。
        case completed
        /// 用户手动跳过（只落一条记录，不评分）。
        case skipped
    }

    /// 会话 ID（微休息用 `sessionID` 指回来）。
    let id: String
    /// 计划时长（秒）。用户事后改设置不影响已记录的会话。
    let plannedSeconds: Int
    let startedAt: Date
    let endedAt: Date
    let outcome: Outcome
    /// 用户对本次体验的情绪评分 1...5；nil = 未评分。
    /// 只有"自然完成 + 用户处理过待评分"才会非 nil（不可补评，见 note）。
    var rating: Int?
}

/// 一次微休息的明细（"微休息有没有用"的原始事实）。
struct PomodoroMicroBreak: Codable, Equatable, Identifiable {
    /// 结束方式（"被打断比例"的分子）。
    enum Outcome: String, Codable {
        /// 计时自然结束。
        case natural
        /// 用户提前结束。
        case skippedByUser
        /// 会话被停止或插件被禁用而中断。
        case aborted
    }

    let id: String
    /// 所属专注会话——关联对照（有 / 无微休息的专注）的数据基础。
    let sessionID: String
    let plannedSeconds: Int
    let startedAt: Date
    let endedAt: Date
    let outcome: Outcome

    /// 实际停留秒数（自然结束 ≈ plannedSeconds，提前结束更短）。
    var actualSeconds: Int {
        max(Int(endedAt.timeIntervalSince(startedAt).rounded()), 0)
    }
}

/// 番茄钟历史档（StateStore 单键持久化）。
struct PomodoroHistory: Codable, Equatable {
    /// 明细条数硬上限（专注 + 微休息合计）。
    ///
    /// 保留策略是**全量**（不按天裁剪）——复盘要看长期变化，条数对 JSON 也不
    /// 是压力；但单文件迟早会大到每次启动都要全量解码，所以留一个刹车。
    /// 约 20 倍日活量级（每天约 8 段专注 + 20 条微休息 ≈ 1 万条/年）。
    static let maxRecords = 20_000

    var sessions: [PomodoroFocusSession] = []
    var microBreaks: [PomodoroMicroBreak] = []
    /// 旧 `stats` 键（单条 `{day, completed}`）迁移来的日汇总兜底：只有"那天
    /// 完成了几个"，没有明细也没有评分。迁移**不伪造** N 条无评分明细。
    var dailyFallbacks: [String: Int] = [:]
    /// 待评分会话（阻塞式闸门的数据面）：评分后转正进 `sessions`，
    /// 用户删除或超时自愈则**整条丢弃**（连它的微休息明细）。
    var pending: PomodoroFocusSession?
    /// 待评分会话的微休息明细——与 `pending` 同生共死。它们不入 `microBreaks`，
    /// 是为了避免"专注被删除后留下孤儿微休息"（也就不会污染复盘对照）。
    var pendingMicroBreaks: [PomodoroMicroBreak] = []

    var totalRecords: Int { sessions.count + microBreaks.count }

    init(
        sessions: [PomodoroFocusSession] = [],
        microBreaks: [PomodoroMicroBreak] = [],
        dailyFallbacks: [String: Int] = [:],
        pending: PomodoroFocusSession? = nil,
        pendingMicroBreaks: [PomodoroMicroBreak] = []
    ) {
        self.sessions = sessions
        self.microBreaks = microBreaks
        self.dailyFallbacks = dailyFallbacks
        self.pending = pending
        self.pendingMicroBreaks = pendingMicroBreaks
    }

    // 逐字段 `decodeIfPresent` + 默认值（与 `LayoutModel` 同款约定）：合成的
    // `init(from:)` 不会在键缺失时回落到属性默认值，而历史档将来加字段时
    // 旧文件必须还能读——一次写对，省掉一次迁移。
    private enum CodingKeys: String, CodingKey {
        case sessions, microBreaks, dailyFallbacks, pending, pendingMicroBreaks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([PomodoroFocusSession].self, forKey: .sessions) ?? []
        microBreaks = try container.decodeIfPresent([PomodoroMicroBreak].self, forKey: .microBreaks) ?? []
        dailyFallbacks = try container.decodeIfPresent([String: Int].self, forKey: .dailyFallbacks) ?? [:]
        pending = try container.decodeIfPresent(PomodoroFocusSession.self, forKey: .pending)
        pendingMicroBreaks = try container
            .decodeIfPresent([PomodoroMicroBreak].self, forKey: .pendingMicroBreaks) ?? []
    }

    /// 裁剪到硬上限：按结束时刻从旧到新**整组**丢弃（一条专注会话连同它的
    /// 微休息一起丢，否则会留下孤儿微休息）。返回是否发生裁剪。
    @discardableResult
    mutating func trimToLimit() -> Bool {
        var trimmed = false
        while totalRecords > Self.maxRecords,
              let oldest = sessions.min(by: { $0.endedAt < $1.endedAt }) {
            sessions.removeAll { $0.id == oldest.id }
            microBreaks.removeAll { $0.sessionID == oldest.id }
            trimmed = true
        }
        return trimmed
    }
}

// MARK: - 派生量（纯函数，单测覆盖）

/// 微休息对照结果：把专注分成"有微休息"与"无微休息"两组，各给平均情绪分与
/// 完成率。**这是相关性而非因果**——分组是用户行为的结果而非随机分配，
/// 页面必须据此标注。
struct PomodoroMicroBreakContrast: Equatable {
    struct Group: Equatable {
        var sessionCount = 0
        var completedCount = 0
        var ratedCount = 0
        var ratingSum = 0

        /// 平均情绪分（1...5）；无评分会话时为 nil。
        var averageRating: Double? {
            ratedCount > 0 ? Double(ratingSum) / Double(ratedCount) : nil
        }

        /// 完成率（自然完成 / 全部）；无会话时为 nil。
        var completionRate: Double? {
            sessionCount > 0 ? Double(completedCount) / Double(sessionCount) : nil
        }
    }

    var withMicroBreaks = Group()
    var withoutMicroBreaks = Group()
}

/// 一天的完成数（日期升序柱状图的一项）。
struct PomodoroDayCount: Equatable {
    /// 日键 `yyyy-MM-dd`。
    let day: String
    let completed: Int
}

/// 复盘区头部的一行汇总。
struct PomodoroHistoryOverview: Equatable {
    /// 已入库的专注会话数（含跳过的）。
    var sessionCount = 0
    /// 其中自然完成的次数。
    var completedCount = 0
    /// 已评分的会话数与评分之和（均分由两者推导）。
    var ratedCount = 0
    var ratingSum = 0
    /// 已入库的微休息条数。
    var microBreakCount = 0
    /// 有明细记录的天数。
    var dayCount = 0
    /// 迁移来的旧版日汇总天数（只有当日次数、没有明细与评分）。
    var legacyDayCount = 0

    /// 平均情绪分（1...5）；无评分时为 nil。
    var averageRating: Double? {
        ratedCount > 0 ? Double(ratingSum) / Double(ratedCount) : nil
    }
}

/// 复盘用的纯派生计算：输入历史档，输出页面要画的数字。
enum PomodoroHistoryAnalysis {
    /// 日键 `yyyy-MM-dd`（本地时区）；"今日完成数"与趋势桶共用同一把尺子。
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// 某个日键的完成数：明细里的自然完成 + 迁移来的日汇总兜底。
    static func completedCount(onDay day: String, history: PomodoroHistory) -> Int {
        let fromSessions = history.sessions.filter {
            $0.outcome == .completed && dayString($0.endedAt) == day
        }.count
        return fromSessions + (history.dailyFallbacks[day] ?? 0)
    }

    /// 近 `days` 天的每日完成数，按日期升序（含今天）。
    static func dailyCompleted(
        history: PomodoroHistory,
        days: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [PomodoroDayCount] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset -> PomodoroDayCount? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let day = dayString(date, calendar: calendar)
            return PomodoroDayCount(day: day, completed: completedCount(onDay: day, history: history))
        }
    }

    /// 某个日键的 24 小时完成分布（本地时区）——"今日节奏"的数据源。
    /// 按**结束时刻**归桶（会话完成的那一刻），跳过的会话不计。
    static func hourlyCompleted(
        onDay day: String,
        history: PomodoroHistory,
        calendar: Calendar = .current
    ) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        for session in history.sessions
        where session.outcome == .completed && dayString(session.endedAt, calendar: calendar) == day {
            let hour = calendar.component(.hour, from: session.endedAt)
            buckets[min(max(hour, 0), 23)] += 1
        }
        return buckets
    }

    /// `yyyy-MM-dd` → 本地化短星期标签（柱状图横轴）；解析失败原样返回。
    static func weekdayShortLabel(day: String, calendar: Calendar = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }

    /// 复盘区头部汇总（一次遍历算完）。
    static func overview(
        history: PomodoroHistory,
        calendar: Calendar = .current
    ) -> PomodoroHistoryOverview {
        var result = PomodoroHistoryOverview()
        result.sessionCount = history.sessions.count
        result.microBreakCount = history.microBreaks.count
        result.legacyDayCount = history.dailyFallbacks.filter { $0.value > 0 }.count
        var days = Set<String>()
        for session in history.sessions {
            if session.outcome == .completed { result.completedCount += 1 }
            if let rating = session.rating {
                result.ratedCount += 1
                result.ratingSum += rating
            }
            days.insert(dayString(session.endedAt, calendar: calendar))
        }
        result.dayCount = days.count
        return result
    }

    /// 微休息对照（见 `PomodoroMicroBreakContrast` 的因果警示）。
    ///
    /// 分组只看"这段专注内有没有微休息记录"；跳过的专注（`skipped`）计入
    /// 完成率的分母，但不计入评分。
    static func microBreakContrast(history: PomodoroHistory) -> PomodoroMicroBreakContrast {
        let sessionIDsWithBreak = Set(history.microBreaks.map(\.sessionID))
        var contrast = PomodoroMicroBreakContrast()
        for session in history.sessions {
            var group = sessionIDsWithBreak.contains(session.id)
                ? contrast.withMicroBreaks
                : contrast.withoutMicroBreaks
            group.sessionCount += 1
            if session.outcome == .completed { group.completedCount += 1 }
            if let rating = session.rating {
                group.ratedCount += 1
                group.ratingSum += rating
            }
            if sessionIDsWithBreak.contains(session.id) {
                contrast.withMicroBreaks = group
            } else {
                contrast.withoutMicroBreaks = group
            }
        }
        return contrast
    }

    /// 微休息的结束方式分布（复盘"被打断比例"）。
    static func microBreakOutcomeCounts(
        history: PomodoroHistory
    ) -> [PomodoroMicroBreak.Outcome: Int] {
        Dictionary(grouping: history.microBreaks, by: \.outcome).mapValues(\.count)
    }

    /// 旧 `stats` 键（单条 `{day, completed}`）→ 日汇总兜底。
    static func migratingLegacyStats(day: String, completed: Int) -> [String: Int] {
        guard !day.isEmpty, completed > 0 else { return [:] }
        return [day: completed]
    }
}
