import AppKit
import Combine
import LidAngleKit
import NotchCenterKit
import SwiftUI

/// LidAngleDepthPlugin（刘海角度感应与合盖透视效果）。
///
/// 移植 [Mac-Duo](https://github.com/sumimakito/Mac-Duo)（Apache-2.0）：合盖时内置屏
/// 内容做透视倾斜、高斯模糊与变暗，随盖角实时驱动。署名见同目录 `NOTICE` 与
/// `README.md`。
///
/// 组成：
/// - **效果本体**是一个全屏覆盖窗（`DepthOverlay` + Metal 渲染器），不属于刘海的
///   任何一种块，窗口生命周期由本插件自持；
/// - **刘海侧**提供抽屉块控制台（`lidangle.console`）、设置界面与快捷按钮
///   （`lidangle.toggle`）；
/// - **盖角感应**下沉到可复用动态库 `LidAngleKit`，第三方插件可直接引用。
///
/// 决策记录：`docs/agent-notes/implemented/2026-09-11-lid-angle-depth-effect.md`。
@objc(LidAngleDepthPlugin)
@MainActor
public final class LidAngleDepthPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {

    private var stateStore: StateStore?
    private var preferences: LidDepthPreferences?
    private var controller: LidDepthController?
    private var hostController: (any HostController)?

    public override init() {
        super.init()
    }

    // MARK: - 块

    /// 打包期最小尺寸遮挡校验探针(官方 drawer 块门禁强制)。
    ///
    /// 常量与 `LidConsoleMetrics` / `LidConsoleBlockView` 的 `VStack` 同源:
    /// 自上而下四条带各占一段,末段并入底部内边距,这样"minSize 矮于总需求"
    /// 会精确触发越界。
    private static func consoleLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let metrics = LidConsoleMetrics.self
        let width = metrics.contentWidth(for: size)
        let origins = metrics.bandOrigins(for: size)
        return [
            BlockProbe(
                id: "lidangle.header",
                rect: CGRect(x: metrics.inset, y: origins[0], width: width, height: metrics.headerHeight)),
            BlockProbe(
                id: "lidangle.readout",
                rect: CGRect(x: metrics.inset, y: origins[1], width: width, height: metrics.readoutHeight)),
            BlockProbe(
                id: "lidangle.gauge",
                rect: CGRect(x: metrics.inset, y: origins[2], width: width, height: metrics.gaugeHeight)),
            BlockProbe(
                id: "lidangle.actions",
                rect: CGRect(x: metrics.inset, y: origins[3], width: width, height: metrics.actionHeight)),
        ]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "lidangle.console",
                displayName: L("block.console.name"),
                kind: .drawer,
                // 四条带 + 内边距的最小可读高度:
                //   10 + 20+8 + 46+8 + 18+8 + 24 + 10 = 152
                minSize: BlockPixelSize(width: 200, height: 152),
                maxSize: BlockPixelSize(width: 620, height: 460),
                recommendedSize: BlockPixelSize(width: 260, height: 172),
                symbolName: "laptopcomputer.trianglebadge.exclamationmark",
                probes: { info in Self.consoleLayoutProbes(for: info.frame.size) },
                makeView: { context in
                    AnyView(LidConsoleBlockView(
                        context: context,
                        controller: LidDepthModel.shared.controller,
                        preferences: LidDepthModel.shared.preferences
                    ))
                }
            ),
        ]
    }

    // MARK: - 服务注入

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.stateStore = stateStore
        self.hostController = hostController
        let model = LidDepthModel.shared.resolve(stateStore: stateStore)
        preferences = model.preferences
        controller = model.controller
    }

    public func pluginWasDisabled() {
        // 禁用即收掉覆盖窗与流。注意不在这里卸载 bundle(插件开发指南 §3.4)。
        controller?.stop()
    }

    // MARK: - 设置界面

    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? {
        { [weak self] context in
            guard let self, let preferences, let controller else {
                return AnyView(EmptyView())
            }
            return AnyView(LidDepthSettingsView(
                preferences: preferences,
                controller: controller,
                settingsContext: context
            ))
        }
    }

    // MARK: - 状态栏菜单

    public var menuItems: [PluginMenuItem] {
        guard let preferences, let controller else { return [] }
        return [
            PluginMenuItem(
                id: "lidangle.menu.preview",
                title: L("menu.preview"),
                systemImage: "eye",
                action: { [weak controller] in controller?.runPreview() }
            ),
            PluginMenuItem(
                id: "lidangle.menu.toggle",
                title: preferences.isEnabled ? L("menu.disable") : L("menu.enable"),
                systemImage: preferences.isEnabled ? "rectangle.slash" : "rectangle.on.rectangle",
                action: { [weak preferences] in
                    guard let preferences else { return }
                    preferences.isEnabled.toggle()
                }
            ),
        ]
    }

    // MARK: - 快捷动作

    private var quickActionCache: [QuickAction]?
    private var quickActionCancellables: Set<AnyCancellable> = []

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        guard let preferences else { return [] } // attachServices 前无 store;宿主不在该窗口期读取。
        let toggle = QuickAction(
            id: "lidangle.toggle",
            displayName: L("quick.toggle.name"),
            systemImage: "laptopcomputer.trianglebadge.exclamationmark",
            kind: .toggle,
            isActive: preferences.isEnabled,
            execute: { [weak preferences] in
                preferences?.isEnabled.toggle()
            }
        )
        // 开关态同步:store 状态变化 → 按钮点亮/熄灭(同一份状态)。
        preferences.$isEnabled
            .sink { [weak toggle] isOn in
                toggle?.isActive = isOn
            }
            .store(in: &quickActionCancellables)
        let actions = [toggle]
        quickActionCache = actions
        return actions
    }
}

/// 插件内共享模型:抽屉块、设置界面与快捷按钮共享同一份 store 与控制器。
///
/// 单例是必要的:效果覆盖窗、抓帧流与 display link 都必须**全进程唯一**,
/// 抽屉块在多块屏上会渲染多个视图实例,每实例各建一份控制器会开出多个覆盖窗。
@MainActor
final class LidDepthModel {
    static let shared = LidDepthModel()

    private(set) var preferences: LidDepthPreferences!
    private(set) var controller: LidDepthController!

    private init() {}

    /// 首次注入时构建;重复调用返回同一份。
    @discardableResult
    func resolve(stateStore: StateStore) -> LidDepthModel {
        if preferences == nil {
            let store = LidDepthPreferences(stateStore: stateStore)
            preferences = store
            controller = LidDepthController(preferences: store)
        }
        // 观察本身是幂等的:控制器内部有 isRunning 守卫。
        controller.start()
        return self
    }
}
