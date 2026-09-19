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

    /// 打包期最小尺寸遮挡校验探针：块内只剩画面区一条（标题行已撤、控件走
    /// 悬停浮出面板），所以只需声明"内容区完整可见"。常量与 CameraBlockMetrics
    /// 同源。
    private static func mirrorLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let inset = CameraBlockMetrics.inset
        return [
            BlockProbe(
                id: "camera.preview",
                rect: CGRect(
                    x: inset, y: inset,
                    width: max(size.width - inset * 2, 0),
                    height: max(size.height - inset * 2, 0))),
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
        // 刻意不在这里配置采集会话：建 `AVCaptureDeviceInput` 就会拉起系统摄像头
        // 授权窗，装载期调用等于每次启动 App 都弹一次（配置改在用户点开始时做）。
        // 决策见 Agent Note 2026-09-11-permission-lazy-trigger。
    }

    public func pluginWasDisabled() {
        CameraStore.shared.stopSession()
    }
}
