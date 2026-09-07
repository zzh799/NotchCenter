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

    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe）：列表在块内 ScrollView
    /// 纵向滚动、顶行按钮悬浮，结构上不溢出邻居；声明整内容区为唯一探针，
    /// 兜住块级内边距缩成负值等越界回归。
    private static func clipboardLayoutProbes(for size: CGSize) -> [BlockProbe] {
        [
            BlockProbe(
                id: "clipboard.content",
                rect: CGRect(x: 0, y: 0, width: size.width, height: size.height)),
        ]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "clipboard.history",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 300, height: 240),
                maxSize: BlockPixelSize(width: 600, height: 240),
                recommendedSize: BlockPixelSize(width: 300, height: 240),
                symbolName: "clipboard",
                instanceSettingsView: { context in
                    AnyView(ClipboardInstanceSettingsView(instance: instanceModel(for: context)))
                },
                probes: { info in
                    Self.clipboardLayoutProbes(for: info.frame.size)
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

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.stateStore = stateStore
        self.hostController = hostController
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

    // MARK: 快捷动作（Quick Action，可被快捷按钮盒收纳）

    private var quickActionCache: [QuickAction]?
    private weak var hostController: (any HostController)?

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        let store = ClipboardHistoryStore.shared
        let actions = [
            QuickAction(
                id: "clipboard.tray",
                displayName: L("block.compact.name"),
                systemImage: "clipboard",
                kind: .action,
                // 前身即默认进带的 `clipboard.tray` 紧凑块：点击 = 展开抽屉
                // 打开剪贴板历史（与原宿主默认交互一致）。
                defaultInStrip: true,
                execute: { [weak self] in
                    self?.hostController?.expandDrawer()
                }
            ),
            QuickAction(
                id: "clipboard.clearUnpinned",
                displayName: L("menu.clear"),
                systemImage: "trash",
                kind: .action,
                // 清空有副作用：盒内点击先确认（与抽屉块内清空交互一致）。
                requiresConfirmation: true,
                execute: { [weak store] in
                    store?.clearUnpinned()
                }
            ),
        ]
        quickActionCache = actions
        return actions
    }
}
