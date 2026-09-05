import NotchCenterKit
import SwiftUI

// MARK: - QuickButtonBoxPlugin（官方「快捷按钮盒」插件）
//
// 收纳其他插件注册的 QuickAction（文档 §4.11）：盒子本身是一个抽屉容器块，
// 不注册任何自己的快捷动作（default []）。内容通过两条路径装填：
// 1. 编辑模式：设置 → 组件 → 快捷动作 → 拖到盒上（宿主经
//    `NotchCenterQuickActionSink.acceptQuickAction` 回调本类）；
// 2. 盒块齿轮（instanceSettingsView）面板：移除 / 排序。
@objc(QuickButtonBoxPlugin) @MainActor
public final class QuickButtonBoxPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices, NotchCenterQuickActionSink {
    private static func instanceModel(for context: BlockContext) -> BoxInstanceModel {
        BoxInstanceRegistry.shared.model(
            placementID: context.placementID,
            stateStore: context.stateStore
        )
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "quickbuttonbox.grid",
                displayName: L("block.name"),
                kind: .drawer,
                supportedSizes: [.large, .extraLarge],
                defaultSize: .extraLarge,
                supportedGridSpans: [],
                symbolName: "square.grid.3x3",
                // 静态宫格不消费横向滑动：其上滑动照常切页。
                scrollUsage: .none,
                instanceSettingsView: { context in
                    AnyView(QuickButtonBoxManageView(context: context))
                },
                makeView: { context in
                    AnyView(QuickButtonBoxView(context: context))
                }
            )
        ]
    }

    /// attachServices 注入：sink 落位时持久化到对应放置实例的存储。
    private var stateStore: StateStore?

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController _: any HostController) {
        self.stateStore = stateStore
    }

    public func pluginWasDisabled() {
        // 视图树将整体重建；注册表内存模型一并清空，避免滞留过期实例。
        BoxInstanceRegistry.shared.removeAll()
    }

    public func placementWasRemoved(blockID _: String, placementID: String) {
        guard let stateStore else { return }
        let model = BoxInstanceRegistry.shared.model(
            placementID: placementID,
            stateStore: stateStore
        )
        model.discardStorage()
        BoxInstanceRegistry.shared.discard(placementID: placementID)
    }

    // MARK: NotchCenterQuickActionSink

    /// 宿主拖拽落位回调：校验容量后把动作 ID 追加到目标放置实例的动作集。
    /// 返回 false（盒已满 / 未知动作由宿主侧先行过滤）时宿主提示用户。
    public func acceptQuickAction(_ actionID: String, placementID: String, span: GridSpan) -> Bool {
        guard let stateStore else { return false }
        let model = BoxInstanceRegistry.shared.model(
            placementID: placementID,
            stateStore: stateStore
        )
        return model.append(actionID: actionID, capacity: QuickButtonBoxLayout.capacity(for: span))
    }
}
