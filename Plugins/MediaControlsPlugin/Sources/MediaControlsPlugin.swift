import NotchCenterKit
import SwiftUI

// MARK: - MediaControlsPlugin（官方「媒体控制」插件）

/// 抽屉里的一行媒体控制：左侧是正在播放的应用（图标 + 本地化名字），右侧是
/// 上一首 / 播放暂停 / 下一首。控制的是**系统当前播放的媒体**，不管它来自音乐、
/// Spotify 还是浏览器；观测与控制借 `/usr/bin/perl` 进程读私有框架 MediaRemote
/// （见 `MediaRemoteBridge`，为什么必须绕见该文件头部注释）。
///
/// 无实例设置、无快捷按钮、无活动摘要：一个块、一行、三个键。决策见
/// docs/agent-notes/implemented/2026-09-28-media-controls-plugin-restore.md。
@objc(MediaControlsPlugin) @MainActor
public final class MediaControlsPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe）。
    ///
    /// 只声明一条区带：整个组件的版式就是一行，可能越出内容盒的元素只有这一行。
    /// 矩形由 `MediaControlsMetrics` 推导（与块视图同一套常量），高度按「行高 +
    /// 底部内边距」取，使 minSize 一旦矮于总需求就精确触发越界。
    private static func rowLayoutProbes(for size: CGSize) -> [BlockProbe] {
        [BlockProbe(id: "media.row", rect: MediaControlsMetrics.rowProbeRect(for: size))]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "media.controls",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                // 高度锁死的单行：三档同高、宽度弹性（拉宽只是把应用名与按钮之间
                // 的空隙撑开）。用户改格子尺寸后实际 frame 可能高于 64，视图按任意
                // 盒内整数跨自适应：行整体垂直居中。
                minSize: BlockPixelSize(width: 260, height: 64),
                maxSize: BlockPixelSize(width: 600, height: 64),
                recommendedSize: BlockPixelSize(width: 300, height: 64),
                symbolName: "playpause.fill",
                probes: { info in
                    Self.rowLayoutProbes(for: info.frame.size)
                },
                makeView: { context in
                    AnyView(MediaControlsBlockView(context: context))
                }
            )
        ]
    }

    public override init() {
        super.init()
    }

    // MARK: 生命周期

    /// 不需要宿主的任何服务：观测走桥子进程推送，起停挂在块可见性上（视图的
    /// `setPresented`），所以这里是协议要求的空实现。
    public func attachServices(stateStore: StateStore, hostController: any HostController) {}

    /// 禁用即收尾：视图卸载通常已经停过桥，这里再收一次，避免"禁用时抽屉正温存"
    /// 这类路径留下常驻的 perl 子进程。
    public func pluginWasDisabled() {
        MediaPlayerController.shared.suspend()
    }
}
