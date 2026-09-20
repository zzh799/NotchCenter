import Foundation
import Testing

@testable import RemindersPlugin

// MARK: - 数据源筛选口径与源编解码回归
//
// 全部为纯函数断言：不触碰 EventKit、不渲染视图。锚点日期用 2026-09-20（参考
// 截图那天），时区固定 Asia/Shanghai 以免受运行环境影响。

struct RemindersLogicTests {
    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        calendar().date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 只填本次断言关心的字段，其余走默认。
    private static func item(
        id: String,
        list: String = "LIST-A",
        completed: Bool = false,
        priority: Int = 0,
        due: Date? = nil,
        repeating: Bool = false
    ) -> RemindersItem {
        RemindersItem(
            id: id,
            title: "item-\(id)",
            isRepeating: repeating,
            isCompleted: completed,
            priority: priority,
            dueDate: due,
            listID: list)
    }

    // MARK: 今天（含逾期）

    @Test func todayIncludesOverdueAndTodayButNotTomorrow() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        let items = [
            Self.item(id: "overdue", due: Self.date(2026, 9, 18)),
            Self.item(id: "todayEarly", due: Self.date(2026, 9, 20, 0, 0)),
            Self.item(id: "todayLate", due: Self.date(2026, 9, 20, 23, 59)),
            Self.item(id: "tomorrow", due: Self.date(2026, 9, 21, 0, 0)),
            Self.item(id: "noDue"),
        ]

        let visible = RemindersLogic.visibleItems(
            items, source: .smart(.today), now: now, calendar: calendar)

        // 逾期 + 今天的都在；明天与无到期日的不在。顺带锁住"保持输入顺序"。
        #expect(visible.map(\.id) == ["overdue", "todayEarly", "todayLate"])
    }

    // MARK: 顺序

    @Test func visibleItemsPreserveInputOrder() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        // 刻意给一个"按到期日排会不一样"的输入序：决策 D6 明确不自推排序键。
        let items = [
            Self.item(id: "z", due: Self.date(2026, 9, 20, 23, 0)),
            Self.item(id: "a", due: Self.date(2026, 9, 20, 1, 0)),
            Self.item(id: "m", due: Self.date(2026, 9, 19)),
        ]
        let visible = RemindersLogic.visibleItems(
            items, source: .smart(.today), now: now, calendar: calendar)
        #expect(visible.map(\.id) == ["z", "a", "m"])
    }

    // MARK: 已完成项

    @Test func completedItemsAreExcludedFromEverySource() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        let done = Self.item(
            id: "done", completed: true, priority: 1,
            due: Self.date(2026, 9, 20, 9, 0))
        let pending = Self.item(
            id: "pending", priority: 1, due: Self.date(2026, 9, 20, 9, 0))

        let sources: [RemindersSource] = [
            .list("LIST-A"), .smart(.today), .smart(.scheduled),
            .smart(.important), .smart(.all),
        ]
        for source in sources {
            let visible = RemindersLogic.visibleItems(
                [done, pending], source: source, now: now, calendar: calendar)
            #expect(visible.map(\.id) == ["pending"], "\(source) 不该包含已完成项")
        }
        // 计数口径随之：它等于过滤后的条数。
        #expect(
            RemindersLogic.visibleItems(
                [done, pending], source: .smart(.all), now: now, calendar: calendar
            ).count == 1)
    }

    // MARK: 具体清单

    @Test func listSourceMatchesOnlyItsOwnItems() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        let items = [
            Self.item(id: "a", list: "LIST-A"),
            Self.item(id: "b", list: "LIST-B"),
            Self.item(id: "c", list: "LIST-A", due: Self.date(2026, 9, 25)),
        ]
        // 清单不看到期日：没有到期日的也要出现。
        let visible = RemindersLogic.visibleItems(
            items, source: .list("LIST-A"), now: now, calendar: calendar)
        #expect(visible.map(\.id) == ["a", "c"])
    }

    // MARK: 计划

    @Test func scheduledRequiresADueDate() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        let items = [
            Self.item(id: "noDue"),
            Self.item(id: "far", due: Self.date(2027, 1, 1)),
            Self.item(id: "past", due: Self.date(2025, 1, 1)),
        ]
        let visible = RemindersLogic.visibleItems(
            items, source: .smart(.scheduled), now: now, calendar: calendar)
        // 无下界：过去的也算"已安排"。
        #expect(visible.map(\.id) == ["far", "past"])
    }

    // MARK: 优先级（不是旗标）

    @Test func importantRequiresNonZeroPriority() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        let items = [
            Self.item(id: "none", priority: 0),
            Self.item(id: "high", priority: 1),
            Self.item(id: "medium", priority: 5),
            Self.item(id: "low", priority: 9),
        ]
        let visible = RemindersLogic.visibleItems(
            items, source: .smart(.important), now: now, calendar: calendar)
        #expect(visible.map(\.id) == ["high", "medium", "low"])
    }

    // MARK: 全部

    @Test func allIncludesEveryPendingItem() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        let items = [
            Self.item(id: "a", list: "LIST-A"),
            Self.item(id: "b", list: "LIST-B", due: Self.date(2030, 1, 1)),
            Self.item(id: "c", list: "LIST-C", completed: true),
        ]
        let visible = RemindersLogic.visibleItems(
            items, source: .smart(.all), now: now, calendar: calendar)
        #expect(visible.map(\.id) == ["a", "b"])
    }

    // MARK: 边界

    @Test func startOfTomorrowIsNextMidnight() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 20, 16, 0)
        #expect(RemindersLogic.startOfTomorrow(for: now, calendar: calendar)
            == Self.date(2026, 9, 21))
        // 今日零点也指向次日零点（"今天"不看时刻只看日界）。
        #expect(RemindersLogic.startOfTomorrow(for: Self.date(2026, 9, 20), calendar: calendar)
            == Self.date(2026, 9, 21))
    }

    @Test func dueDateFromComponentsResolvesDateOnlyReminders() {
        let calendar = Self.calendar()
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 20
        #expect(RemindersLogic.dueDate(from: components, calendar: calendar)
            == Self.date(2026, 9, 20))
        // 空组件、以及只给了时分的组件，都必须回 nil：`Calendar.date(from:)` 会
        // 给缺失字段填默认值（年 1 / 月 1 / 日 1），放任它就会造出一条纪元附近的
        // 假到期日，让"没有到期日"的提醒凭空出现在「今天」里。
        #expect(RemindersLogic.dueDate(from: DateComponents(), calendar: calendar) == nil)
        #expect(RemindersLogic.dueDate(from: nil, calendar: calendar) == nil)
        var timeOnly = DateComponents()
        timeOnly.hour = 9
        timeOnly.minute = 30
        #expect(RemindersLogic.dueDate(from: timeOnly, calendar: calendar) == nil)
    }

    // MARK: 数据源编解码

    @Test func sourceRoundTripsThroughJSON() throws {
        let sources: [RemindersSource] = [
            .smart(.today), .smart(.scheduled), .smart(.important),
            .smart(.all), .list("CAL-IDENTIFIER-123"),
        ]
        for source in sources {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(RemindersSource.self, from: data)
            #expect(decoded == source)
        }
    }

    /// 持久化在用户磁盘上的数据遇到未知形状时必须**报错**而不是静默落回默认——
    /// 静默回退会让用户某天发现"块自己换了清单"却查不到原因。
    @Test func unknownSourceShapeThrowsInsteadOfDefaulting() {
        let unknownSmart = Data(#"{"type":"smart","value":"flagged"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RemindersSource.self, from: unknownSmart)
        }
        let unknownKind = Data(#"{"type":"tagged","value":"x"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RemindersSource.self, from: unknownKind)
        }
    }

    @Test func listIdentifierOnlyResolvesForListSources() {
        #expect(RemindersSource.list("X").listIdentifier == "X")
        #expect(RemindersSource.smart(.today).listIdentifier == nil)
        #expect(RemindersSource.fallback == .smart(.today))
    }
}
