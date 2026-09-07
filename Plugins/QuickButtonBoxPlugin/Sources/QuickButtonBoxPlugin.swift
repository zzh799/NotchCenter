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

    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe）：盒内 LazyVGrid 自适应
    /// 列数、超容量动作由宿主拒绝入盒（不滚动），结构上不溢出邻居；声明内容区
    /// （整卡内边距 10 以内）为唯一探针，兜住 minSize 比内边距还小的越界回归。
    private static func quickButtonBoxLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let inset: CGFloat = 10
        return [
            BlockProbe(
                id: "quickbuttonbox.content",
                rect: CGRect(
                    x: inset, y: inset,
                    width: max(size.width - inset * 2, 0),
                    height: max(size.height - inset * 2, 0))),
        ]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "quickbuttonbox.grid",
                displayName: L("block.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 300, height: 240),
                maxSize: BlockPixelSize(width: 600, height: 240),
                recommendedSize: BlockPixelSize(width: 600, height: 240),
                symbolName: "square.grid.3x3",
                instanceSettingsView: { context in
                    AnyView(QuickButtonBoxManageView(context: context))
                },
                probes: { info in
                    Self.quickButtonBoxLayoutProbes(for: info.frame.size)
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
