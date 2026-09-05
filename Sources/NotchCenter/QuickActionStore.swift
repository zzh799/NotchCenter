import Foundation
import NotchCenterKit

// MARK: - 快捷动作注册表（文档 §4.11）

/// 宿主侧的全局快捷动作注册表：插件启用时 `register`、禁用/卸载时 `unregister`。
///
/// - 插件动作实例身份稳定（插件缓存同一批 `QuickAction`），注册表只存引用；
///   盒内按钮与编辑目录观察这些实例获得实时状态。
/// - 注册顺序 = 插件启用顺序（`order` 数组），`allActions()` 按此展平，目录展示稳定。
/// - 动作 ID 全局唯一：后注册的同名 ID 被忽略（先到先得）并打印警告。
///   插件应使用 `<pluginID 段>.<action>` 形式规避冲突。
@MainActor
final class QuickActionStore {
    private var actionsByPlugin: [String: [QuickAction]] = [:]
    private var pluginOrder: [String] = []

    /// 注册一个插件的全部动作（插件启用/attach 后调用；重复注册按 pluginID 幂等替换）。
    func register(pluginID: String, actions: [QuickAction]) {
        var taken = Set(allActions().map(\.id))
        taken.subtract(Set(actionsByPlugin[pluginID]?.map(\.id) ?? []))
        var accepted: [QuickAction] = []
        for action in actions {
            if taken.contains(action.id) {
                print("QuickActionStore: duplicate action id '\(action.id)' ignored (plugin \(pluginID))")
                continue
            }
            taken.insert(action.id)
            accepted.append(action)
        }
        if actionsByPlugin[pluginID] == nil {
            pluginOrder.append(pluginID)
        }
        actionsByPlugin[pluginID] = accepted
    }

    /// 注销一个插件的全部动作（插件禁用/卸载前调用；未知 pluginID 无副作用）。
    func unregister(pluginID: String) {
        guard actionsByPlugin[pluginID] != nil else { return }
        actionsByPlugin[pluginID] = nil
        pluginOrder.removeAll { $0 == pluginID }
    }

    /// 全部已注册动作，按插件注册顺序展平。
    func allActions() -> [QuickAction] {
        pluginOrder.flatMap { actionsByPlugin[$0] ?? [] }
    }

    /// 按 ID 取动作；不存在（插件禁用/未知 ID）返回 nil。
    func action(id: String) -> QuickAction? {
        allActions().first { $0.id == id }
    }

    /// 清理全部注册（测试与全量重扫用）。
    func removeAll() {
        actionsByPlugin.removeAll()
        pluginOrder.removeAll()
    }
}
