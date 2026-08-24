import AppKit
import NotchCenterKit
import SwiftUI

/// OpenCodeUsagePlugin（OpenCode 用量卡，由 dsh-opencode-usage 移植）。
/// 抓取 opencode.ai dashboard SSR 页面，展示 Go 三个用量窗口（5h 滚动 /
/// 每周 / 每月）同心环与 Zen 余额；点击打开 dashboard，设置界面配置
/// cookie / workspaceID（cookie 只展示尾 4 位掩码，绝不回显明文）。
@objc(OpenCodeUsagePlugin) @MainActor public final class OpenCodeUsagePlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "opencode.usage",
            displayName: "OpenCode Usage",
            kind: .drawer,
            supportedSizes: [.small, .medium],
            defaultSize: .medium,
            symbolName: "gauge",
            makeView: { _ in
                AnyView(OpenCodeUsageBlockView())
            }
        )
    ]

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
}
