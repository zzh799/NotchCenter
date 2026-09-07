import NotchCenterKit
import SwiftUI

/// DisplayPlugin（官方显示器亮度插件）：经 DDC/CI 调节外接显示器亮度。
/// Apple Silicon 走 IOAVService 路线（忠实移植 m1ddc，MIT），Intel 走
/// IOKit IOI2C 公开 API；决策记录见 Agent Note 2026-09-05-display-plugin-ddc，
/// 能力边界见插件 README。
///
/// 版式随块跨度自适应：1×1（small）每台屏「屏名 + 滑杆」两行紧凑堆叠，
/// 其余尺寸维持历史「每屏一行横向滑杆」（见 DisplaySlidersBlockView）。
@objc(DisplayPlugin) @MainActor
public final class DisplayPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "brightness.sliders",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 150, height: 120),
                maxSize: BlockPixelSize(width: 600, height: 240),
                recommendedSize: BlockPixelSize(width: 300, height: 120),
                symbolName: "sun.max",
                // 滑杆只经命中测试消费鼠标拖拽，不消费滚轮横向增量：
                // 块上横向轻扫照常切页，与拖滑杆调亮度互不干扰。
                probes: { info in
                    // 打包期最小尺寸遮挡校验：两形态（1×1 紧凑两行 / 行式）共用
                    // ViewThatFits 容器，超高条目自动转块内 ScrollView，结构上不
                    // 溢出邻居；声明内容区为唯一探针（紧凑形态内边距 8/10 是
                    // 更小的内容盒，两形态内容都落在其中）。
                    let size = info.frame.size
                    let topInset: CGFloat = 8
                    let leadingInset: CGFloat = 10
                    return [
                        BlockProbe(
                            id: "display.content",
                            rect: CGRect(
                                x: leadingInset, y: topInset,
                                width: max(size.width - leadingInset * 2, 0),
                                height: max(size.height - topInset * 2, 0))),
                    ]
                },
                makeView: { context in
                    AnyView(DisplaySlidersBlockView(context: context))
                }
            ),
        ]
    }

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        // 重新启用时恢复写入通道（禁用时 suspend 收掉）。
        BrightnessController.shared.resume()
        observeScreenChanges()
    }

    public func pluginWasDisabled() {
        stopObservingScreenChanges()
        BrightnessController.shared.suspend()
    }

    // MARK: 显示器热插拔

    /// 监听屏幕参数变化：显示器插拔 / 分辨率变化完成后触发差量重枚举，
    /// 拔出屏的滑杆行即时消失、新屏即时出现（同名通知宿主亦用于重建布局）。
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func stopObservingScreenChanges() {
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        Task { await BrightnessController.shared.refresh() }
    }
}
