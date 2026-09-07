import Foundation
import NotchCenterKit

// MARK: - 盒实例模型（每放置实例一份，文档 §4.11）

/// 单个「快捷按钮盒」放置实例的动作集模型：有序动作 ID 数组，持久化到该
/// 实例的 placement 作用域存储（键 `quickActions`），与插件级共享存储隔离。
///
/// 同一放置实例的块视图、管理面板与宿主流入（sink）共用同一实例（身份稳定），
/// 视图随 `@Published actionIDs` 刷新。
@MainActor
final class BoxInstanceModel: ObservableObject {
    /// placement 作用域存储键。
    static let storageKey = "quickActions"

    @Published private(set) var actionIDs: [String]

    private let scope: StateStore?

    init(placementID: String, stateStore: StateStore) {
        scope = stateStore.placementScope(placementID: placementID)
        actionIDs = scope?.object([String].self, forKey: Self.storageKey) ?? []
    }

    /// 是否已收纳某动作。
    func contains(_ actionID: String) -> Bool {
        actionIDs.contains(actionID)
    }

    /// 追加动作（尾部）。已存在 → 空操作接受；容量超限 → 拒绝（不写入）。
    /// 容量由调用方按当前块跨度给出（见 `QuickButtonBoxLayout.capacity`）。
    func append(actionID: String, capacity: Int) -> Bool {
        guard !actionIDs.contains(actionID) else { return true }
        guard actionIDs.count < max(capacity, 0) else { return false }
        actionIDs.append(actionID)
        persist()
        return true
    }

    /// 移除指定动作。
    func remove(actionID: String) {
        guard actionIDs.contains(actionID) else { return }
        actionIDs.removeAll { $0 == actionID }
        persist()
    }

    /// 上移 / 下移一位（管理面板排序）。
    func move(from index: Int, by offset: Int) {
        guard actionIDs.indices.contains(index) else { return }
        let target = index + offset
        guard actionIDs.indices.contains(target) else { return }
        let moved = actionIDs.remove(at: index)
        actionIDs.insert(moved, at: target)
        persist()
    }

    /// 清空（移除全部）。
    func removeAllActions() {
        guard !actionIDs.isEmpty else { return }
        actionIDs.removeAll()
        persist()
    }

    private func persist() {
        try? scope?.setObject(actionIDs, forKey: Self.storageKey)
    }

    /// 放置实例被移除时清理落盘文件。
    func discardStorage() {
        scope?.removeValue(forKey: Self.storageKey)
    }
}

/// 每放置实例模型注册表：块视图（多屏多实例）与管理面板共享同一模型。
@MainActor
final class BoxInstanceRegistry {
    static let shared = BoxInstanceRegistry()

    private var models: [String: BoxInstanceModel] = [:]

    private init() {}

    /// 取（或创建）某放置实例的模型。
    func model(placementID: String, stateStore: StateStore) -> BoxInstanceModel {
        if let existing = models[placementID] { return existing }
        let model = BoxInstanceModel(placementID: placementID, stateStore: stateStore)
        models[placementID] = model
        return model
    }

    /// 实例被移除：丢弃内存模型。
    func discard(placementID: String) {
        models[placementID] = nil
    }

    /// 插件被禁用：整体清空（视图树随后整体重建）。
    func removeAll() {
        models.removeAll()
    }
}

// MARK: - 盒布局常量（容量策略）

/// 盒的容量与图标宫格布局参数：纯图标（44pt 单元格）+ 悬停显名，不做块内
/// 滚动/分页；装填超过该容量即拒绝，由宿主提示用户换更大尺寸。
enum QuickButtonBoxLayout {
    /// 图标单元格边长。
    static let iconSize: CGFloat = 44
    /// 单元格间距。
    static let iconSpacing: CGFloat = 8

    /// 按当前网格跨度给容量上限（保守估算，保证落满不溢出视觉区域）：
    /// 大块 2×2 ≈ 10、特大块 4×2 ≈ 16；未知跨度按单元格数 × 2 封顶 16。
    static func capacity(for span: GridSpan) -> Int {
        switch (span.columns, span.rows) {
        case (2, 2): return 10
        case (4, 2): return 16
        default:
            return min(max(span.columns * span.rows * 2, 1), 16)
        }
    }

    /// 由块当前跨度换算容量（无布局信息时的回落：按 4×2 封顶容量）。
    static func capacity(forSize size: GridSpan?) -> Int {
        guard let size else { return capacity(for: GridSpan(columns: 4, rows: 2)) }
        return capacity(for: size)
    }
}
