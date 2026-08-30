import AppKit
import NotchCenterKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // accessory 应用没有默认 Edit 菜单，标准编辑快捷键（⌘C 等）需要
        // 隐藏主菜单承载（见 EditMenuInstaller 顶部说明）。
        EditMenuInstaller.install()
        panelController = NotchPanelController()
        panelController?.showDocked()
        maybeRunSmokeTest()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.flush()
    }

    // MARK: - 设置面板（抽屉顶栏齿轮按钮触发；accessory 应用无菜单栏）

    @objc private func showSettings() {
        panelController?.showSettings()
    }

    @objc private func toggleDrawer() {
        guard let panelController else { return }
        if panelController.isDrawerExpanded() {
            panelController.collapse(animated: true)
        } else {
            panelController.expand(animated: true, activate: true)
        }
    }

    @objc private func editLayout() {
        panelController?.startEditMode()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Smoke test（开发期验证，非发布路径）

    /// 应用级健康检查（`NOTCHCENTER_SMOKE_TEST=1`）：打印已发现插件、
    /// 加载错误与布局校验结果后自动退出，供 CI 使用。
    private func maybeRunSmokeTest() {
        guard ProcessInfo.processInfo.environment["NOTCHCENTER_SMOKE_TEST"] == "1" else { return }
        guard let panelController else { return }

        print("=== NotchCenter smoke test ===")
        print("bundleURL: \(Bundle.main.bundleURL.path)")
        print("builtInPlugIns: \(CorePaths.builtInPlugInsDirectory.path)")
        print("userPlugIns: \(CorePaths.userPlugInsDirectory.path)")
        print("discovered: \(panelController.pluginManager.entries.map(\.metadata.pluginID))")
        print("invalidBundles: \(panelController.pluginManager.invalidBundles)")
        for entry in panelController.pluginManager.entries {
            print("plugin: \(entry.metadata.pluginID) enabled=\(entry.isEnabled) loaded=\(entry.instance != nil) blocks=\(entry.blocks.count) error=\(entry.loadError ?? "nil") settingsView=\(entry.instance?.settingsView != nil) stateStore=\(entry.stateStore != nil)")
        }
        print("layout: maxColumns=\(panelController.layoutEngine.userMaxColumns) enabled=\(panelController.layoutEngine.enabledPluginIDs.sorted())")
        print("layout issues: \(panelController.layoutEngine.validate().count)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 菜单动作载体（Action 需闭包，NSMenuItem 通过 representedObject 携带）

@MainActor
final class MenuActionItem: NSObject {
    let title: String
    let action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}