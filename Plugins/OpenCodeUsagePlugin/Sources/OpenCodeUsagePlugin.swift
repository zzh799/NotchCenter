import AppKit
import NotchCenterKit
import SwiftUI

/// OpenCodeUsagePlugin（OpenCode 用量卡，由 dsh-opencode-usage 移植）。
/// 抓取 opencode.ai dashboard SSR 页面，展示 Go 三个用量窗口（5h 滚动 /
/// 每周 / 每月）与 Zen 余额；点击打开 dashboard，设置界面配置
/// cookie / workspaceID（cookie 只展示尾 4 位掩码，绝不回显明文）。
///
/// 抽屉支持同一块类型放置多个实例：数据全局共享一份（单例 store），
/// 显示样式（余量环 / 余量表 / 峰谷时钟）与峰谷倒计时开关按实例单独
/// 设置——持久化在 Kit 的 placementStore，经 instanceSettingsView 编辑。
@objc(OpenCodeUsagePlugin) @MainActor public final class OpenCodeUsagePlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// 块声明。视图工厂与实例设置视图都以 BlockContext 为输入，从中解析出
    /// 该放置实例的共享外观模型；必须用含 instanceSettingsView 的完整 init。
    private static let block = NotchBlock(
        id: "opencode.usage",
        displayName: L("block.displayName"),
        kind: .drawer,
        supportedSizes: [.small, .medium],
        defaultSize: .medium,
        supportedGridSpans: [],
        interaction: .expandDrawer,
        // 静态用量卡、不消费横向滚动：其上滑动直接切页。
        symbolName: "gauge",
        scrollUsage: .none,
        instanceSettingsView: { context in
            AnyView(OpenCodeUsageInstanceSettingsView(instance: instanceModel(for: context)))
        },
        makeView: { context in
            AnyView(OpenCodeUsageBlockView(instance: instanceModel(for: context)))
        }
    )

    private static func instanceModel(for context: BlockContext) -> OpenCodeUsageInstanceModel {
        OpenCodeUsageInstanceRegistry.shared.model(
            placementID: context.placementID,
            stateStore: context.stateStore
        )
    }

    public static var blocks: [NotchBlock] { [block] }

    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? {
        { _ in
            AnyView(OpenCodeUsageSettingsView())
        }
    }

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        OpenCodeUsageStore.shared.resolve(stateStore: stateStore)
    }

    public func pluginWasDisabled() {
        OpenCodeUsageStore.shared.suspend()
    }

    public func placementWasRemoved(blockID: String, placementID: String) {
        // 只清理该实例私有的外观配置；插件级共享数据（账户配置等）不动。
        guard blockID == Self.block.id else { return }
        OpenCodeUsageInstanceRegistry.shared.discard(placementID: placementID)
        OpenCodeUsageStore.shared.sharedStateStore?
            .placementScope(placementID: placementID)?
            .removeValue(forKey: OpenCodeUsageAppearanceLogic.storeKey)
    }
}
