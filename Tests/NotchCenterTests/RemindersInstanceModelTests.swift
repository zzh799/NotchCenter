import Foundation
import NotchCenterKit
import Testing

@testable import RemindersPlugin

// MARK: - 实例模型：写入、刷新调度与撤销条的时序回归
//
// 全程注入假数据源，**绝不触碰真实 `EKEventStore`**——`fetchReminders` 在未授权时
// 会拉起系统授权窗，测试里弹窗是不可接受的副作用（同宿主 `PermissionStatusProviding`
// 的既有做法）。
//
// 异步链路靠 `RemindersInstanceModel.refreshAndWait()` 确定化，不用 sleep 轮询。

@MainActor
private final class FakeRemindersDataSource: RemindersDataSource {
    /// 写入的注入行为。
    enum WriteFailure {
        case none
        /// 目标清单只读（共享列表未授权写）。
        case readOnly
        /// 条目已不存在（别处删掉了）。
        case missing
    }

    var lists: [RemindersListDescriptor]
    var stored: [RemindersItem]
    /// 为假时：写入被记录但不改 `stored`，用来复现"写成功但 store 还没反映"的窗口。
    var appliesWritesImmediately = true
    var writeFailure: WriteFailure = .none

    private(set) var fetchCount = 0
    private(set) var writes: [(completed: Bool, id: String)] = []

    init(lists: [RemindersListDescriptor], items: [RemindersItem]) {
        self.lists = lists
        self.stored = items
    }

    func listDescriptors() -> [RemindersListDescriptor] { lists }

    func fetchItems(for source: RemindersSource) async -> [RemindersItem] {
        fetchCount += 1
        return stored
    }

    func setCompleted(_ completed: Bool, itemIdentifier: String) throws {
        writes.append((completed, itemIdentifier))
        switch writeFailure {
        case .none:
            break
        case .readOnly:
            throw RemindersDataSourceError.readOnlyList
        case .missing:
            throw RemindersDataSourceError.itemNotFound
        }
        guard appliesWritesImmediately else { return }
        apply(completed: completed, to: itemIdentifier)
    }

    /// 把之前记录但未落地的写入补上——复现"store 稍后才反映"的窗口。
    func flushRecordedWrites() {
        for write in writes {
            apply(completed: write.completed, to: write.id)
        }
    }

    private func apply(completed: Bool, to identifier: String) {
        guard let index = stored.firstIndex(where: { $0.id == identifier }) else { return }
        let old = stored[index]
        stored[index] = RemindersItem(
            id: old.id,
            title: old.title,
            isRepeating: old.isRepeating,
            isCompleted: completed,
            priority: old.priority,
            dueDate: old.dueDate,
            listID: old.listID)
    }

    func startObservingExternalChanges(_ handler: @escaping @MainActor () -> Void) {}
    func stopObservingExternalChanges() {}
}

// MARK: 测试夹具

@MainActor
private struct Harness {
    let dataSource = FakeRemindersDataSource(
        lists: [
            RemindersListDescriptor(
                id: "LIST-A", title: "Life",
                color: RemindersListTint(red: 1, green: 0.4, blue: 0.2, opacity: 1),
                allowsContentModifications: true),
            RemindersListDescriptor(
                id: "LIST-B", title: "Shared",
                color: RemindersListTint(red: 0.3, green: 0.6, blue: 1, opacity: 1),
                allowsContentModifications: false),
        ],
        items: [
            RemindersItem(
                id: "i1", title: "Noname", isRepeating: true, isCompleted: false,
                priority: 0, dueDate: nil, listID: "LIST-A"),
            RemindersItem(
                id: "i2", title: "Yoga", isRepeating: false, isCompleted: false,
                priority: 0, dueDate: nil, listID: "LIST-A"),
            RemindersItem(
                id: "i3", title: "Meditate", isRepeating: true, isCompleted: false,
                priority: 0, dueDate: nil, listID: "LIST-A"),
        ])

    var permission: PermissionStatus = .authorized

    func model(
        store: StateStore? = nil,
        placementID: String = "placement-1"
    ) -> RemindersInstanceModel {
        // 先取局部快照再捕获：闭包捕获局部 `let` 是按值，语义明确。
        let dataSource = self.dataSource
        let permission = self.permission
        return RemindersInstanceModel(
            placementID: placementID,
            blockID: "reminders.list",
            store: store,
            dataSourceProvider: { dataSource },
            permissionProvider: { permission })
    }
}

@MainActor
struct RemindersInstanceModelTests {
    private func temporaryStore() throws -> (StateStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reminders-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (StateStore(rootDirectory: directory), directory)
    }

    // MARK: 权限纪律

    @Test func unpermittedModelNeverTouchesTheDataSource() async {
        var harness = Harness()
        harness.permission = .denied
        let model = harness.model()

        await model.refreshAndWait()

        #expect(harness.dataSource.fetchCount == 0, "未授权时一次取数都不该发生")
        #expect(model.items.isEmpty)
        #expect(model.permission == .denied)
    }

    @Test func activateLoadsItemsWhenAuthorized() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))

        await model.refreshAndWait()

        #expect(model.items.map(\.id) == ["i1", "i2", "i3"])
        #expect(model.undoBar == nil)
        #expect(!model.sourceRemoved)
    }

    // MARK: 勾选

    @Test func completingWritesThenRefetches() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()
        let fetchesBefore = harness.dataSource.fetchCount

        model.complete(model.items[1])
        await model.refreshAndWait()

        #expect(harness.dataSource.writes.count == 1)
        #expect(harness.dataSource.writes.first?.completed == true)
        #expect(harness.dataSource.writes.first?.id == "i2")
        // 自发写入不靠通知：save 成功即本地重拉。
        #expect(harness.dataSource.fetchCount > fetchesBefore)
        #expect(model.items.map(\.id) == ["i1", "i3"])
        #expect(model.notice == nil)
    }

    @Test func writeFailureLeavesItemInPlaceAndShowsNotice() async {
        let harness = Harness()
        harness.dataSource.writeFailure = .readOnly
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()

        model.complete(model.items[0])
        await model.refreshAndWait()

        #expect(model.items.map(\.id) == ["i1", "i2", "i3"], "写失败时条目必须还在原位")
        #expect(model.notice == L("notice.readOnly"))
        #expect(model.undoBar == nil, "没写进去就不该给撤销入口")
    }

    @Test func missingItemFailureMapsToItsOwnMessage() async {
        let harness = Harness()
        harness.dataSource.writeFailure = .missing
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()

        model.complete(model.items[0])
        await model.refreshAndWait()

        #expect(model.notice == L("notice.itemMissing"))
    }

    // MARK: 撤销条时序（决策 D10）

    /// 撤销条的起算点是"条目**真的**从列表消失"，不是"点击的那一刻"：
    /// 写进去了但 store 还没反映（条目仍在列表里）时，不该出现撤销条。
    @Test func undoBarWaitsUntilTheItemActuallyLeftTheList() async {
        let harness = Harness()
        harness.dataSource.appliesWritesImmediately = false
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()

        model.complete(model.items[0])
        await model.refreshAndWait()

        #expect(model.items.map(\.id) == ["i1", "i2", "i3"], "store 没反映，条目还在")
        #expect(model.undoBar == nil, "条目还没走，撤销条不该起算")

        // store 追上了：重拉后条目消失，撤销条这时才出现。
        harness.dataSource.flushRecordedWrites()
        await model.refreshAndWait()

        #expect(model.items.map(\.id) == ["i2", "i3"])
        #expect(model.undoBar?.itemID == "i1")
        #expect(model.undoBar?.title == "Noname")
    }

    @Test func undoRestoresTheItemAndClearsTheBar() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()

        model.complete(model.items[0])
        await model.refreshAndWait()
        #expect(model.undoBar != nil)

        model.undoCompletion()
        await model.refreshAndWait()

        #expect(harness.dataSource.writes.last?.completed == false)
        #expect(harness.dataSource.writes.last?.id == "i1")
        #expect(model.items.map(\.id) == ["i1", "i2", "i3"])
        #expect(model.undoBar == nil, "撤销后条不可留着")
    }

    @Test func undoWriteFailureSurfacesNotice() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()
        model.complete(model.items[0])
        await model.refreshAndWait()
        #expect(model.undoBar != nil)

        harness.dataSource.writeFailure = .readOnly
        model.undoCompletion()
        await model.refreshAndWait()

        #expect(model.notice == L("notice.readOnly"))
        // 撤销失败：条目仍停在"已完成"那一侧，不会被凭空拉回来。
        #expect(!model.items.contains { $0.id == "i1" })
    }

    // MARK: 刷新调度（决策 D9）

    /// 同一同步段内连发多次重拉请求，只应拉起**一次**取数：首个请求起任务，
    /// 其余都在任务真正开始前被吸收进这一次（drain 在每轮开头清 pending）。
    @Test func rapidRefreshRequestsCoalesceIntoOneFetch() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()

        let before = harness.dataSource.fetchCount
        model.requestRefresh()
        model.requestRefresh()
        model.requestRefresh()
        await model.refreshAndWait()

        #expect(harness.dataSource.fetchCount - before == 1)
    }

    /// 但"合并"不能变成"吞掉"：上一次刷新结束后再请求，必须能真的再拉一次。
    @Test func refreshAfterDrainStillFetches() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()
        let before = harness.dataSource.fetchCount

        await model.refreshAndWait()
        #expect(harness.dataSource.fetchCount - before == 1)

        await model.refreshAndWait()
        #expect(harness.dataSource.fetchCount - before == 2)
    }

    @Test func externalChangeEventuallyTriggersARefresh() async throws {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()
        let before = harness.dataSource.fetchCount

        model.handleExternalChange()
        #expect(harness.dataSource.fetchCount == before, "节流窗内不该立刻拉")

        // 这里唯一需要真等的地方：等的是被测的节流常量本身。
        try await Task.sleep(for: RemindersMetrics.externalRefreshThrottle + .milliseconds(150))
        await model.refreshAndWait()

        #expect(harness.dataSource.fetchCount > before)
    }

    // MARK: 数据源切换与失效

    @Test func missingListIsReportedInsteadOfSilentlyFallingBack() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("GONE"))

        await model.refreshAndWait()

        #expect(model.sourceRemoved, "清单没了必须显式报告")
        #expect(model.source == .list("GONE"), "不得静默换成别的清单")
        #expect(model.items.isEmpty)
    }

    @Test func switchingSourceClearsTheUndoBar() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()
        model.complete(model.items[0])
        await model.refreshAndWait()
        #expect(model.undoBar != nil)

        model.updateSource(.list("LIST-B"))
        await model.refreshAndWait()

        #expect(model.undoBar == nil, "换源后旧撤销条指向的条目已不在视野里")
        // Shared 清单里没有条目：假数据源的全量条目都属于 LIST-A。
        #expect(model.items.isEmpty)
    }

    @Test func sourceSelectionPersistsToThePlacementStore() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Harness().model(store: store)
        first.updateSource(.list("LIST-B"))
        await first.refreshAndWait()

        // 换个实例读同一份存储：选择必须跟着块实例走。
        let second = Harness().model(store: store, placementID: "placement-1")
        #expect(second.source == .list("LIST-B"))
    }

    @Test func unsetSourceFallsBackToToday() {
        let model = Harness().model()
        #expect(model.source == .smart(.today))
    }

    // MARK: 收尾

    @Test func suspendClearsTransientLayersAndKeepsData() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()
        model.complete(model.items[0])
        await model.refreshAndWait()
        #expect(model.undoBar != nil)

        model.suspend()

        #expect(model.undoBar == nil)
        #expect(model.notice == nil)
        // 已取数据留着：重新可见时 activate() 会幂等校准，不必白拉一次。
        #expect(model.items.map(\.id) == ["i2", "i3"])
    }

    @Test func shutdownKeepsDataAndIsIdempotent() async {
        let harness = Harness()
        let model = harness.model()
        model.updateSource(.list("LIST-A"))
        await model.refreshAndWait()

        model.shutdown()
        model.shutdown()

        #expect(!model.items.isEmpty, "硬收尾只停任务，不清已取数据")
    }
}
