import AppKit
import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 实例配置（每实例单独设置：数据源）

@MainActor
enum RemindersInstanceConfig {
    /// placementStore 里的配置键。
    static let sourceKey = "config.source"

    /// 载入该实例绑定的数据源；无记录 / 解码失败（含旧版字段形状）回退「今天」。
    static func loadSource(from store: StateStore?) -> RemindersSource {
        guard let store else { return .fallback }
        return store.object(RemindersSource.self, forKey: sourceKey) ?? .fallback
    }

    static func saveSource(_ source: RemindersSource, to store: StateStore?) {
        try? store?.setObject(source, forKey: sourceKey)
    }
}

// MARK: - 放置实例模型（同一实例的所有视图副本观察同一个对象）

/// 一个块放置实例的全部可观察状态。多屏副本、设置浮窗、块视图都观察同一个
/// 实例（由 `RemindersCore` 按 `placementID` 注册缓存），否则多屏之间会各拉各的。
///
/// 刷新纪律（决策 D9）：
/// - **无乐观状态**：列表内容一律来自"重拉结果"，类里不存"本地已删除"的影子集合；
/// - 自发写入（勾选 / 撤销）成功后**本地立即触发一次重拉**，不等 `EKEventStoreChanged`
///   ——写入已完成是确定事实，靠通知等于把延迟交给未定义的投递时机；
/// - `EKEventStoreChanged` 只作为**外部变更**入口，带节流合并；
/// - 重拉幂等：进行中再触发则置 pending，本次完成后补跑一次。
@MainActor
final class RemindersInstanceModel: ObservableObject {
    /// 底部撤销条内容（决策 D10：起算点是"条目真的从列表里消失"那一刻）。
    struct UndoBar: Equatable {
        let itemID: String
        let title: String
    }

    let placementID: String
    let blockID: String

    @Published private(set) var source: RemindersSource
    @Published private(set) var permission: PermissionStatus
    /// 全部可选清单（切换入口与设置界面共用；顺序沿用 EventKit 返回序）。
    @Published private(set) var lists: [RemindersListDescriptor] = []
    @Published private(set) var items: [RemindersItem] = []
    /// 绑定的清单已从 Reminders 里消失。**不自动回退**到别的清单——静默换源会让
    /// 用户以为数据丢了。
    @Published private(set) var sourceRemoved = false
    @Published private(set) var undoBar: UndoBar?
    /// 一次性错误提示（写失败等）；由视图在若干秒后清掉。
    @Published private(set) var notice: String?

    private let configStore: StateStore?
    private let dataSourceProvider: @MainActor () -> RemindersDataSource?
    private let permissionProvider: @MainActor () -> PermissionStatus

    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var externalThrottleTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    /// 已提交但尚未在重拉结果里确认"离开了列表"的勾选。
    /// 值里的时刻只用于多条同时离开时挑最新一条进撤销条。
    private var pendingCompletions: [String: (title: String, requestedAt: Date)] = [:]

    init(
        placementID: String,
        blockID: String,
        store: StateStore?,
        dataSourceProvider: @escaping @MainActor () -> RemindersDataSource?,
        permissionProvider: @escaping @MainActor () -> PermissionStatus
    ) {
        self.placementID = placementID
        self.blockID = blockID
        self.configStore = store
        self.dataSourceProvider = dataSourceProvider
        self.permissionProvider = permissionProvider
        self.source = RemindersInstanceConfig.loadSource(from: store)
        // 只读 TCC 状态查询，不弹任何系统窗（权限纪律：查询与请求严格分开）。
        self.permission = permissionProvider()
    }

    // MARK: 生命周期

    /// 块视图首次出现时调用（`.task`）：必要时拉一次数据。
    func activate() {
        permission = permissionProvider()
        guard permission.isUsable else { return }
        requestRefresh()
    }

    /// App 重新激活 / 权限弹窗关闭后：授权可能刚变过，重取状态并按需加载。
    func refreshPermissionAndReload() {
        let latest = permissionProvider()
        let wasUsable = permission.isUsable
        permission = latest
        guard latest.isUsable, !wasUsable || items.isEmpty else { return }
        requestRefresh()
    }

    /// 抽屉不可见时调用（温存契约：收起**不**卸载视图树，`.onDisappear` 只表达
    /// 挂载 / 卸载，所以"用户看不到"这件事只能读 `\.isDrawerPresented`）。
    ///
    /// 只停掉"看不见就没意义"的东西：外部变更的延迟重拉、瞬时浮层。配置与已取
    /// 数据留着——重新可见时 `activate()` 会幂等校准，不必白拉一次。
    /// 幂等：收起与卸载会先后各触发一次。
    func suspend() {
        externalThrottleTask?.cancel()
        externalThrottleTask = nil
        undoTask?.cancel()
        undoTask = nil
        undoBar = nil
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    /// 实例被移除 / 插件被禁用时的硬收尾。幂等。
    func shutdown() {
        suspend()
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        pendingCompletions.removeAll()
    }

    // MARK: 数据源切换

    func updateSource(_ newSource: RemindersSource) {
        guard newSource != source else { return }
        source = newSource
        // 换源后旧撤销条指向的条目已不在视野里，留着只会误导。
        pendingCompletions.removeAll()
        undoTask?.cancel()
        undoTask = nil
        undoBar = nil
        RemindersInstanceConfig.saveSource(newSource, to: configStore)
        requestRefresh()
    }

    // MARK: 勾选与撤销

    /// 勾选完成：**立即**写 EventKit（不做延迟落盘——抽屉温存、App 可能随时退出，
    /// 延迟写入存在丢失窗口），成功后本地立即重拉。
    func complete(_ item: RemindersItem) {
        guard let dataSource = dataSourceProvider() else { return }
        do {
            try dataSource.setCompleted(true, itemIdentifier: item.id)
        } catch {
            presentNotice(Self.message(for: error))
            return
        }
        pendingCompletions[item.id] = (item.title, Date())
        requestRefresh()
    }

    func undoCompletion() {
        guard let bar = undoBar, let dataSource = dataSourceProvider() else { return }
        undoTask?.cancel()
        undoTask = nil
        undoBar = nil
        do {
            try dataSource.setCompleted(false, itemIdentifier: bar.itemID)
        } catch {
            presentNotice(Self.message(for: error))
            return
        }
        requestRefresh()
    }

    func dismissNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    // MARK: 刷新调度

    /// 幂等重拉入口：进行中则只置 pending，本次完成后补跑一次。
    func requestRefresh() {
        if refreshTask != nil {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.drainRefreshes()
        }
    }

    /// 请求一次刷新并等它（含被合并进来的后续刷新）跑完。
    ///
    /// 生产 UI 路径不需要它——视图只靠 `@Published` 驱动。它存在的唯一理由是让
    /// 测试能把"点一下 → 重拉 → 列表更新"这条异步链路变成可 `await` 的确定序列，
    /// 不必靠 sleep 轮询（轮询既慢又不稳）。
    func refreshAndWait() async {
        requestRefresh()
        guard let task = refreshTask else { return }
        await task.value
    }

    /// 外部变更（Reminders.app 改动 / iCloud 同步）入口：`EKEventStoreChanged` 粗粒度
    /// 且不描述变更内容，只能整体重拉，故加节流窗合并连发。
    func handleExternalChange() {
        externalThrottleTask?.cancel()
        externalThrottleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: RemindersMetrics.externalRefreshThrottle)
            } catch {
                return // 已被新的变更取消
            }
            self?.requestRefresh()
        }
    }

    private func drainRefreshes() async {
        repeat {
            refreshPending = false
            await performRefresh()
        } while refreshPending
        // 循环退出后到这一行之间没有 await，主执行者上不会插入其它任务，
        // 因此这里清空任务句柄不会漏掉刚置位的 pending。
        refreshTask = nil
    }

    private func performRefresh() async {
        permission = permissionProvider()
        guard permission.isUsable, let dataSource = dataSourceProvider() else {
            items = []
            sourceRemoved = false
            return
        }

        let descriptors = dataSource.listDescriptors()
        lists = descriptors
        if let identifier = source.listIdentifier,
           !descriptors.contains(where: { $0.id == identifier }) {
            sourceRemoved = true
            items = []
            return
        }
        sourceRemoved = false

        let fetched = await dataSource.fetchItems(for: source)
        let now = Date()
        let visible = RemindersLogic.visibleItems(
            fetched, source: source, now: now, calendar: .autoupdatingCurrent)
        applyRefresh(visible)
    }

    private func applyRefresh(_ visible: [RemindersItem]) {
        let visibleIDs = Set(visible.map(\.id))
        items = visible

        // 撤销条起算点：条目**真的**从列表消失的那一刻。用"已提交且不再出现"
        // 判定，而不是"点击即起算"——否则重拉偏慢时撤销条会在条目还看得见时
        // 就消失，状态自相矛盾。
        let departed = pendingCompletions
            .filter { !visibleIDs.contains($0.key) }
            .map { (id: $0.key, title: $0.value.title, requestedAt: $0.value.requestedAt) }
            .sorted { $0.requestedAt > $1.requestedAt }
        for entry in departed {
            pendingCompletions[entry.id] = nil
        }
        if let latest = departed.first {
            presentUndoBar(itemID: latest.id, title: latest.title)
        }
    }

    private func presentUndoBar(itemID: String, title: String) {
        undoTask?.cancel()
        undoBar = UndoBar(itemID: itemID, title: title)
        undoTask = Task { [weak self] in
            do {
                try await Task.sleep(for: RemindersMetrics.undoVisibleDuration)
            } catch {
                return // 被新的撤销条或撤销动作取消
            }
            self?.undoBar = nil
        }
    }

    private func presentNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            self?.notice = nil
        }
    }

    private static func message(for error: Error) -> String {
        // 先把存在类型收窄再 switch：`Error` 上不能直接匹配具体枚举的 case 模式。
        guard let dataSourceError = error as? RemindersDataSourceError else {
            return L("notice.writeFailed")
        }
        switch dataSourceError {
        case .readOnlyList:
            return L("notice.readOnly")
        case .itemNotFound:
            return L("notice.itemMissing")
        }
    }
}

// MARK: - 插件级核心（单份数据源 + 实例注册表）

/// 插件级单例：持有唯一 `RemindersDataSource`（`EKEventStore` 官方建议应用内复用），
/// 把外部变更广播给全部实例，并按 `placementID` 缓存实例模型。
@MainActor
final class RemindersCore {
    static let shared = RemindersCore()

    private var pluginStateStore: StateStore?
    private var hostController: (any HostController)?
    private var dataSource: RemindersDataSource?
    private var instances: [String: RemindersInstanceModel] = [:]
    private var activationObserver: NSObjectProtocol?

    private init() {}

    // MARK: 宿主注入

    func attach(stateStore: StateStore, hostController: any HostController) {
        self.pluginStateStore = stateStore
        self.hostController = hostController
    }

    // MARK: 实例模型

    func model(placementID: String, blockID: String) -> RemindersInstanceModel {
        if let existing = instances[placementID] { return existing }
        observeActivationIfNeeded()
        let model = RemindersInstanceModel(
            placementID: placementID,
            blockID: blockID,
            store: pluginStateStore?.placementScope(placementID: placementID),
            dataSourceProvider: { [weak self] in self?.dataSourceIfAuthorized() },
            permissionProvider: { [weak self] in self?.permissionStatus() ?? .notDetermined })
        instances[placementID] = model
        return model
    }

    func discard(placementID: String) {
        instances.removeValue(forKey: placementID)?.shutdown()
    }

    /// 插件被禁用时调用：停订阅、清实例。禁止在此卸载 bundle。
    func shutdown() {
        for model in instances.values { model.shutdown() }
        instances.removeAll()
        dataSource?.stopObservingExternalChanges()
        dataSource = nil
        // 摘掉激活观察者并清宿主引用：否则停用后每次 App 激活仍会经
        // `handleAppBecameActive` 重建 `EKEventStore`（常驻且无人使用）。
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        hostController = nil
    }

    // MARK: 权限

    func permissionStatus() -> PermissionStatus {
        hostController?.permissionStatus(of: .reminders) ?? .notDetermined
    }

    /// 缺权限时的**唯一**入口：宿主的「权限管理」弹窗。插件不代开系统设置。
    func presentPermissionGuide() {
        hostController?.presentPermissions([.reminders])
    }

    // MARK: 取数

    /// 惰性构造数据源：**只在已授权时**才建 `EKEventStore` 与订阅。
    /// 未授权时调 `fetchReminders` 本身就会拉起系统授权窗——权限纪律要求
    /// 装载期与未授权期都不碰这条路径。
    private func dataSourceIfAuthorized() -> RemindersDataSource? {
        guard permissionStatus().isUsable else { return nil }
        if let dataSource { return dataSource }
        let created = EventKitRemindersDataSource()
        created.startObservingExternalChanges { [weak self] in
            self?.broadcastExternalChange()
        }
        dataSource = created
        return created
    }

    private func broadcastExternalChange() {
        for model in instances.values { model.handleExternalChange() }
    }

    /// 用户去系统设置 / 权限弹窗授权后切回 App 时重取状态：否则块会一直停在
    /// 引导态，等于权限把功能多锁了一会儿。查询无副作用，安全。
    private func observeActivationIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                RemindersCore.shared.handleAppBecameActive()
            }
        }
    }

    private func handleAppBecameActive() {
        _ = dataSourceIfAuthorized()
        for model in instances.values { model.refreshPermissionAndReload() }
    }
}
