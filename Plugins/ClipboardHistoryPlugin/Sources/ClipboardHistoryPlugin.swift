import NotchCenterKit
import SwiftUI

// MARK: - ClipboardHistoryPlugin（官方剪贴板历史插件）
//
// 共识见 Agent Note 2026-09-05-clipboard-history-plugin：纯文本起步、点击写回
// 无模拟粘贴、全局共享历史 + placement 独立显示偏好。第一版不实现插件级
// settingsView（返回 nil）；状态栏菜单贡献暂停 / 清空两项。

@objc(ClipboardHistoryPlugin) @MainActor
public final class ClipboardHistoryPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// attachServices 注入的插件级存储：历史落盘、暂停态、实例删除清理。
    private var stateStore: StateStore?

    private static func instanceModel(for context: BlockContext) -> ClipboardInstanceModel {
        ClipboardInstanceRegistry.shared.model(
            placementID: context.placementID,
            blockID: context.blockID,
            stateStore: context.stateStore
        )
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "clipboard.tray",
                displayName: L("block.compact.name"),
                kind: .compact,
                // 默认交互：点击展开抽屉（宿主处理，插件纯展示 + 暂停态变灰）。
                symbolName: "clipboard",
                makeView: { context in
                    AnyView(ClipboardTrayView(context: context))
                }
            ),
            NotchBlock(
                id: "clipboard.history",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                supportedSizes: [.large, .extraLarge],
                defaultSize: .large,
                supportedGridSpans: [],
                symbolName: "clipboard",
                // 纵向列表不消费横向滑动：其上滑动照常切页。
                scrollUsage: .none,
                instanceSettingsView: { context in
                    AnyView(ClipboardInstanceSettingsView(instance: instanceModel(for: context)))
                },
                makeView: { context in
                    AnyView(ClipboardHistoryBlockView(
                        instance: instanceModel(for: context),
                        placementID: context.placementID,
                        isPreview: context.layoutInfo.isPreview
                    ))
                }
            ),
        ]
    }

    public var menuItems: [PluginMenuItem] {
        let store = ClipboardHistoryStore.shared
        return [
            PluginMenuItem(
                id: "clipboard.menu.pause",
                title: store.isPaused ? L("menu.resume") : L("menu.pause"),
                systemImage: store.isPaused ? "clipboard" : "pause.circle",
                action: { [weak self] in
                    self?.togglePaused()
                }
            ),
            PluginMenuItem(
                id: "clipboard.menu.clear",
                title: L("menu.clear"),
                systemImage: "trash",
                action: { [weak self] in
                    self?.clearUnpinned()
                }
            ),
        ]
    }

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController _: any HostController) {
        self.stateStore = stateStore
        ClipboardHistoryStore.shared.attach(stateStore: stateStore)
    }

    public func pluginWasDisabled() {
        ClipboardHistoryStore.shared.suspend()
    }

    public func placementWasRemoved(blockID _: String, placementID: String) {
        ClipboardInstanceRegistry.shared.discard(placementID: placementID)
        ClipboardHistoryStore.shared.placementRemoved(placementID: placementID)
        // 只清该实例的显示偏好，全局历史不受影响（共识 Q7）。
        if let scope = stateStore?.placementScope(placementID: placementID) {
            scope.removeValue(forKey: ClipboardInstanceConfigLogic.storeKey)
        }
    }

    // MARK: 菜单动作（store 单例经 attach 已就绪；未就绪时空操作）

    private func togglePaused() {
        let store = ClipboardHistoryStore.shared
        store.setPaused(!store.isPaused)
    }

    private func clearUnpinned() {
        ClipboardHistoryStore.shared.clearUnpinned()
    }
}
