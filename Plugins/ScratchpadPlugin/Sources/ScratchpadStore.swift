import Combine
import Foundation
import NotchCenterKit

@MainActor
final class ScratchpadWorkspaceState: ObservableObject {
    @Published var isShelfDropTargeted = false
    @Published var isDraggingShelfItem = false
    @Published var isPreviewingShelfItem = false
}

struct FileShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let bookmarkData: Data?
    let fallbackPath: String
    let originalName: String
    let addedAt: Date
    let isDirectory: Bool?
    let fileExtension: String?

    init(url: URL) {
        id = UUID()
        // File bookmarks can block the main thread when they are created
        // synchronously inside AppKit's drop callback. The shelf is temporary,
        // so keeping the normalized path is sufficient and avoids that stall.
        bookmarkData = nil
        fallbackPath = url.standardizedFileURL.path
        originalName = url.lastPathComponent
        addedAt = Date()
        isDirectory = url.hasDirectoryPath
        fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension
    }
}

/// 文件暂存区数据层：只保存文件**引用路径**（文档 §8 契约：不复制、不移动、不删除用户原文件）。
/// 数据经 StateStore 持久化（文档 §4.6）；上限 100 项。
///
/// 同一块类型可放置多个实例：每个放置实例的条目持久化在该实例私有的
/// placementScope（`<pluginData>/placements/<placementID>/`），互不干扰；
/// stateStore 为 nil（placementID 非法，损坏布局数据）时退化为不持久化的会话内存。
@MainActor
final class ScratchpadStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem]
    @Published private var availabilityByID: [UUID: Bool] = [:]

    static let storageKey = "shelf.items.v1"
    private static let maximumItemCount = 100
    private let stateStore: StateStore?

    init(stateStore: StateStore?) {
        self.stateStore = stateStore
        items = stateStore?.object([FileShelfItem].self, forKey: Self.storageKey) ?? []
    }

    /// 旧版插件级数据的实例迁移入口：仅当当前为空时整体接管。
    func seedIfEmpty(_ newItems: [FileShelfItem]) {
        guard items.isEmpty else { return }
        items = newItems
        save()
    }

    @discardableResult
    func acceptDrop(_ urls: [URL]) -> Bool {
        let fileURLs = FileDropPayload.normalizedFileURLs(from: urls)
        guard !fileURLs.isEmpty else { return false }

        add(fileURLs)
        return true
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        // knownPaths seeds with every existing shelf path, so a failed insert
        // means "already on shelf" and no second linear scan is needed.
        var knownPaths = Set(items.compactMap { resolvedURL(for: $0)?.standardizedFileURL.path })
        var addedItems: [FileShelfItem] = []

        for url in urls where url.isFileURL {
            let standardizedURL = url.standardizedFileURL
            guard knownPaths.insert(standardizedURL.path).inserted else { continue }
            guard items.count + addedItems.count < Self.maximumItemCount else { break }
            addedItems.append(FileShelfItem(url: standardizedURL))
        }

        guard !addedItems.isEmpty else { return 0 }
        items.append(contentsOf: addedItems)
        save()
        return addedItems.count
    }

    func remove(_ item: FileShelfItem) {
        remove(ids: [item.id])
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            availabilityByID[id] = nil
        }
        save()
    }

    func removeAll() {
        items.removeAll()
        availabilityByID.removeAll()
        save()
    }

    func resolvedURL(for item: FileShelfItem) -> URL? {
        URL(fileURLWithPath: item.fallbackPath).standardizedFileURL
    }

    func isAvailable(_ item: FileShelfItem) -> Bool {
        availabilityByID[item.id] ?? true
    }

    func refreshAvailability(_ item: FileShelfItem) async {
        let path = item.fallbackPath
        let isAvailable = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value

        guard items.contains(where: { $0.id == item.id }) else { return }
        availabilityByID[item.id] = isAvailable
    }

    private func save() {
        try? stateStore?.setObject(items, forKey: Self.storageKey)
    }
}

// MARK: - 放置实例注册表（每实例独立暂存区）
//
// 宿主把同一份块视图放进每块屏的抽屉树（多屏多份），清空确认浮窗又可能
// 同时引用同一实例——按 placementID 缓存唯一的 ObservableObject，让所有
// 副本观察同一对象（沿用插件内共享状态 × 每屏一份视图树的约束）。

@MainActor
final class ScratchpadInstanceRegistry {
    static let shared = ScratchpadInstanceRegistry()

    private var storesByID: [String: ScratchpadStore] = [:]

    /// 插件级共享存储：迁移旧版全局暂存数据，placementWasRemoved 时清理实例目录。
    private(set) var pluginStateStore: StateStore?

    init() {}

    func attach(pluginStateStore: StateStore) {
        self.pluginStateStore = pluginStateStore
    }

    /// 取（或创建）某放置实例的暂存区。stateStore 是插件级共享存储，
    /// 内部派生出该实例的 placementScope。
    func store(placementID: String, stateStore: StateStore) -> ScratchpadStore {
        if let store = storesByID[placementID] { return store }
        let store = ScratchpadStore(stateStore: stateStore.placementScope(placementID: placementID))
        migrateLegacyItemsIfNeeded(into: store)
        storesByID[placementID] = store
        return store
    }

    /// 紧凑角标：全部实例条目之和 + 尚未迁移的旧版插件级残留。
    var totalItemCount: Int {
        storesByID.values.reduce(0) { $0 + $1.items.count } + (legacyItems?.count ?? 0)
    }

    /// 紧凑图标「清空暂存区」：清空所有实例与旧版残留（只移除路径记录）。
    func removeAll() {
        for store in storesByID.values {
            store.removeAll()
        }
        pluginStateStore?.removeValue(forKey: ScratchpadStore.storageKey)
    }

    /// 实例被移除时丢弃内存缓存并删除其持久化数据（只移除路径记录，原文件不受影响）。
    func discard(placementID: String) {
        storesByID.removeValue(forKey: placementID)
        pluginStateStore?
            .placementScope(placementID: placementID)?
            .removeValue(forKey: ScratchpadStore.storageKey)
    }

    // MARK: 旧版迁移

    private var legacyItems: [FileShelfItem]? {
        guard let pluginStateStore else { return nil }
        return pluginStateStore.object([FileShelfItem].self, forKey: ScratchpadStore.storageKey)
    }

    /// 旧版本把暂存项存在插件级 store（所有块共享一份）。首个新实例创建时
    /// 一次性搬进该实例并删除旧记录；后续实例自然从空开始。
    private func migrateLegacyItemsIfNeeded(into store: ScratchpadStore) {
        guard let pluginStateStore, let legacyItems, !legacyItems.isEmpty else { return }
        defer { pluginStateStore.removeValue(forKey: ScratchpadStore.storageKey) }
        if store.items.isEmpty {
            store.seedIfEmpty(legacyItems)
        }
    }
}
