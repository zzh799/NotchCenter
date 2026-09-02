import AppKit
import NotchCenterKit
import SwiftUI

/// PomodoroPlugin（官方番茄钟插件）：专注/休息循环 + 随机间隔提示音微休息
/// （参考 JokerQianwei/Focus 的间隔效应与随机提醒设计）。
///
/// 运行期间经活动摘要通道（HostController.showActivitySummary）在刘海紧凑带
/// 提交迷你进度摘要（阶段简介 + 剩余时间 + 进度），收起态也可一瞥当前状态；
/// 完整控制（暂停/跳过/停止）在抽屉控制卡。同时提供紧凑快捷开关与状态栏
/// 菜单项；设置覆盖计时 / 随机提示音 / 声音效果三组。
@objc(PomodoroPlugin) @MainActor
public final class PomodoroPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "pomodoro.toggle",
                displayName: L("block.compact.name"),
                kind: .compact,
                interaction: .custom,
                symbolName: "timer",
                makeView: { context in
                    AnyView(PomodoroCompactView(context: context))
                }
            ),
            NotchBlock(
                id: "pomodoro.timer",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                supportedSizes: [.medium, .large],
                defaultSize: .medium,
                // 静态控制卡、不消费横向滚动：其上滑动直接切页。
                symbolName: "timer",
                scrollUsage: .none,
                makeView: { context in
                    AnyView(PomodoroDrawerBlockView(context: context))
                }
            ),
        ]
    }

    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? {
        { _ in
            AnyView(PomodoroSettingsView())
        }
    }

    public var menuItems: [PluginMenuItem] {
        let running = PomodoroStore.shared.display.phase != .idle
        return [
            PluginMenuItem(
                id: "pomodoro.menu.toggle",
                title: running ? L("menu.stop") : L("menu.start"),
                systemImage: running ? "stop.fill" : "timer",
                action: {
                    if running {
                        PomodoroStore.shared.stop()
                    } else {
                        PomodoroStore.shared.start()
                    }
                }
            )
        ]
    }

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        PomodoroStore.shared.resolve(stateStore: stateStore, hostController: hostController)
    }

    public func pluginWasDisabled() {
        PomodoroStore.shared.suspend()
    }
}
