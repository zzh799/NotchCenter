import NotchCenterKit
import SwiftUI

// MARK: - RemindersPlugin（官方「提醒事项」插件）
//
// 抽屉里的提醒事项清单：读 macOS 真实数据（EventKit），可就地勾选完成。
// 单一块 id `reminders.list`，三态版式（窄 / 宽 / 大）由宽 × 高双轴断点切换，
// 版式骨架复刻参考截图。决策与全部取舍见
// docs/agent-notes/implemented/2026-09-20-reminders-block.md。
//
// 权限纪律（[`2026-09-11-permission-lazy-trigger`](../../../docs/agent-notes/implemented/2026-09-11-permission-lazy-trigger.md)）：
// `attachServices` **不构造** `EKEventStore`、**不取数**——两者都会拉起系统授权窗。
// 取数路径只在已授权时经 `RemindersCore.dataSourceIfAuthorized()` 惰性打通；
// 缺权限时块内给引导态，唯一入口是宿主的「权限管理」弹窗。

@objc(RemindersPlugin)
@MainActor
public final class RemindersPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public override init() {
        super.init()
    }

    // MARK: 块声明

    /// `reminders.list`：一块一源（具体清单或智能视图），换源的唯一入口是块齿轮
    /// （实例设置）——块内右上角角标已于 2026-09-21 删除。
    ///
    /// 尺寸三档：`min 150×150`（窄态下限，网格上取整后是 1×2 格）、
    /// `recommended 300×360`（大态，2×3 格）、`max 900×600`。三态与网格的对应
    /// 关系见 `RemindersMetrics`：宽阈值 300 = 2 格，高阈值 360 = 3 格。
    private static let listBlock = NotchBlock(
        id: "reminders.list",
        displayName: L("block.list.name"),
        kind: .drawer,
        minSize: BlockPixelSize(width: 150, height: 150),
        maxSize: BlockPixelSize(width: 900, height: 600),
        recommendedSize: BlockPixelSize(width: 300, height: 360),
        symbolName: "checklist",
        instanceSettingsView: { context in
            AnyView(RemindersSourceList(instance: instance(for: context)))
        },
        probes: { info in
            RemindersMetrics.probes(for: info.frame.size)
        },
        makeView: { context in
            AnyView(RemindersBlockView(context: context, instance: instance(for: context)))
        }
    )

    public static var blocks: [NotchBlock] { [listBlock] }

    /// 同一 `placementID` 必须拿到同一个模型：宿主把同一份块视图塞进每块屏的
    /// 抽屉树，各屏副本得观察同一个对象，否则会各拉各的。
    private static func instance(for context: BlockContext) -> RemindersInstanceModel {
        RemindersCore.shared.model(
            placementID: context.placementID, blockID: context.blockID)
    }

    // MARK: 服务钩子

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        RemindersCore.shared.attach(stateStore: stateStore, hostController: hostController)
    }

    /// 插件被禁用：停外部变更订阅、清实例。禁止在此卸载 bundle。
    public func pluginWasDisabled() {
        RemindersCore.shared.shutdown()
    }

    /// 一个放置实例被用户移除：丢弃该实例的模型（抽屉与紧凑两条删除路径都会触发）。
    public func placementWasRemoved(blockID: String, placementID: String) {
        RemindersCore.shared.discard(placementID: placementID)
    }
}
