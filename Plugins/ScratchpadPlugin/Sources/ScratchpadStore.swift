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
@MainActor
final class ScratchpadStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem]
    @Published private var availabilityByID: [UUID: Bool] = [:]

    private static let storageKey = "shelf.items.v1"
    private static let maximumItemCount = 100
    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
        items = stateStore.object([FileShelfItem].self, forKey: Self.storageKey) ?? []
    }

    @discardableResult
    func acceptDrop(_ urls: [URL]) -> Bool {
        let fileURLs = FileDropPayload.normalizedFileURLs(from: urls)
        guard !fileURLs.isEmpty else { return false }

        _ = add(fileURLs)
        return true
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var knownPaths = Set(items.compactMap { resolvedURL(for: $0)?.standardizedFileURL.path })
        var addedItems: [FileShelfItem] = []

        for url in urls where url.isFileURL {
            let standardizedURL = url.standardizedFileURL

            if items.contains(where: {
                resolvedURL(for: $0)?.standardizedFileURL.path == standardizedURL.path
            }) {
                continue
            }

            guard items.count + addedItems.count < Self.maximumItemCount else { break }
            guard knownPaths.insert(standardizedURL.path).inserted else { continue }
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
        try? stateStore.setObject(items, forKey: Self.storageKey)
    }
}
