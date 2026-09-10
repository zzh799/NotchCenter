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
    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe；区带镜像
    /// PomodoroBlockViews.runningContent 的布局常量——运行中为最满形态：
    /// 纵向内边距 8、行距 8、状态单行 18、倒计时 34、进度条 4、控制钮 24）。
    /// 意图：四行固定区带须完整落在 minSize 盒内且互不重叠；盒高小于总需求
    /// （8+18+8+34+8+4+8+24+8=120）时控制钮行越界 → 会向邻居溢出。
    private static func pomodoroLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let inset: CGFloat = 8
        let spacing: CGFloat = 8
        let statusHeight: CGFloat = 18
        let countdownHeight: CGFloat = 34
        let barHeight: CGFloat = 4
        let controlsHeight: CGFloat = 24
        let contentWidth = max(size.width - inset * 2, 0)
        let statusRect = CGRect(x: inset, y: inset, width: contentWidth, height: statusHeight)
        let countdownRect = CGRect(
            x: inset,
            y: inset + statusHeight + spacing,
            width: contentWidth,
            height: countdownHeight)
        let barRect = CGRect(
            x: inset,
            y: inset + statusHeight + spacing + countdownHeight + spacing,
            width: contentWidth,
            height: barHeight)
        // 最末区带并入底部内边距，使越界触发点与真实总需求（120）一致。
        let controlsRect = CGRect(
            x: inset,
            y: inset + statusHeight + spacing + countdownHeight + spacing + barHeight + spacing,
            width: contentWidth,
            height: controlsHeight + inset)
        return [
            BlockProbe(id: "pomodoro.status", rect: statusRect),
            BlockProbe(id: "pomodoro.countdown", rect: countdownRect),
            BlockProbe(id: "pomodoro.progress", rect: barRect),
            BlockProbe(id: "pomodoro.controls", rect: controlsRect),
        ]
    }

    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe；区带镜像
    /// PomodoroPageViews 的 `PomodoroPageMetrics` 布局常量）。
    ///
    /// 大组件是普通抽屉块（`.drawer` + `.newPageWhenOccupied`），**不豁免探针**：
    /// minSize 300×240 下探针若越界，内容会伸到同页邻居块上。因此只声明
    /// 三个"必须完整可见"的纵向区带（顶部大计时器 / 今日节奏 / 底部复盘标题），
    /// 中段的历史柱状区域允许在最小高度下被压缩——它是自适应的，不是硬需求。
    /// 区带高度按实际常量推导：顶部 34(标题+倒计时+进度条+动作)、横纵内边距 14。
    private static func pomodoroPageLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let horizontal = NotchTokens.Space.contentHorizontal
        let top: CGFloat = 0
        let heroHeight: CGFloat = 104
        let todayHeight: CGFloat = 46
        let contentWidth = max(size.width - horizontal * 2, 0)
        return [
            BlockProbe(
                id: "pomodoro.page.hero",
                rect: CGRect(x: horizontal, y: top, width: contentWidth, height: heroHeight)
            ),
            BlockProbe(
                id: "pomodoro.page.today",
                rect: CGRect(
                    x: horizontal,
                    y: top + heroHeight + 20,
                    width: contentWidth,
                    height: todayHeight)
            ),
            BlockProbe(
                id: "pomodoro.page.review",
                rect: CGRect(
                    x: horizontal,
                    y: top + heroHeight + 20 + todayHeight + 20,
                    width: contentWidth,
                    height: 20)
            ),
        ]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "pomodoro.timer",
                displayName: L("block.drawer.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 300, height: 120),
                maxSize: BlockPixelSize(width: 300, height: 240),
                recommendedSize: BlockPixelSize(width: 300, height: 120),
                symbolName: "timer",
                probes: { info in
                    Self.pomodoroLayoutProbes(for: info.frame.size)
                },
                makeView: { context in
                    AnyView(PomodoroDrawerBlockView(context: context))
                }
            ),
            // 大组件形态：大计时器 + 今日节奏 + 历史复盘。与上面的小控制卡是
            // 两种形态，二者可同时放置。`.newPageWhenOccupied` 只是"添加那一刻"
            // 的落点偏好（当前页被占用时另开一页），落位后与任何抽屉块同权。
            NotchBlock(
                id: "pomodoro.page",
                displayName: L("block.page.name"),
                kind: .drawer,
                minSize: BlockPixelSize(width: 300, height: 240),
                maxSize: BlockPixelSize(width: 900, height: 600),
                recommendedSize: BlockPixelSize(width: 600, height: 360),
                placement: .newPageWhenOccupied,
                symbolName: "timer.circle",
                probes: { info in
                    Self.pomodoroPageLayoutProbes(for: info.frame.size)
                },
                makeView: { context in
                    AnyView(PomodoroPageView(context: context))
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

    // MARK: 快捷动作

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
