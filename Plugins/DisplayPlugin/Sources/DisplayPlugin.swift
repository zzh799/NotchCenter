import NotchCenterKit
import SwiftUI

/// DisplayPlugin（官方显示器亮度插件）：按屏调节亮度——外接屏经 DDC/CI
/// （Apple Silicon 走 IOAVService 路线，忠实移植 m1ddc，MIT；Intel 走
/// IOKit IOI2C 公开 API），内建屏经系统亮度通道（DisplayServices，与系统
/// 亮度键同一个值）。决策记录见 Agent Note 2026-09-05-display-plugin-ddc 与
/// 2026-09-19-builtin-brightness-system-path，能力边界见插件 README。
///
/// 两块共存：`brightness.sliders` 是多屏列表（版式见 DisplaySlidersBlockView）；
/// `brightness.single` 是单屏条（一实例一屏，形态见 SingleBrightnessBlockView，
/// 决策见 Agent Note 2026-09-09-display-single-brightness-bar）。
/// DDC 写入区间按屏全局存（见 DDCLuminanceRange），两块的设置界面编辑同一份值。
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
                instanceSettingsView: { context in
                    AnyView(DisplaySlidersSettingsView(pluginStore: context.stateStore))
                },
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
            NotchBlock(
                id: "brightness.single",
                displayName: L("block.single.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 75, height: 60),
                maxSize: BlockPixelSize(width: 300, height: 240),
                recommendedSize: BlockPixelSize(width: 150, height: 240),
                symbolName: "sun.max",
                instanceSettingsView: { context in
                    AnyView(SingleDisplaySettingsView(
                        instance: SingleDisplayInstanceRegistry.model(
                            placementID: context.placementID,
                            stateStore: context.stateStore),
                        pluginStore: context.stateStore))
                },
                probes: { info in
                    // 单探针即整块内容不断言子结构：小 UI 满铺、大 UI 标题与滑杆
                    // 都落在此盒内；探针只能依赖 frame（校验时无跨度上下文）。
                    let size = info.frame.size
                    let inset: CGFloat = 6
                    return [
                        BlockProbe(
                            id: "single.content",
                            rect: CGRect(
                                x: inset, y: inset,
                                width: max(size.width - inset * 2, 0),
                                height: max(size.height - inset * 2, 0))),
                    ]
                },
                makeView: { context in
                    AnyView(SingleBrightnessBlockView(context: context))
                }
            ),
        ]
    }

    /// 宿主注入的作用域存储：删实例时定位该 placement 的 placementScope
    /// （区间等插件级共享数据在同一 store 的根，不受影响）。
    private var stateStore: StateStore?

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.stateStore = stateStore
        // 区间先载入再恢复通道：设置界面读的是同一份内存值。
        BrightnessController.shared.configure(store: stateStore)
        // 重新启用时恢复写入通道（禁用时 suspend 收掉）。
        BrightnessController.shared.resume()
        observeScreenChanges()
    }

    public func pluginWasDisabled() {
        stopObservingScreenChanges()
        BrightnessController.shared.suspend()
    }

    /// 单屏条实例被删除：只清该实例的绑定（内存模型 + 磁盘 config.display），
    /// 插件级 DDC 区间存储不受影响。宿主会先逐个 placementWasRemoved 再停用。
    public func placementWasRemoved(blockID _: String, placementID: String) {
        SingleDisplayInstanceRegistry.discard(placementID: placementID)
        if let scope = stateStore?.placementScope(placementID: placementID) {
            scope.removeValue(forKey: SingleDisplayInstanceConfigLogic.storeKey)
        }
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
