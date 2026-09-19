import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - SystemMonitorPlugin（系统监控：CPU / 内存 / 磁盘 / 网络 + All-in-one）
//
// 单插件注册五个抽屉块（共识 Q11-A）：四个单指标块（1×1 / 2×1）与一个
// 系统总览块（1×1 / 1×2 / 2×1 / 2×2 / 4×2 / 4×3 / 4×4，布局随跨度切换）。
// 采样引擎全局单份（SystemMonitorStore），
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

    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe）：单指标块与总览块的内容
    /// 都随跨度形态自适应填充、块内边距 10，无固定叠加区带，结构上不溢出邻居
    /// （单指标 2×1 的 sparkline 与 1×1 mini 均落在内容区内）；声明内容区为
    /// 唯一探针，兜住 minSize 比内边距还小的越界回归。
    private static func monitorContentProbes(for size: CGSize) -> [BlockProbe] {
        let inset: CGFloat = 10
        return [
            BlockProbe(
                id: "content",
                rect: CGRect(
                    x: inset, y: inset,
                    width: max(size.width - inset * 2, 0),
                    height: max(size.height - inset * 2, 0))),
        ]
    }

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
            minSize: BlockPixelSize(width: 150, height: 120),
            maxSize: BlockPixelSize(width: 300, height: 120),
            recommendedSize: BlockPixelSize(width: 150, height: 120),
            interaction: .expandDrawer,
            symbolName: kind.symbolName,
            instanceSettingsView: { context in
                AnyView(SingleInstanceSettingsView(kind: kind, instance: instanceModel(for: context)))
            },
            probes: { info in
                monitorContentProbes(for: info.frame.size)
            },
            makeView: { context in
                AnyView(MetricBlockView(
                    kind: kind,
                    instance: instanceModel(for: context),
                    placementID: context.placementID,
                    isPreview: context.layoutInfo.isPreview,
                    // 宿主按跨度与像素变化重走 makeView（BlockViewCacheKey 含两者），
                    // 2×1 档在创建期即展开 sparkline（像素不够时视图内再降级为 mini）；
                    // 无 span 上下文（目录预览等）按推荐 1×1 的 mini 形态兜底。
                    showsSparkline: MetricCellForm.forSpan(
                        widthColumns: context.layoutInfo.widthColumns,
                        heightRows: context.layoutInfo.heightRows
                    ) == .sparkline,
                    contentSize: context.layoutInfo.frame.size
                ))
            }
        )
    }

    private static let overviewBlock = NotchBlock(
        id: "system.overview",
        displayName: L("block.overview.name"),
        kind: .drawer,
        minSize: BlockPixelSize(width: 150, height: 120),
        maxSize: BlockPixelSize(width: 600, height: 480),
        // 推荐 2×2（默认档）；盒内任意整数跨可达（1×1 / 1×2 / 2×1 / 2×2 /
        // 4×2 / 4×3 / 4×4 皆在其中），布局随跨度切换（OverviewArrangement）。
        recommendedSize: BlockPixelSize(width: 300, height: 240),
        interaction: .expandDrawer,
        symbolName: "speedometer",
        instanceSettingsView: { context in
            AnyView(OverviewInstanceSettingsView(instance: instanceModel(for: context)))
        },
        probes: { info in
            monitorContentProbes(for: info.frame.size)
        },
        makeView: { context in
            AnyView(OverviewBlockView(
                instance: instanceModel(for: context),
                placementID: context.placementID,
                isPreview: context.layoutInfo.isPreview,
                widthColumns: context.layoutInfo.widthColumns,
                heightRows: context.layoutInfo.heightRows,
                contentSize: context.layoutInfo.frame.size
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
