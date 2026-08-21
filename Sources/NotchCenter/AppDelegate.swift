import AppKit
import NotchCenterKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = NotchPanelController()
        panelController?.showDocked()
        buildStatusItem()
        buildMenu()
        maybeRunSmokeTest()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.flush()
    }

    // MARK: - 状态栏菜单（文档 §6.1 / §4.8）

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "NotchCenter")
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    private func buildMenu() {
        let rootItem = NSMenuItem(title: "NotchCenter", action: nil, keyEquivalent: "")
        let mainMenu = NSMenu()
        rootItem.submenu = mainMenu

        let toggleItem = NSMenuItem(title: "Show Drawer", action: #selector(toggleDrawer), keyEquivalent: "e")
        toggleItem.target = self
        mainMenu.addItem(toggleItem)

        let editItem = NSMenuItem(title: "Edit Layout…", action: #selector(editLayout), keyEquivalent: "l")
        editItem.target = self
        mainMenu.addItem(editItem)

        let quitItem = NSMenuItem(title: "Quit NotchCenter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        mainMenu.addItem(quitItem)

        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(rootItem)
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
            print("plugin: \(entry.metadata.pluginID) enabled=\(entry.isEnabled) loaded=\(entry.instance != nil) blocks=\(entry.blocks.count) error=\(entry.loadError ?? "nil")")
        }
        print("layout: maxColumns=\(panelController.layoutEngine.userMaxColumns) enabled=\(panelController.layoutEngine.enabledPluginIDs.sorted())")
        print("layout issues: \(panelController.layoutEngine.validate().count)")

        if ProcessInfo.processInfo.environment["NOTCHCENTER_SCREENSHOT"] == "1" {
            // 截图验证模式：0.8s 后展开抽屉，2.5s 后把两个面板渲染为 PNG，25s 后退出。
            print("screenshot mode: expanding drawer in 0.8s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                panelController.expand(animated: true, activate: false)
            }
            if ProcessInfo.processInfo.environment["NOTCHCENTER_EDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    panelController.startEditMode()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                panelController.capturePanelsForDebug()
                print("panels captured")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                NSApp.terminate(nil)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - 状态栏菜单动态刷新：插件贡献与状态随启用变化重建（文档 §4.8）

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        populateStatusMenu(menu)
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        guard let panelController else { return }

        let toggleTitle = panelController.isDrawerExpanded() ? "Hide Drawer" : "Show Drawer"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleDrawer), keyEquivalent: "e")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let editItem = NSMenuItem(title: "Edit Layout…", action: #selector(editLayout), keyEquivalent: "l")
        editItem.target = self
        menu.addItem(editItem)

        menu.addItem(.separator())

        let triggerItem = NSMenuItem(title: "Trigger Mode", action: nil, keyEquivalent: "")
        triggerItem.submenu = makeTriggerModeMenu(settingsStore: panelController.settingsStore)
        menu.addItem(triggerItem)

        let columnsItem = NSMenuItem(title: "Drawer Columns", action: nil, keyEquivalent: "")
        columnsItem.submenu = makeColumnsMenu(engine: panelController.layoutEngine)
        menu.addItem(columnsItem)

        menu.addItem(.separator())

        // 插件菜单贡献（按插件分组，最多 3 项/插件）。
        for contribution in panelController.pluginManager.menuContributions() {
            let pluginItem = NSMenuItem(title: contribution.displayName, action: nil, keyEquivalent: "")
            pluginItem.submenu = makePluginMenu(contribution)
            menu.addItem(pluginItem)
        }

        menu.addItem(.separator())

        let pluginsItem = NSMenuItem(title: "Plugin Manager…", action: #selector(showPluginManager), keyEquivalent: ",")
        pluginsItem.target = self
        menu.addItem(pluginsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchCenter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeTriggerModeMenu(settingsStore: SettingsStore) -> NSMenu {
        let menu = NSMenu()
        for mode in SettingsStore.TriggerMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(setTriggerMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = mode == .hover ? 0 : 1
            item.state = settingsStore.triggerMode == mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeColumnsMenu(engine: LayoutEngine) -> NSMenu {
        let menu = NSMenu()
        for columns in 2...8 {
            let item = NSMenuItem(
                title: "\(columns) Columns",
                action: #selector(setColumns(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = columns
            item.state = engine.userMaxColumns == columns ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makePluginMenu(
        _ contribution: (pluginID: String, displayName: String, items: [PluginMenuItem])
    ) -> NSMenu {
        let menu = NSMenu()
        for item in contribution.items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(pluginMenuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = MenuActionItem(title: item.title, action: item.action)
            if let systemImage = item.systemImage {
                menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    // MARK: 菜单动作

    @objc private func setTriggerMode(_ sender: NSMenuItem) {
        panelController?.settingsStore.triggerMode = sender.tag == 1 ? .click : .hover
    }

    @objc private func setColumns(_ sender: NSMenuItem) {
        guard let panelController else { return }
        panelController.layoutEngine.setUserMaxColumns(sender.tag)
        panelController.refreshAfterLayoutChange()
    }

    @objc private func showPluginManager() {
        panelController?.showPluginManager()
    }

    @objc private func pluginMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuActionItem else { return }
        payload.action()
    }
}

/// 菜单项的闭包动作载体（Action 需闭包，NSMenuItem 通过 representedObject 携带）。
@MainActor
final class MenuActionItem: NSObject {
    let title: String
    let action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}