import Combine
import Foundation
import NotchCenterKit

// MARK: - 插件内共享模型（参考 CaffeinatePlugin 的 KeepAwakeModel 单例模式）
//
// 同一份块视图会被宿主放进每块屏的抽屉树，用量抓取与缓存必须全局只有
// 一份（否则每屏各自轮询会重复打 opencode.ai）；视图只读 @Published 属性。

@MainActor
final class OpenCodeUsageStore: ObservableObject {
    static let shared = OpenCodeUsageStore()

    /// 抓取失败后的冷却期，避免轮询打爆 opencode.ai（对齐参考实现的 60 s）。
    static let failureCooldown: TimeInterval = 60
    /// 轮询循环检查"是否过期"的间隔。
    static let pollCheckInterval: TimeInterval = 30

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isLoading = false
    /// 用户可见的错误文案；nil 表示无错误。绝不含 cookie 内容。
    @Published private(set) var errorMessage: String?

    private(set) var config = OpenCodeUsageConfig()

    private var stateStore: StateStore?
    private var pollingTask: Task<Void, Never>?
    private var lastSuccessAt: Date?
    private var nextAllowedAt: Date?

    /// 插件级共享存储（attachServices 注入）：供放置实例清理等非视图路径
    /// 派生 placementScope 用。视图内一律走 BlockContext.placementStore。
    var sharedStateStore: StateStore? { stateStore }

    var isConfigured: Bool { OpenCodeUsageConfigLogic.isConfigured(config) }

    // MARK: 生命周期

    /// 宿主 attachServices 注入 StateStore；幂等。
    func resolve(stateStore: StateStore) {
        guard self.stateStore == nil else { return }
        self.stateStore = stateStore
        loadPersistedConfig()
        startPolling()
    }

    /// 插件被禁用时停止后台轮询。
    func suspend() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func loadPersistedConfig() {
        guard let stateStore else { return }
        if let stored = stateStore.object(OpenCodeUsageConfig.self, forKey: OpenCodeUsageConfigLogic.storeKey) {
            config = stored
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshIfNeeded()
                try? await Task.sleep(for: .seconds(Self.pollCheckInterval))
            }
        }
    }

    // MARK: 抓取编排

    /// 缓存未过期或处于失败冷却期时跳过。
    func refreshIfNeeded() async {
        guard !isLoading else { return }
        if let lastSuccessAt,
           Date().timeIntervalSince(lastSuccessAt) < OpenCodeUsageConfigLogic.effectiveCacheTTL(config) {
            return
        }
        if let nextAllowedAt, Date() < nextAllowedAt { return }
        await performFetch()
    }

    /// 手动刷新：无视冷却与缓存 TTL 立即拉取最新数据。
    /// 先清掉旧快照与错误态，让 UI 立刻进入加载反馈而不是继续展示旧数据。
    func forceRefresh() {
        nextAllowedAt = nil
        lastSuccessAt = nil
        snapshot = nil
        errorMessage = nil
        Task { await performFetch() }
    }

    private func performFetch() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await OpenCodeUsageClient.fetch(config: config)
            snapshot = fresh
            errorMessage = nil
            lastSuccessAt = fresh.updatedAt
        } catch {
            nextAllowedAt = Date().addingTimeInterval(Self.failureCooldown)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 配置写入

    /// 保存 cookie / workspaceID / baseURL。cookie 为空表示保留现值；
    /// 成功后立刻失效缓存强制刷新，返回 nil 或用户可见错误文案。
    @discardableResult
    func saveConfig(cookie: String?, workspaceID: String?, baseURL: String?) -> String? {
        var next = config
        if let cookie {
            if cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next.cookie = nil
            } else {
                next.cookie = OpenCodeUsageConfigLogic.normalizeCookie(cookie)
                if next.cookie == nil { return L("error.badCookie") }
            }
        }
        if let workspaceID {
            let trimmed = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            next.workspaceID = trimmed.isEmpty ? nil : trimmed
        }
        if let baseURL {
            let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            next.baseURL = trimmed.isEmpty ? nil : trimmed
        }

        do {
            try stateStore?.setObject(next, forKey: OpenCodeUsageConfigLogic.storeKey)
        } catch {
            return LF("error.persist", error.localizedDescription)
        }
        config = next
        // 新配置立即可用：清掉旧缓存、错误与冷却。
        snapshot = nil
        errorMessage = nil
        lastSuccessAt = nil
        nextAllowedAt = nil
        forceRefresh()
        return nil
    }

    func clearConfig() {
        _ = saveConfig(cookie: "", workspaceID: "", baseURL: "")
    }

    // MARK: 掩码视图（settings 界面只展示尾 4 位）

    var maskedCookie: OpenCodeUsageConfigLogic.MaskedSecret {
        OpenCodeUsageConfigLogic.maskedSecret(config.cookie)
    }

    var maskedWorkspaceID: OpenCodeUsageConfigLogic.MaskedSecret {
        OpenCodeUsageConfigLogic.maskedSecret(config.workspaceID)
    }
}
