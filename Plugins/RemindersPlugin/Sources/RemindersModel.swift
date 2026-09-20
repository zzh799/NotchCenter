import Foundation

// MARK: - 数据源（块绑定的那一个"看什么"）

/// 一个块实例绑定的**唯一**数据源：某个具体清单，或某个跨清单的智能视图。
///
/// 持久化为 `placementStore` 里的 `config.source`（JSON，`{"type":…,"value":…}`）。
/// 编码刻意做成带判别字段的扁平结构而非 `Codable` 自动合成的嵌套形式：后者对
/// 关联值 enum 生成的形状随 Swift 版本浮动，而这份数据要长期躺在用户磁盘上。
enum RemindersSource: Equatable, Hashable, Sendable, Codable {
    /// 某个具体清单（`EKCalendar.calendarIdentifier`）。
    case list(String)
    /// 跨清单的智能视图。
    case smart(SmartList)

    /// 智能视图。
    ///
    /// **没有"旗标"**：Reminders.app 的旗标存在它自己的容器里，公开 EventKit
    /// **不暴露**该属性（只有私有 ReminderKit 能读），因此无法实现。这里提供的是
    /// 公开 API 面内语义最接近的一项——「优先级」（`EKReminder.priority != 0`，
    /// 即 Reminders 里标了 `!` / `!!` / `!!!` 的条目）。
    enum SmartList: String, CaseIterable, Sendable, Hashable, Codable {
        /// 今天到期**及已逾期**的未完成项（与 Reminders.app 的「今天」同义）。
        case today
        /// 设有到期日的未完成项。
        case scheduled
        /// 标了优先级的未完成项。
        case important
        /// 全部未完成项。
        case all
    }

    /// 未设置过源的实例默认落在这里：零配置下唯一有意义、且参考截图里出现过的视图。
    static let fallback = RemindersSource.smart(.today)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        switch type {
        case "list":
            self = .list(value)
        case "smart":
            guard let smart = SmartList(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container,
                    debugDescription: "unknown smart list: \(value)")
            }
            self = .smart(smart)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown source type: \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .list(identifier):
            try container.encode("list", forKey: .type)
            try container.encode(identifier, forKey: .value)
        case let .smart(smart):
            try container.encode("smart", forKey: .type)
            try container.encode(smart.rawValue, forKey: .value)
        }
    }

    /// 是否指向具体清单（失效检测用；智能视图不会失效）。
    var listIdentifier: String? {
        if case let .list(identifier) = self { return identifier }
        return nil
    }
}

// MARK: - 清单描述符（`EKCalendar` 的纯值快照）

/// 清单颜色。EventKit 给的是 `CGColor`，转成 sRGB 分量后落成纯值类型，
/// 让视图层与测试都不必碰 CoreGraphics 对象。
struct RemindersListTint: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    /// 取不到清单颜色时的回退（白 alpha 圆底，与 `IconCircleBadge` 常态同值）。
    static let fallback = RemindersListTint(red: 1, green: 1, blue: 1, opacity: 0.14)
}

/// 一个提醒清单的纯值快照。
struct RemindersListDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let color: RemindersListTint
    /// 只读清单（共享列表等）不允许写：块内不提供勾选，避免必然失败的写入。
    let allowsContentModifications: Bool
}

// MARK: - 条目快照（`EKReminder` 的纯值快照）

/// 一条提醒的纯值快照。**只携带渲染与筛选需要的字段**，不持有 `EKReminder`——
/// 视图与测试因此都不依赖 EventKit，也使跨隔离域传递成为可能（`EKReminder`
/// 不是 `Sendable`）。
struct RemindersItem: Identifiable, Equatable, Sendable {
    /// `calendarItemIdentifier`。**必须**用它作 `ForEach` 的 id，不能用数组下标：
    /// EventKit 的返回序无文档承诺，下标会让行在顺序抖动时错位复用。
    let id: String
    let title: String
    /// 有重复规则 → 行尾画 `arrow.triangle.2.circlepath`（参考截图里的那个符号）。
    let isRepeating: Bool
    let isCompleted: Bool
    /// `EKReminder.priority`：0 = 无，1 = `!!!`，5 = `!!`，9 = `!`。
    let priority: Int
    let dueDate: Date?
    let listID: String?
}

// MARK: - 筛选与计数口径（纯函数，只依赖注入的 `now` 与 `calendar`）

enum RemindersLogic {
    /// 某条目是否属于该数据源。**已完成项恒定不属于任何源**——它们既不进列表
    /// 也不计入计数（决策 D7）。
    static func matches(
        _ item: RemindersItem,
        source: RemindersSource,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard !item.isCompleted else { return false }
        switch source {
        case let .list(identifier):
            return item.listID == identifier
        case let .smart(smart):
            switch smart {
            case .today:
                // 含逾期：到期日严格早于"明天零点"即可，无下界。
                guard let due = item.dueDate else { return false }
                return due < startOfTomorrow(for: now, calendar: calendar)
            case .scheduled:
                return item.dueDate != nil
            case .important:
                return item.priority != 0
            case .all:
                return true
            }
        }
    }

    /// 过滤出该源应当显示的条目。**保持输入顺序**（= EventKit 返回序，决策 D6），
    /// 不做任何重排。
    static func visibleItems(
        _ items: [RemindersItem],
        source: RemindersSource,
        now: Date,
        calendar: Calendar
    ) -> [RemindersItem] {
        items.filter { matches($0, source: source, now: now, calendar: calendar) }
    }

    /// 今天 24:00 的绝对时刻（次日零点）。
    static func startOfTomorrow(for now: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
    }

    /// `EKReminder.dueDateComponents` → 绝对时刻。
    ///
    /// 必须要求年月日齐全。`Calendar.date(from:)` 对缺失字段取默认值（年 1、月 1、
    /// 日 1），只给了时分的组件也能"成功"解析出一个纪元附近的**假日期**——那会让
    /// 一条没有到期日的提醒凭空出现在「今天」里。EventKit 在有到期日时至少给出
    /// 年月日，所以这道门槛不会误杀真实数据。
    static func dueDate(from components: DateComponents?, calendar: Calendar) -> Date? {
        guard let components,
              components.year != nil,
              components.month != nil,
              components.day != nil else {
            return nil
        }
        return calendar.date(from: components)
    }
}
