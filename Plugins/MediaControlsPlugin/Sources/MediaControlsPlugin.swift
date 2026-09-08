import AppKit
import NotchCenterKit
import SwiftUI
/// MediaControlsPlugin（官方媒体控制插件）：控制系统当前正在播放的媒体
/// （Spotify / Music / 浏览器等任意 App 的全局 Now Playing 会话），以抽屉块
/// 承载控制面（封面 / 标题 / 进度 / 播放暂停与上下曲），并把「正在播放」的
/// 简介与进度经活动摘要通道（HostController.showActivitySummary）提交给宿主，
/// 在刘海紧凑带内显示迷你芯片（收起态也可一瞥当前曲目）。
///
/// 技术路线：MediaRemote 私有框架（dlopen/dlsym 单层封装，见
/// `MediaRemoteSession`）；风险与决策见 Agent Note
/// 2026-09-03-media-controls-plugin。框架不可用时插件整体优雅降级。
@objc(MediaControlsPlugin) @MainActor
public final class MediaControlsPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe；区带镜像
    /// MediaControlsBlockViews.activeContent 的布局常量——播放中为最满形态：
    /// 行1 封面 54 + 信息列 ≈62、行2 进度 3+4+时间 ≈19、块内边距 14）。
    /// 意图：两行固定区带必须完整落在 minSize 盒内，且互不重叠；盒高小于
    /// 总需求（14+62+10+19+14=119）时最末行带越界 → 会向邻居溢出。
    private static func mediaControlLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let inset: CGFloat = 14
        let rowSpacing: CGFloat = 10
        let artworkRowHeight: CGFloat = 62
        let progressRowHeight: CGFloat = 19
        let contentWidth = max(size.width - inset * 2, 0)
        let artworkRow = CGRect(x: inset, y: inset, width: contentWidth, height: artworkRowHeight)
        // 最末区带并入底部内边距：总需求 = 14 + 62 + 10 + 19 + 14 = 119，
        // 盒高 < 119 时该区带越界 → 向邻居溢出的触发点与真实布局一致。
        let progressRow = CGRect(
            x: inset,
            y: inset + artworkRowHeight + rowSpacing,
            width: contentWidth,
            height: progressRowHeight + inset)
        return [
            BlockProbe(id: "media.artworkRow", rect: artworkRow),
            BlockProbe(id: "media.progressRow", rect: progressRow),
        ]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "media.controls",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 300, height: 240),
                maxSize: BlockPixelSize(width: 600, height: 240),
                recommendedSize: BlockPixelSize(width: 300, height: 240),
                symbolName: "playpause.fill",
                probes: { info in
                    Self.mediaControlLayoutProbes(for: info.frame.size)
                },
                makeView: { context in
                    AnyView(MediaControlsDrawerBlockView(context: context))
                }
            ),
        ]
    }

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        MediaPlayerController.shared.resolve(stateStore: stateStore, hostController: hostController)
    }

    public func pluginWasDisabled() {
        MediaPlayerController.shared.suspend()
    }

    // MARK: 快捷动作

    private var quickActionCache: [QuickAction]?

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        let controller = MediaPlayerController.shared
        let actions = [
            QuickAction(
                id: "media.playPause",
                displayName: L("help.togglePlayPause"),
                systemImage: "playpause.fill",
                kind: .action,
                execute: { [weak controller] in
                    controller?.togglePlayPause()
                }
            ),
            QuickAction(
                id: "media.previous",
                displayName: L("help.previous"),
                systemImage: "backward.end.fill",
                kind: .action,
                execute: { [weak controller] in
                    controller?.previousTrack()
                }
            ),
            QuickAction(
                id: "media.next",
                displayName: L("help.next"),
                systemImage: "forward.end.fill",
                kind: .action,
                execute: { [weak controller] in
                    controller?.nextTrack()
                }
            ),
        ]
        quickActionCache = actions
        return actions
    }
}
