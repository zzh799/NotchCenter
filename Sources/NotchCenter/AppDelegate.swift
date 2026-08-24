import AppKit
import NotchCenterKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = NotchPanelController()
        panelController?.showDocked()
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

    #if DEBUG
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
    #endif

    private func maybeRunSmokeTest() {
        guard ProcessInfo.processInfo.environment["NOTCHCENTER_SMOKE_TEST"] == "1" else { return }
        guard let panelController else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTCHCENTER_DRAGSCROLL_AUTO"] == "1" {
            panelController.runDragScrollAutoDiagnostic()
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_AUTO"] == "1" {
            panelController.runResizeAutoDiagnostic()
            return
        }
        if ProcessInfo.processInfo.environment["NOTCHCENTER_SHRINKSCROLL_PROBE"] == "1" {
            panelController.runShrinkScrollProbe()
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