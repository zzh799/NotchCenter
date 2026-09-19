import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - CommandSchedulerPlugin
//
// 定时执行本机命令，并回看每次执行的输出。核心只提供基础设施（调度、执行、
// 历史、UI 落点），业务语义全在插件内；不依赖 `LaunchdControlKit`——本插件的
// 调度活在宿进程里（决策 1），没有 launchd 介入。
//
// 设计决策与备选方案见 `docs/agent-notes/implemented/2026-09-19-command-scheduler-plugin.md`。
@objc(CommandSchedulerPlugin) @MainActor public final class CommandSchedulerPlugin: NSObject,
    NotchCenterPlugin, NotchCenterPluginServices {

    /// 打包期最小尺寸遮挡校验探针（Kit `BlockProbe`；几何区带镜像 `TaskListView`
    /// 的布局常量——改动布局时同步这里，数字一律取自 `SchedulerMetrics`）。
    ///
    /// 区带意图：顶部工具行（新建 / 全局设置）+ 任务列表区（在 `minSize` 下须
    /// 完整可见 `SchedulerMetrics.visibleRowsAtMinimum` 行）。竖轴总和必须 ≤
    /// `minSize.height`，违规说明块矮到装不下自己的工具行与几行任务，会向邻居
    /// 溢出（宿主卡片不裁切）。
    static func schedulerLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let padding = SchedulerMetrics.padding
        let contentWidth = max(size.width - padding * 2, 1)
        let toolbarTop = padding
        let listTop = padding + SchedulerMetrics.toolbarHeight + SchedulerMetrics.toolbarSpacing
        return [
            BlockProbe(
                id: "scheduler.toolbar",
                rect: CGRect(
                    x: padding, y: toolbarTop,
                    width: contentWidth, height: SchedulerMetrics.toolbarHeight
                )
            ),
            BlockProbe(
                id: "scheduler.list",
                rect: CGRect(
                    x: padding, y: listTop,
                    width: contentWidth, height: SchedulerMetrics.listMinimumHeight
                )
            ),
        ]
    }

    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "command.scheduler",
            displayName: L("scheduler.block.title"),
            kind: .drawer,
            // 三档往大定是决策 9 的直接后果：历史浮窗卡片尺寸被"卡片 ⊆ 块矩形"
            // 这条约束夹住（卡片 = 块 − BlockPopover.cardInset），块小了日志就
            // 没得看；480×340 是"卡片还能当分栏日志查看器用"的地板。
            minSize: BlockPixelSize(width: 480, height: 340),
            maxSize: BlockPixelSize(width: 960, height: 760),
            recommendedSize: BlockPixelSize(width: 660, height: 460),
            // 大组件不往别人页缝里塞：当前页为空就地占用，否则另开一页。
            placement: .newPageWhenOccupied,
            symbolName: "calendar.badge.clock",
            probes: { info in
                schedulerLayoutProbes(for: info.frame.size)
            },
            makeView: { context in
                AnyView(TaskListView(context: context))
            }
        )
    ]

    /// 插件级设置（宿主编辑模式齿轮入口）。块内齿轮走同一个视图，但由插件
    /// 自己调 `SettingPopover` 呈现——`settingsView` 的标准触发点要先进布局
    /// 编辑模式，改配置的心智不该长在那里（决策 6）。
    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? {
        { _ in AnyView(SchedulerSettingsView()) }
    }

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        SchedulerCore.shared.attach(stateStore: stateStore, hostController: hostController)
    }

    /// 宿主禁用插件时调用：杀运行中的进程组（记 `aborted`，不是 `failed`）、
    /// 停排期、收活动摘要与浮窗。禁止在此卸载 bundle。
    public func pluginWasDisabled() {
        SchedulerCore.shared.shutdown()
    }
}
