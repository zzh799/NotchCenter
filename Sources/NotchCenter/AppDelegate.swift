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
        maybeRunPlacementProbe()
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

    // MARK: - 摆位探针（开发期诊断，非发布路径）

    /// 切页让位诊断（`NOTCHCENTER_PLACEMENT_PROBE=1`）：真实布局 + 真实屏幕上
    /// 复现「设置打开 → 切到自然高度不同的页」，转储三份几何快照定位共享
    /// 路径哪一环空转。快照 A = 打开设置后；B = selectDrawerPage 走完真实
    /// 链路后；C = 手动补调一次 updateSettingsPlacement 后。跑完自动退出。
    private func maybeRunPlacementProbe() {
        guard ProcessInfo.processInfo.environment["NOTCHCENTER_PLACEMENT_PROBE"] == "1",
              let panelController else { return }

        func dump(_ tag: String) {
            let c = panelController
            let pair = c.activePair ?? c.pairs.first
            print("=== 快照 \(tag) ===")
            print("activePage=\(c.uiState.drawerActivePage) pages=\(c.layoutEngine.drawerPages) expanded=\(c.isDrawerExpanded()) settingsPresented=\(c.isSettingsPresented)")
            for page in c.layoutEngine.drawerPages {
                let size = c.layoutEngine.drawerWindowSize(page: page)
                print("  page \(page): natural \(size)")
            }
            if let pair {
                print("  screen frame=\(pair.screenFrame) visible=\(pair.screen.visibleFrame) compactH=\(pair.layout.compactHeight)")
                print("  maxDrawerHeight=\(c.maxDrawerHeight(for: pair)) bandH=\(c.settingsWindowBandHeight)")
            }
            print("  settingsPlacement=\(String(describing: c.settingsPlacement))")
            print("  drawerWindowSize(ui)=\(c.uiState.drawerWindowSize)")
            if let window = c.settingsWindowController?.window {
                print("  settingsWindow frame=\(window.frame) visible=\(window.isVisible)")
            } else {
                print("  settingsWindow=nil")
            }
        }

        print("=== 摆位探针启动 ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            print("--- showSettings ---")
            panelController.showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                dump("A:打开设置后")
                let pages = panelController.layoutEngine.drawerPages
                let active = panelController.uiState.drawerActivePage
                let target = pages
                    .filter { $0 != active }
                    .max {
                        panelController.layoutEngine.drawerWindowSize(page: $0).height
                            < panelController.layoutEngine.drawerWindowSize(page: $1).height
                    }
                guard let target else {
                    print("!!! 没有第二个页面可切，探针结束")
                    NSApp.terminate(nil)
                    return
                }
                print("--- selectDrawerPage(\(target)) ---")
                panelController.selectDrawerPage(target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    dump("B:真实切页链路后")
                    let changed = panelController.updateSettingsPlacement()
                    print("  手动 updateSettingsPlacement() 返回 changed=\(changed)")
                    dump("C:手动补裁后")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                }
            }
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