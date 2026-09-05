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
                // 滑杆以非 ScrollView 机制消费横向输入，宿主滚动探针不可见，
                // 按「块以自定义机制消费横向输入」约定声明无条件让路：
                // 块上横向拖动归滑杆，切页手势移到块外触发。
                scrollUsage: .always,
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
