import AppKit
import EventKit
import Foundation
import NotchCenterKit

// MARK: - 数据源抽象
//
// 所有 EventKit 访问都在这一层后面。理由有二：
// 1. 单测**绝不能**触碰真实 `EKEventStore`——`fetchReminders` 在未授权时会拉起
//    系统授权窗，测试里弹窗是不可接受的副作用（同宿主 `PermissionStatusProviding`
//    的既有做法：生产实现读真实状态，测试注入假实现）；
// 2. `EKReminder` / `EKCalendar` 都不是 `Sendable`，把它们挡在这一层外，
//    上层（视图、模型、测试）只处理 `RemindersItem` / `RemindersListDescriptor`
//    这两个纯值快照。

enum RemindersDataSourceError: Error, Equatable {
    /// 勾选时 `calendarItem(withIdentifier:)` 找不到该条目（已被别处删掉）。
    case itemNotFound
    /// 目标清单是只读的（共享列表未授予写权限等），写入必然失败。
    case readOnlyList
}

@MainActor
protocol RemindersDataSource: AnyObject {
    /// 全部提醒清单（顺序沿用 EventKit 返回序）。
    func listDescriptors() -> [RemindersListDescriptor]
    /// 拉取某数据源作用域内的条目快照。**不做源的精确筛选**（含已完成项）——
    /// 筛选口径统一在 `RemindersLogic`，避免"EventKit 谓词"与"纯逻辑"两处各判一次
    /// 而悄悄分叉。
    func fetchItems(for source: RemindersSource) async -> [RemindersItem]
    /// 写入完成态。抛错即表示未落盘，调用方回滚 UI。
    func setCompleted(_ completed: Bool, itemIdentifier: String) throws
    /// 订阅**外部**变更（Reminders.app 里的改动、iCloud 同步）。
    /// 自发的写入不靠它——见 `RemindersCore` 的刷新调度。
    func startObservingExternalChanges(_ handler: @escaping @MainActor () -> Void)
    func stopObservingExternalChanges()
}

// MARK: - EventKit 生产实现

/// 生产数据源。整个插件进程内**只建一个**（`RemindersCore` 持有）：`EKEventStore`
/// 官方建议应用内复用单例，且多实例各自持 store 会各自收一份变更通知。
@MainActor
final class EventKitRemindersDataSource: RemindersDataSource {
    /// `EKEventStore` 未标 `Sendable`，但 EventKit 的读写调用由系统保证线程安全；
    /// 本类只在主执行者上访问它，跨 `await` 的"发送"告警是 Swift 6 的保守判定。
    /// 与宿主 `PermissionCenter` 对同一个类做的豁免同源。
    ///
    /// 构造函数**不会**拉起任何系统授权窗；真正的触发点只有 `fetchItems` 与
    /// `setCompleted`（两者都只在已授权路径上被调用，见 `RemindersCore`）。
    nonisolated(unsafe) private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    func listDescriptors() -> [RemindersListDescriptor] {
        store.calendars(for: .reminder).map { calendar in
            RemindersListDescriptor(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                color: Self.color(of: calendar),
                allowsContentModifications: calendar.allowsContentModifications)
        }
    }

    func fetchItems(for source: RemindersSource) async -> [RemindersItem] {
        let calendars = relevantCalendars(for: source)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)

        // `fetchReminders` 在本 SDK（macOS 15.5 / Xcode 16.4）只有 completion 形式，
        // 没有 async 重载，得自己桥。桥接的载荷必须是 `Sendable`——`EKReminder`
        // 不是，所以映射在回调闭包内完成，跨出边界的只有 `RemindersItem`。
        return await withCheckedContinuation { continuation in
            let completion: @Sendable ([EKReminder]?) -> Void = { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.snapshot(of:)))
            }
            // 返回值是本次请求的取消令牌（`Any`），这里不持有、不需要取消。
            _ = store.fetchReminders(matching: predicate, completion: completion)
        }
    }

    func setCompleted(_ completed: Bool, itemIdentifier: String) throws {        guard let reminder = store.calendarItem(withIdentifier: itemIdentifier) as? EKReminder else {
            throw RemindersDataSourceError.itemNotFound
        }
        if completed, let calendar = reminder.calendar, !calendar.allowsContentModifications {
            throw RemindersDataSourceError.readOnlyList
        }
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        try store.save(reminder, commit: true)
    }

    func startObservingExternalChanges(_ handler: @escaping @MainActor () -> Void) {
        stopObservingExternalChanges()
        // 通知粗粒度、不描述变更内容（Apple 文档明确 "Individual changes are not
        // described"），只能收到后整体重拉；节流与幂等由 `RemindersCore` 做。
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            // queue: .main 保证已在主线程；闭包本身非 MainActor，故显式断言隔离域
            // 后再调插件侧（@MainActor）处理器。
            MainActor.assumeIsolated { handler() }
        }
    }

    func stopObservingExternalChanges() {
        guard let changeObserver else { return }
        NotificationCenter.default.removeObserver(changeObserver)
        self.changeObserver = nil
    }

    // MARK: 纯映射（nonisolated：要在 EventKit 的回调线程上执行）

    /// 该数据源的作用域清单：具体清单 → 那一个；智能视图 → 全部清单。
    private func relevantCalendars(for source: RemindersSource) -> [EKCalendar] {
        let all = store.calendars(for: .reminder)
        guard let identifier = source.listIdentifier else { return all }
        return all.filter { $0.calendarIdentifier == identifier }
    }

    nonisolated static func snapshot(of reminder: EKReminder) -> RemindersItem {
        RemindersItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            isRepeating: reminder.hasRecurrenceRules,
            isCompleted: reminder.isCompleted,
            priority: reminder.priority,
            dueDate: RemindersLogic.dueDate(
                from: reminder.dueDateComponents, calendar: .autoupdatingCurrent),
            listID: reminder.calendar?.calendarIdentifier)
    }

    /// 清单颜色 → sRGB 纯值分量。取不到（色彩空间缺失等）时回退白 alpha 圆底。
    nonisolated static func color(of calendar: EKCalendar) -> RemindersListTint {
        guard let converted = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB) else {
            return .fallback
        }
        return RemindersListTint(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            opacity: Double(converted.alphaComponent))
    }
}
