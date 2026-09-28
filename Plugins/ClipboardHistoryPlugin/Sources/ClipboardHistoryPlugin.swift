import NotchCenterKit
import SwiftUI

// MARK: - ClipboardHistoryPlugin（官方剪贴板历史插件）
//
// 共识见 Agent Note 2026-09-05-clipboard-history-plugin：纯文本起步、点击写回
// 无模拟粘贴、全局共享历史 + placement 独立显示偏好。状态栏菜单贡献暂停 / 清空两项。
// 插件级 settingsView 到 2026-09-25 才有内容：全局的「自动清理」档位——库页块
// （`clipboard.library`）本身没有实例设置，没有它这个入口就够不到这一项
// （决策记录 2026-09-25-clipboard-auto-cleanup 的 D8）。

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

    /// 剪贴板库页块（`clipboard.library`）的打包期遮挡校验探针。
    ///
    /// 区带镜像 `ClipboardLibraryMetricsProbe` 与 `ClipboardLibraryView` 的纵向
    /// 骨架。最小尺寸 300×240 下只声明两个固定区带（搜索输入行 / 类型筛选行）；
    /// 置顶看板横向滚动、最近列表纵向滚动，都是自适应容器，允许被压缩。
    /// 纵向常量：内边距 12、间距 12、搜索行 26、筛选行 22。
    private static func clipboardLibraryLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let padding = ClipboardLibraryMetricsProbe.padding
        let gap = ClipboardLibraryMetricsProbe.sectionGap
        let searchHeight = ClipboardLibraryMetricsProbe.searchRowHeight
        let filterHeight = ClipboardLibraryMetricsProbe.filterRowHeight
        let contentWidth = max(size.width - padding * 2, 0)
        // 最末区带并入底部内边距：总需求 = 12 + 26 + 12 + 22 + 12 = 84，
        // 盒高 < 84 时该区带越界 → 触发点与真实布局一致。
        return [
            BlockProbe(
                id: "clipboard.library.search",
                rect: CGRect(x: padding, y: padding, width: contentWidth, height: searchHeight)),
            BlockProbe(
                id: "clipboard.library.filter",
                rect: CGRect(
                    x: padding,
                    y: padding + searchHeight + gap,
                    width: contentWidth,
                    height: filterHeight + padding)),
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
                    AnyView(ClipboardHistoryBlockView(instance: instanceModel(for: context)))
                }
            ),
            // 大组件形态：常驻搜索 + 置顶看板 + 类型筛选 + 全文预览。与上面的
            // 小抽屉块是两种形态，二者可同时放置。
            NotchBlock(
                id: "clipboard.library",
                displayName: L("block.library.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 300, height: 240),
                maxSize: BlockPixelSize(width: 900, height: 600),
                recommendedSize: BlockPixelSize(width: 600, height: 400),
                placement: .newPageWhenOccupied,
                symbolName: "rectangle.stack",
                probes: { info in
                    Self.clipboardLibraryLayoutProbes(for: info.frame.size)
                },
                makeView: { _ in
                    AnyView(ClipboardLibraryView())
                }
            ),
        ]
    }

    /// 插件级设置：全局的自动清理档位（历史是插件级共享的，档位只有一份）。
    /// 抽屉块因声明了 `instanceSettingsView` 走实例浮窗，那一份里也含同一行。
    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? {
        { _ in
            AnyView(ClipboardPluginSettingsView())
        }
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
        ClipboardHistoryLogic.announceDiagnostics()
        ClipboardHistoryStore.shared.attach(stateStore: stateStore)
    }

    public func pluginWasDisabled() {
        ClipboardHistoryStore.shared.suspend()
    }

    public func placementWasRemoved(blockID _: String, placementID: String) {
        ClipboardInstanceRegistry.shared.discard(placementID: placementID)
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

    // MARK: 快捷动作

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
