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
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_PROBE"] == "1" {
            ResizeProbeWindowController.shared.show()
        }
        #endif
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

    /// 首次/二次进入编辑模式的对照诊断（NOTCHCENTER_EDIT_FIRST=1）：
    /// 收起态直接进入编辑（首次），逐步抓帧与窗口几何；退出后再次进入
    /// （二次）对照。定位“仅首次出现”的过渡异常。
    private func runFirstEditDiagnostic(_ panelController: NotchPanelController) {
        func dump(_ tag: String) {
            guard let pair = panelController.activePair else { return }
            NSLog(
                "edit-first[%@] drawer=%@ visible=%@ expanded=%@",
                tag,
                NSStringFromRect(pair.drawerPanel.frame),
                NSStringFromSize(panelController.uiState.drawerWindowSize),
                String(describing: panelController.uiState.isDrawerExpanded)
            )
        }
        func capture(_ suffix: String, at deadline: DispatchTime) {
            DispatchQueue.main.asyncAfter(deadline: deadline) {
                panelController.capturePanelsForDebug(suffix: suffix)
                dump(suffix)
            }
        }

        let enter = DispatchTime.now() + 1.0
        DispatchQueue.main.asyncAfter(deadline: enter) {
            NSLog("edit-first: enter #1 (from docked)")
            // 真实点击伴随应用激活；非激活窗口上 preference 不传播，
            // 诊断须对齐该前提。
            NSApp.activate(ignoringOtherApps: true)
            panelController.startEditMode()
        }
        for (i, dt) in [0.08, 0.18, 0.30, 0.45, 0.70, 1.00].enumerated() {
            capture("_first\(i)", at: enter + dt)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            NSLog("edit-first: exit")
            // 钉住抽屉避免自动收起：二次进入走“展开态”路径（与用户操作一致）。
            panelController.debugTogglePin()
            panelController.stopEditMode()
        }
        let reenter = DispatchTime.now() + 4.0
        DispatchQueue.main.asyncAfter(deadline: reenter) {
            NSLog("edit-first: enter #2 (from expanded)")
            NSApp.activate(ignoringOtherApps: true)
            panelController.startEditMode()
        }
        for (i, dt) in [0.15, 0.35, 0.70].enumerated() {
            capture("_second\(i)", at: reenter + dt)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
            NSApp.terminate(nil)
        }
    }

    /// 收起动画中帧诊断（NOTCHCENTER_COLLAPSE_PROBE=1）：展开抽屉（钉住防
    /// 自动收起）→ 收起 → 抓收起过程中帧。验证岛顶紧凑带是否钉死容器顶缘：
    /// 收起时 `content` 退出布局后，若动画容器 frame 的对齐为默认垂直居中，
    /// 只剩紧凑带的 VStack 会坠到仍在收缩的容器中部（图标从上往下掉）。
    private func runCollapseProbe(_ panelController: NotchPanelController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // preference 日志在非激活窗口上不传播，诊断须对齐真实点击的前提。
            NSApp.activate(ignoringOtherApps: true)
            panelController.expand(animated: true, activate: false)
            // 展开过渡同样逐帧自拍：图标应在展开全程保持静止。
            panelController.captureDrawerWindowSamples(prefix: "live_open")
            // 钉住避免 hover 模式下鼠标不在停留区被自动收起。
            panelController.debugTogglePin()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            panelController.capturePanelsForDebug(suffix: "_open")
        }
        let collapse = DispatchTime.now() + 2.0
        DispatchQueue.main.asyncAfter(deadline: collapse) {
            panelController.collapse(animated: true)
            // 逐帧自拍抽屉窗口：观察紧凑带在收起过渡中的实际位置（像素）。
            panelController.captureDrawerWindowSamples(prefix: "live_coll")
            // 需要几何对照（model vs presentation 层位置）时再开 layer dump。
            if ProcessInfo.processInfo.environment["NOTCHCENTER_COLLAPSE_LAYERS"] == "1" {
                panelController.dumpDrawerLayerTreeSamples()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            NSApp.terminate(nil)
        }
    }

    private func maybeRunSmokeTest() {
        guard ProcessInfo.processInfo.environment["NOTCHCENTER_SMOKE_TEST"] == "1" else { return }
        guard let panelController else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_AUTO"] == "1" {
            panelController.runResizeAutoDiagnostic()
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCENTER_EDIT_FIRST"] == "1" {
            runFirstEditDiagnostic(panelController)
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCENTER_COLLAPSE_PROBE"] == "1" {
            runCollapseProbe(panelController)
            return
        }
        #endif
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
            // 调试序列：展开动画中间帧 → 点击 pin → 截图；进入编辑模式 → 截图。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                panelController.capturePanelsForDebug(suffix: "_reveal")
                print("reveal captured")
            }
            // 调试序列：点击 pin → 截图（验证图标是否立即刷新）；进入编辑模式 → 截图。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                panelController.debugTogglePin()
                print("pin toggled")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                panelController.capturePanelsForDebug(suffix: "_pin")
                print("pin captured")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                panelController.startEditMode()
                print("edit mode entered")
            }
            // 编辑过渡中帧：窗口 frame（AppKit 0.35s）接近完成、内容 spring
            // （约 0.55s 收尾）仍落后的错位期抓图，验证内容顶对齐
            // （紧凑带不下坠、菜单栏不漏出）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.78) {
                panelController.capturePanelsForDebug(suffix: "_editmid")
                print("edit mid captured")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                panelController.capturePanelsForDebug(suffix: "_edit")
                print("edit captured")
            }
            // 拖拽排序验证：预留落点后抓帧窗口，供外部输入驱动在 6-9s 间执行拖放。
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
                panelController.capturePanelsForDebug(suffix: "_afterdrag")
                print("after-drag captured")
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