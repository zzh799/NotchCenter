import AppKit
import NotchCenterKit
import SwiftUI

/// PomodoroPlugin（官方番茄钟插件）：专注/休息循环 + 随机间隔提示音微休息
/// （参考 JokerQianwei/Focus 的间隔效应与随机提醒设计）。
///
/// 运行期间经活动岛机制（HostController.showActivityIsland）在刘海下方
/// 常驻一个计时小岛：紧凑态显示倒计时，悬停展开控制，微休息自动展开提醒。
/// 同时提供紧凑快捷开关、抽屉控制卡与状态栏菜单项；设置覆盖计时 / 随机
/// 提示音 / 声音效果三组。
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
                symbolName: "timer",
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
