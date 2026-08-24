import Foundation

// MARK: - 峰谷时钟逻辑（从 dsh-opencode-usage client.tsx 的 PeakClock 移植）
//
// OpenCode 的 DeepSeek V4 Flash/Pro 在两个 UTC 窗口内按峰时计价：
// 01:00–04:00 与 06:00–10:00 UTC。表盘是 24 小时制本地时间面
// （一圈 = 一天，每个刻度对应唯一的本地时刻），峰时段画红色弧段，
// 其余为谷时绿色；指针一天转一圈、平滑到秒。

enum PeakClockLogic {
    static let peakColor = PeakClockColor(red: 0.898, green: 0.282, blue: 0.302) // #e5484d
    static let offPeakColor = PeakClockColor(red: 0.180, green: 0.620, blue: 0.357) // #2e9e5b

    struct PeakClockColor: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// 峰时窗口：UTC 当日秒区间 [start, end)。01:00–04:00 与 06:00–10:00。
    private static let peakWindows: [(start: Int, end: Int)] = [
        (3_600, 14_400),
        (21_600, 36_000),
    ]
    static let daySeconds = 86_400

    struct ClockArc: Equatable, Sendable {
        /// 表盘角度，0° = 12 点钟方向，顺时针。
        let startDegree: Double
        let endDegree: Double
    }

    // MARK: 判定与倒计时

    /// 当前是否处于峰时窗口（按该时刻的 UTC 当日秒判定；窗口锚定 UTC）。
    static func isPeak(_ date: Date = Date()) -> Bool {
        let secondOfDay = utcSecondOfDay(date)
        return peakWindows.contains { secondOfDay >= $0.start && secondOfDay < $0.end }
    }

    /// 当前阶段剩余秒数：峰时到峰末；谷时到下一个峰时起点（跨零点取次日）。
    static func phaseRemainingSeconds(_ date: Date = Date()) -> Int {
        let second = utcSecondOfDay(date)
        var end: Int
        if let window = peakWindows.first(where: { second >= $0.start && second < $0.end }) {
            end = window.end
        } else if let next = peakWindows.first(where: { second < $0.start }) {
            end = next.start
        } else {
            // 已过当日最后一个峰时起点 → 次日第一个峰时起点。
            end = daySeconds + peakWindows[0].start
        }
        return end - second
    }

    /// 该时刻的 UTC 当日秒数（GMT 日历直读；峰价窗口锚定 UTC 时刻而非本地钟面）。
    private static func utcSecondOfDay(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return components.hour! * 3600 + components.minute! * 60 + components.second!
    }

    // MARK: 表盘几何

    /// 把 UTC 峰时窗口映射到本地 24 小时表盘的角度弧段（1° = 4 分钟），
    /// 跨零点的窗口拆成两段并合并相邻弧段。
    static func peakArcs(
        _ date: Date = Date(),
        utcOffsetSeconds: Int = TimeZone.current.secondsFromGMT()
    ) -> [ClockArc] {
        // 本地分钟 = (UTC 分钟 + 本地相对 UTC 偏移) mod 1440。
        let offsetMinutes = Double(utcOffsetSeconds / 60)
        var arcs: [ClockArc] = []
        for window in peakWindows {
            let startMinute = (Double(window.start) / 60 + offsetMinutes)
                .truncatingRemainder(dividingBy: 1440)
            let normalizedStart = startMinute < 0 ? startMinute + 1440 : startMinute
            let endMinute = (Double(window.end) / 60 + offsetMinutes)
                .truncatingRemainder(dividingBy: 1440)
            let normalizedEnd = endMinute < 0 ? endMinute + 1440 : endMinute
            if normalizedStart < normalizedEnd {
                arcs.append(ClockArc(startDegree: normalizedStart / 4, endDegree: normalizedEnd / 4))
            } else {
                // 窗口跨过本地零点。
                arcs.append(ClockArc(startDegree: normalizedStart / 4, endDegree: 360))
                arcs.append(ClockArc(startDegree: 0, endDegree: normalizedEnd / 4))
            }
        }
        return mergedArcs(arcs.sorted { $0.startDegree < $1.startDegree })
    }

    /// 峰时弧段的补集（谷时绿色弧段）。
    static func offPeakArcs(of peaks: [ClockArc]) -> [ClockArc] {
        var result: [ClockArc] = []
        var cursor = 0.0
        for arc in peaks {
            if arc.startDegree > cursor {
                result.append(ClockArc(startDegree: cursor, endDegree: arc.startDegree))
            }
            cursor = max(cursor, arc.endDegree)
        }
        if cursor < 360 {
            result.append(ClockArc(startDegree: cursor, endDegree: 360))
        }
        return result
    }

    private static func mergedArcs(_ sorted: [ClockArc]) -> [ClockArc] {
        var merged: [ClockArc] = []
        for arc in sorted {
            if let last = merged.last, arc.startDegree <= last.endDegree {
                if arc.endDegree > last.endDegree {
                    merged[merged.count - 1] = ClockArc(startDegree: last.startDegree, endDegree: arc.endDegree)
                }
            } else {
                merged.append(arc)
            }
        }
        return merged
    }

    /// 指针角度：本地一日秒数 / 86400 × 360，平滑到秒。
    static func handAngle(_ date: Date = Date(), timeZone: TimeZone = .current) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let secondOfDay = components.hour! * 3600 + components.minute! * 60 + components.second!
        return Double(secondOfDay) / Double(daySeconds) * 360
    }

    /// 秒数倒计时 → "HH:MM:SS"（向上取整，与挂钟走秒一致）。
    static func formatCountdown(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
