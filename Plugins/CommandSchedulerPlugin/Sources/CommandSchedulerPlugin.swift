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
    /// 区带意图：只剩任务列表一条（块内已无工具行）。竖轴总和
    /// （`padding` + `listMinimumHeight` + `padding`）必须 ≤ `minSize.height`，
    /// 违规说明块矮到装不下自己声明的最少行数，会向邻居溢出（宿主卡片不裁切）。
    ///
    /// 右上角悬浮「+」不单列探针：它必然落在列表区内，而 `BlockSizeVerifier`
    /// 对探针做**互不重叠**判定，单列会直接判错（同 CameraPlugin 的收敛结论）。
    static func schedulerLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let padding = SchedulerMetrics.padding
        return [
            BlockProbe(
                id: "scheduler.list",
                rect: CGRect(
                    x: padding, y: padding,
                    width: max(size.width - padding * 2, 1),
                    height: SchedulerMetrics.listMinimumHeight
                )
            ),
        ]
    }

    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "command.scheduler",
            displayName: L("scheduler.block.title"),
            kind: .drawer,
            // 三档：min 300×300 是用户明确要求的下限——卡片尺寸数学随块尺寸走
            // （卡片 = 块 − cardInset），300×300 下卡片 252×252，历史卡切单栏
            // 排布、表单卡靠卡片内滚动，功能不残。rec / max 不动：块大日志才好看。
            minSize: BlockPixelSize(width: 300, height: 300),
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

    /// 插件级设置（宿主块左上角齿轮入口：悬停即出现，不要求编辑模式）。块内不再
    /// 有齿轮按钮——它曾是同一份设置的第二个入口，现已由宿主齿轮完全覆盖。
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
