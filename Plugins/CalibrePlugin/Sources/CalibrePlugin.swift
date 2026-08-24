import AppKit
import LaunchdControlKit
import NotchCenterKit
import SwiftUI

/// CalibrePlugin（calibre-server 服务控制卡，结构与 DshPlugin 一致）。
/// 提供一个抽屉块：服务名 + 运行开关，点击空白区打开网页，
/// 长按弹出浮窗展示自启开关 / PID / 端口 / 状态 / 重启。
@objc(CalibrePlugin) @MainActor public final class CalibrePlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "calibre.service",
            displayName: "Calibre Server",
            kind: .drawer,
            supportedSizes: [.small, .medium],
            defaultSize: .small,
            symbolName: "books.vertical",
            makeView: { _ in
                AnyView(CalibreServiceBlockView())
            }
        )
    ]

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        // plist 缺失时按固定模板自动创建，不覆盖已有文件。
        let plist = LaunchdPlist(plistPath: CalibreServiceConfig.plistPath)
        _ = plist.createIfMissing(contents: CalibreServiceConfig.plistContents)
        // 预热共享监视器：App 启动即开始轮询，首次展开抽屉前状态已就绪，
        // 开关不会在首屏再播一次“从关到开”的动画。
        _ = CalibreServiceMonitor.shared
    }

    public func pluginWasDisabled() {
        CalibrePopover.dismiss()
    }
}
