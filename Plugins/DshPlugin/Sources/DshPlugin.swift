import AppKit
import LaunchdControlKit
import NotchCenterKit
import SwiftUI

/// DshPlugin（dsh-web 服务控制卡，由 dsh-daemon/DSHMenubar 移植）。
/// 提供一个抽屉块：服务名 + 运行开关，点击空白区打开网页，
/// 长按弹出浮窗展示自启开关 / PID / 端口 / 状态 / 重启。
@objc(DshPlugin) @MainActor public final class DshPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "dsh.service",
            displayName: L("dsh.block.name"),
            kind: .drawer,
            supportedSizes: [.small, .medium],
            defaultSize: .small,
            symbolName: "server.rack",
            makeView: { _ in
                AnyView(DshServiceBlockView())
            }
        )
    ]

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        // plist 缺失时按固定模板自动创建（决策 5），不覆盖已有文件。
        let plist = LaunchdPlist(plistPath: DshServiceConfig.plistPath)
        _ = plist.createIfMissing(contents: DshServiceConfig.plistContents)
        // 预热共享监视器：App 启动即开始轮询，首次展开抽屉前状态已就绪，
        // 开关不会在首屏再播一次“从关到开”的动画。
        _ = DshServiceMonitor.shared
    }

    public func pluginWasDisabled() {
        DshPopover.dismiss()
    }
}
