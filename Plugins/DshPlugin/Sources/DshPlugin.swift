import AppKit
import Combine
import LaunchdControlKit
import NotchCenterKit
import SwiftUI

/// DshPlugin（dsh-web 服务控制卡，由 dsh-daemon/DSHMenubar 移植）。
/// 提供一个抽屉块：服务名 + 运行开关，点击空白区打开网页，
/// 长按弹出浮窗展示自启开关 / PID / 端口 / 状态 / 重启。
@objc(DshPlugin) @MainActor public final class DshPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe）：单行「状态点 + 服务名 +
    /// 状态 + 开关」水平布局（内容水平内边距 10、自然行高 ≈16），无固定叠加
    /// 区带、结构上不会块内自叠；行带须完整落在 minSize 盒内。
    private static func dshLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let horizontalInset: CGFloat = 10
        let rowHeight: CGFloat = 16
        return [
            BlockProbe(
                id: "dsh.serviceRow",
                rect: CGRect(
                    x: horizontalInset,
                    y: max((size.height - rowHeight) / 2, 0),
                    width: max(size.width - horizontalInset * 2, 0),
                    height: rowHeight)),
        ]
    }

    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "dsh.service",
            displayName: L("dsh.block.name"),
            kind: .drawer,
            minSize: BlockPixelSize(width: 150, height: 120),
            maxSize: BlockPixelSize(width: 300, height: 120),
            recommendedSize: BlockPixelSize(width: 150, height: 120),
            symbolName: "server.rack",
            probes: { info in
                dshLayoutProbes(for: info.frame.size)
            },
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

    // MARK: 快捷动作（Quick Action，可被快捷按钮盒收纳）

    private var quickActionCache: [QuickAction]?
    private var quickActionCancellables: Set<AnyCancellable> = []

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        let monitor = DshServiceMonitor.shared
        let toggle = QuickAction(
            id: "dsh.toggleService",
            displayName: L("quick.toggle.name"),
            systemImage: "power",
            kind: .toggle,
            // 服务启停会改系统状态：盒内点击先确认。
            requiresConfirmation: true,
            isActive: monitor.isServiceOn,
            execute: { [weak monitor] in
                monitor?.toggleRunning()
            }
        )
        // 开关态同步：轮询刷新 status 后盒内按钮跟随真实服务状态。
        monitor.$status
            .sink { [weak toggle, weak monitor] _ in
                toggle?.isActive = monitor?.isServiceOn ?? false
            }
            .store(in: &quickActionCancellables)
        let actions = [toggle]
        quickActionCache = actions
        return actions
    }
}
