import NotchCenterKit
import SwiftUI

/// DisplayPlugin（官方显示器亮度插件）：经 DDC/CI 调节外接显示器亮度，
/// 抽屉块内每屏一行滑杆。Apple Silicon 走 IOAVService 路线（忠实移植
/// m1ddc，MIT），Intel 走 IOKit IOI2C 公开 API；决策记录见 Agent Note
/// 2026-09-05-display-plugin-ddc，能力边界见插件 README。
@objc(DisplayPlugin) @MainActor
public final class DisplayPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "brightness.sliders",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                supportedSizes: [.medium, .large, .extraLarge],
                defaultSize: .medium,
                symbolName: "sun.max",
                // 滑杆只经命中测试消费鼠标拖拽，不消费滚轮横向增量：
                // 块上横向轻扫照常切页，与拖滑杆调亮度互不干扰。
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
    }

    public func pluginWasDisabled() {
        BrightnessController.shared.suspend()
    }
}
