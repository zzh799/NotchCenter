import AppKit
import Combine
import NotchCenterKit
import SwiftUI

/// PomodoroPlugin（官方番茄钟插件）：专注/休息循环 + 随机间隔提示音微休息
/// （参考 JokerQianwei/Focus 的间隔效应与随机提醒设计）。
///
/// 运行期间经活动摘要通道（HostController.showActivitySummary）在刘海紧凑带
/// 提交迷你进度摘要（阶段简介 + 剩余时间 + 进度），收起态也可一瞥当前状态；
/// 完整控制（暂停/跳过/停止）在抽屉控制卡。一键入口统一为**快捷按钮**
/// （`pomodoro.toggle` 智能启停 + start/pause/reset，快速区与按钮盒均可放）；
/// 另有状态栏菜单项；设置覆盖计时 / 随机提示音 / 声音效果三组。
@objc(PomodoroPlugin) @MainActor
public final class PomodoroPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] {
        [
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

    // MARK: 快捷动作（Quick Action，可被快捷按钮盒收纳）

    private var quickActionCache: [QuickAction]?
    private var quickActionCancellables: Set<AnyCancellable> = []

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        let store = PomodoroStore.shared
        // 智能启停（前身即默认进带的 `pomodoro.toggle` 紧凑块，语义完全一致：
        // 空闲 → 开始；运行 → 停止）。
        let toggle = QuickAction(
            id: "pomodoro.toggle",
            displayName: L("quick.toggle.name"),
            systemImage: "timer",
            kind: .toggle,
            isActive: store.display.phase != .idle,
            defaultInStrip: true,
            execute: { [weak store] in
                guard let store else { return }
                if store.display.phase != .idle {
                    store.stop()
                } else {
                    store.start()
                }
            }
        )
        // 开关态同步：阶段变化 → 按钮点亮/熄灭。
        store.$display
            .sink { [weak toggle] display in
                toggle?.isActive = display.phase != .idle
            }
            .store(in: &quickActionCancellables)
        let actions = [toggle] + [
            QuickAction(
                id: "pomodoro.start",
                displayName: L("quick.start.name"),
                systemImage: "play.fill",
                kind: .action,
                execute: { [weak store] in
                    store?.start()
                }
            ),
            QuickAction(
                id: "pomodoro.pause",
                displayName: L("quick.pause.name"),
                systemImage: "pause.fill",
                kind: .action,
                execute: { [weak store] in
                    store?.togglePause()
                }
            ),
            QuickAction(
                id: "pomodoro.reset",
                displayName: L("quick.reset.name"),
                systemImage: "stop.fill",
                kind: .action,
                execute: { [weak store] in
                    store?.stop()
                }
            ),
        ]
        quickActionCache = actions
        return actions
    }
}
