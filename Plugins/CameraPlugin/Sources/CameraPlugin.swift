import AppKit
import AVFoundation
import NotchCenterKit
import SwiftUI

// MARK: - CameraPlugin（摄像头镜子）
//
// 单一职责：一键预览摄像头画面（camera.mirror，需要摄像头权限）。
// 窗口/会话归插件单例管理，pluginWasDisabled 关闭会话。

@objc(CameraPlugin)
@MainActor
public final class CameraPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    private var stateStore: StateStore?

    public override init() {
        super.init()
    }

    /// 打包期最小尺寸遮挡校验探针：镜像块的顶栏 + 预览区下限。
    /// 常量与 CameraBlockMetrics 同源。
    private static func mirrorLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let inset = CameraBlockMetrics.inset
        let spacing = CameraBlockMetrics.spacing
        let contentWidth = max(size.width - inset * 2, 0)
        let header = CameraBlockMetrics.headerHeight
        let preview = CameraBlockMetrics.previewMinHeight
        return [
            BlockProbe(
                id: "camera.header",
                rect: CGRect(x: inset, y: inset, width: contentWidth, height: header)),
            BlockProbe(
                id: "camera.preview",
                rect: CGRect(
                    x: inset, y: inset + header + spacing,
                    width: contentWidth, height: preview)),
        ]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "camera.mirror",
                displayName: L("block.mirror.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 180, height: 140),
                maxSize: BlockPixelSize(width: 600, height: 480),
                recommendedSize: BlockPixelSize(width: 240, height: 180),
                symbolName: "camera",
                probes: { info in Self.mirrorLayoutProbes(for: info.frame.size) },
                makeView: { context in
                    AnyView(CameraMirrorBlockView(context: context))
                }
            ),
        ]
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.stateStore = stateStore
        CameraStore.shared.configureIfNeeded()
    }

    public func pluginWasDisabled() {
        CameraStore.shared.stopSession()
    }
}
