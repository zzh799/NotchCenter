import AppKit
import Combine
import LaunchdControlKit
import NotchCenterKit
import SwiftUI

/// CalibrePlugin（calibre-server 服务控制卡，结构与 DshPlugin 一致）。
/// 提供一个抽屉块：服务名 + 运行开关，点击空白区打开网页，
/// 长按弹出浮窗展示自启开关 / PID / 端口 / 状态 / 重启。
@objc(CalibrePlugin) @MainActor public final class CalibrePlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe）：单行「状态点 + 服务名 +
    /// 状态 + 开关」水平布局（内容水平内边距 10、自然行高 ≈16），无固定叠加
    /// 区带、结构上不会块内自叠；行带须完整落在 minSize 盒内。
    /// 窄块（< 110pt）改走紧凑「图标 + 名称」（见 `ServiceBlockCompactMetrics`），
    /// 同为居中单行带，探针几何不变。
    private static func calibreLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let horizontalInset: CGFloat = 10
        let rowHeight: CGFloat = 16
        return [
            BlockProbe(
                id: "calibre.serviceRow",
                rect: CGRect(
                    x: horizontalInset,
                    y: max((size.height - rowHeight) / 2, 0),
                    width: max(size.width - horizontalInset * 2, 0),
                    height: rowHeight)),
        ]
    }

    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "calibre.service",
            displayName: L("calibre.block.name"),
            kind: .drawer,
            minSize: BlockPixelSize(width: 75, height: 60),
            maxSize: BlockPixelSize(width: 150, height: 120),
            recommendedSize: BlockPixelSize(width: 75, height: 60),
            symbolName: "books.vertical",
            probes: { info in
                calibreLayoutProbes(for: info.frame.size)
            },
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
        // 重新启用（或首次）时恢复轮询：suspend 后表是停的，这里再起。
        CalibreServiceMonitor.shared.resume()
    }

    public func pluginWasDisabled() {
        CalibrePopover.dismiss()
        // 只关浮窗不够：轮询不停会在插件禁用后继续每 10s 起一次 shell 探测。
        CalibreServiceMonitor.shared.suspend()
    }

    // MARK: 快捷动作

    private var quickActionCache: [QuickAction]?
    private var quickActionCancellables: Set<AnyCancellable> = []

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        let monitor = CalibreServiceMonitor.shared
        let toggle = QuickAction(
            id: "calibre.toggleService",
            displayName: L("quick.toggle.name"),
            systemImage: "power",
            kind: .toggle,
            // 服务启停会改系统状态：盒内点击先确认（宿主/管理面板外的服务卡不受影响）。
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
