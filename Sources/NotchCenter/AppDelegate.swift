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
        #if DEBUG
        // 开发期诊断（默认不开）：NOTCHCENTER_SIZE_LAB=1 启动直开块尺寸对照
        // 实验室（SizeLabWindow）；常规入口在 设置 → 调试 页。
        if ProcessInfo.processInfo.environment["NOTCHCENTER_SIZE_LAB"] == "1" {
            panelController?.showSizeLab()
        }
        #endif
        maybeRunSmokeTest()
        maybeRunPlacementProbe()
        maybeRunDragProbe()
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

    // MARK: 拖拽驻留探针（开发期诊断，非发布路径）

    /// 胶囊驻留切页诊断（`NOTCHCENTER_DRAG_PROBE=1`）：真实布局 + 真实屏幕上
    /// 走一遍「起拖 → 注入指针压上目标页胶囊 → 驻留到点 → 切页」，配合
    /// `NOTCHCENTER_DRAG_PROBE_LOG=1` 逐步转储命中输入输出与驻留状态，
    /// 跑完自动退出。注入坐标由命中数学自身同源计算——若几何系统性偏移，
    /// capsuleHit 日志会直接呈现 miss/错槽，与真实拖拽的失效同源可见。
    private func maybeRunDragProbe() {
        guard ProcessInfo.processInfo.environment["NOTCHCENTER_DRAG_PROBE"] == "1",
              let panelController else { return }
        print("=== 拖拽驻留探针启动 ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let c = self.panelController else { return }
            if !c.isDrawerExpanded() { c.expand(animated: false, activate: true) }
            c.showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                self.runDragProbeSteps(c)
                // KEEP 模式：不退出、不收尾，会话保持给真实事件接管（外部
                // 注入 CGEvent 验证真实输入链路）。
                guard ProcessInfo.processInfo.environment["NOTCHCENTER_DRAG_PROBE_KEEP"] != "1" else {
                    print("=== KEEP 模式：会话保持，等待真实事件 ===")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// 探针几何转储：命中数学的全部输入 + 逐胶囊中心 + 驻留状态。
    private func dragProbeDump(_ c: NotchPanelController, tag: String) {
        guard let pair = c.activePair ?? c.pairs.first else {
            print("  [\(tag)] pair=nil")
            return
        }
        let mapper = c.drawerScreenMapper(for: pair)
        let pages = c.uiState.drawerPages
        let rowWidth = DrawerPagePillLayout.rowWidth(pageCount: pages.count)
        let centerX = mapper.visibleFrame.midX
            + DrawerPagePillLayout.rowCenterOffset(isEditing: c.uiState.isEditing)
        let rowLeft = centerX - rowWidth / 2
        let bandTop = mapper.visibleFrame.maxY - pair.layout.compactHeight
        print("  [\(tag)] active=\(c.uiState.drawerActivePage) pages=\(pages) editing=\(c.uiState.isEditing) dwell{\(BlockDragCoordinator.shared.dragProbeDwellSummary)}")
        print("  [\(tag)] visible=\(mapper.visibleFrame) compactH=\(pair.layout.compactHeight) band=[\(mapper.gridTopEdgeY), \(bandTop)]")
        print("  [\(tag)] row: left=\(rowLeft) width=\(rowWidth)")
        for (slot, page) in pages.enumerated() {
            let x = rowLeft + DrawerPagePillLayout.addButtonDiameter
                + DrawerPagePillLayout.addSpacing
                + CGFloat(slot) * DrawerPagePillLayout.step
                + DrawerPagePillLayout.pillWidth / 2
            print("  [\(tag)]   slot \(slot) page \(page) centerX=\(x)")
        }
    }

    private func runDragProbeSteps(_ c: NotchPanelController) {
        dragProbeDump(c, tag: "A:展开+设置后")
        guard let entry = c.pluginManager.entries.first(where: { $0.isEnabled && $0.instance != nil }),
              let block = entry.blocks.first(where: { $0.kind == .drawer }) else {
            print("!!! 没有可用抽屉块，探针结束")
            return
        }
        let span = block.sizeBox(
            cellWidth: NotchGridMetrics.cellWidth,
            cellHeight: NotchGridMetrics.cellHeight
        )?.recommended ?? GridSpan.globalMinimum
        let payload = BlockDragCoordinator.Payload(
            pluginID: entry.id,
            blockID: block.id,
            kind: .drawer,
            displayName: block.displayName,
            symbolName: block.symbolName,
            span: span,
            preview: nil
        )
        guard let pair = c.activePair ?? c.pairs.first,
              let slot = c.uiState.drawerPages.firstIndex(where: { $0 != c.uiState.drawerActivePage }) else {
            print("!!! 没有第二页可切，探针结束")
            return
        }
        let mapper = c.drawerScreenMapper(for: pair)
        let pages = c.uiState.drawerPages
        let rowWidth = DrawerPagePillLayout.rowWidth(pageCount: pages.count)
        let centerX = mapper.visibleFrame.midX
            + DrawerPagePillLayout.rowCenterOffset(isEditing: c.uiState.isEditing)
        let point = NSPoint(
            x: centerX - rowWidth / 2 + DrawerPagePillLayout.addButtonDiameter
                + DrawerPagePillLayout.addSpacing + CGFloat(slot) * DrawerPagePillLayout.step
                + DrawerPagePillLayout.pillWidth / 2,
            y: (mapper.gridTopEdgeY + mapper.visibleFrame.maxY - pair.layout.compactHeight) / 2
        )
        print("--- beginIfNeeded + updatePointer(at: \(point)) ---")
        BlockDragCoordinator.shared.beginIfNeeded(payload)
        BlockDragCoordinator.shared.updatePointer(at: point)
        dragProbeDump(c, tag: "B:注入后即刻")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.dragProbeDump(c, tag: "C:驻留中(+0.35s)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            print("  [D:+1.2s] active=\(c.uiState.drawerActivePage) dwell{\(BlockDragCoordinator.shared.dragProbeDwellSummary)}")
            print("=== 探针结束（active 应等于 dwell 目标页）===")
            if ProcessInfo.processInfo.environment["NOTCHCENTER_DRAG_PROBE_KEEP"] != "1" {
                BlockDragCoordinator.shared.cancel()
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