import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - SystemMonitorPlugin（系统监控：CPU / 内存 / 磁盘 / 网络 + All-in-one）
//
// 单插件注册五个抽屉块（共识 Q11-A）：四个单指标块（1×1 / 2×1）与一个
// 系统总览块（2×2 / 4×2 / 4×3 / 4×4）。采样引擎全局单份（SystemMonitorStore），
// 每实例差异（历史窗 / 阈值 / 单位 / 排除表 / 指标开关）走 placementStore
// 经 instanceSettingsView 编辑。不实现插件级 settingsView 与 menuItems（共识 Q13/Q14）。

@objc(SystemMonitorPlugin)
@MainActor
public final class SystemMonitorPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// attachServices 注入的插件级存储，用于实例删除时清理 placementStore 文件。
    private var stateStore: StateStore?

    public override init() {
        super.init()
    }

    // MARK: 块声明

    private static func instanceModel(for context: BlockContext) -> SystemMonitorInstanceModel {
        SystemMonitorInstanceRegistry.shared.model(
            placementID: context.placementID,
            blockID: context.blockID,
            stateStore: context.stateStore
        )
    }

    private static func singleBlock(id: String, kind: MetricKind) -> NotchBlock {
        NotchBlock(
            id: id,
            displayName: L(kind.displayNameKey),
            kind: .drawer,
            supportedSizes: [.small, .medium],
            defaultSize: .small,
            supportedGridSpans: [],
            interaction: .expandDrawer,
            symbolName: kind.symbolName,
            // 静态监控卡、不消费横向滚动：其上滑动直接切页。
            scrollUsage: .none,
            instanceSettingsView: { context in
                AnyView(SingleInstanceSettingsView(kind: kind, instance: instanceModel(for: context)))
            },
            makeView: { context in
                AnyView(MetricBlockView(
                    kind: kind,
                    instance: instanceModel(for: context),
                    placementID: context.placementID,
                    isPreview: context.layoutInfo.isPreview,
                    // 宿主按跨度变化重走 makeView（BlockViewCacheKey 含跨度），
                    // 2×1 档在创建期即展开 sparkline。
                    showsSparkline: context.layoutInfo.size == .medium
                ))
            }
        )
    }

    private static let overviewBlock = NotchBlock(
        id: "system.overview",
        displayName: L("block.overview.name"),
        kind: .drawer,
        supportedSizes: [.large, .extraLarge],
        defaultSize: .large,
        supportedGridSpans: [GridSpan(columns: 4, rows: 3), GridSpan(columns: 4, rows: 4)],
        interaction: .expandDrawer,
        symbolName: "speedometer",
        scrollUsage: .none,
        instanceSettingsView: { context in
            AnyView(OverviewInstanceSettingsView(instance: instanceModel(for: context)))
        },
        makeView: { context in
            AnyView(OverviewBlockView(
                instance: instanceModel(for: context),
                placementID: context.placementID,
                isPreview: context.layoutInfo.isPreview
            ))
        }
    )

    public static var blocks: [NotchBlock] {
        [
            singleBlock(id: "system.cpu", kind: .cpu),
            singleBlock(id: "system.memory", kind: .memory),
            singleBlock(id: "system.disk", kind: .disk),
            singleBlock(id: "system.network", kind: .network),
            overviewBlock,
        ]
    }

    // MARK: 服务钩子

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.stateStore = stateStore
        SystemMonitorStore.shared.attach()
    }

    public func pluginWasDisabled() {
        SystemMonitorStore.shared.suspend()
    }

    public func placementWasRemoved(blockID: String, placementID: String) {
        SystemMonitorInstanceRegistry.shared.discard(placementID: placementID)
        SystemMonitorStore.shared.placementRemoved(placementID: placementID)
        // 清掉该实例的两份配置文件，避免孤儿文件堆积。
        if let scope = stateStore?.placementScope(placementID: placementID) {
            scope.removeValue(forKey: InstanceConfigLogic.singleStoreKey)
            scope.removeValue(forKey: InstanceConfigLogic.overviewStoreKey)
        }
    }
}
