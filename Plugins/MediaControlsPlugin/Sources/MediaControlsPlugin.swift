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
    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "media.controls",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                supportedSizes: [.large, .extraLarge],
                defaultSize: .large,
                // 静态控制卡、不消费横向滚动：其上滑动直接切页。
                symbolName: "playpause.fill",
                scrollUsage: .none,
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
}
