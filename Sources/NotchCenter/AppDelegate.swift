import AppKit
import NotchCenterKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // accessory 应用没有默认 Edit 菜单，标准编辑快捷键（⌘C 等）需要
        // 隐藏主菜单承载（见 EditMenuInstaller 顶部说明）。
        EditMenuInstaller.install()
        // 合成基准：控制器构造前先把布局读写重定向到临时文件（布局是
        // LayoutEngine init 时读盘的，之后再改环境变量已经晚了）。
        let benchMode = DrawerBenchLayout.requestedMode
        if benchMode != nil { DrawerBenchLayout.redirectLayoutFile() }
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
        maybeRunDrawerOpenBench(synthetic: benchMode)
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

    // MARK: 抽屉打开基准（开发期诊断，非发布路径）

    /// 抽屉打开基准（`NOTCHCENTER_DRAWER_BENCH=1`，或 `=synthetic` 用合成
    /// N 曲线布局）：逐页 ×N 轮走**真实**开合链路（`expand` → `rebuildContent`
    /// → 窗口上线 → SwiftUI 挂载 → 淡入），每轮由 `DrawerOpenPerfCollector`
    /// 打印一条分解，结束打印按页（= 块数）汇总表后自动退出。轮数经
    /// `NOTCHCENTER_DRAWER_BENCH_ROUNDS` 覆盖（默认 3）。
    ///
    /// 之所以在本机跑而不是单测里跑：耗时的大头（SwiftUI 构建 + AppKit 视图
    /// 创建 + 布局）必须有真窗口与真插件视图才成立，宿主侧纯计算测不出 N 的
    /// 曲线。只读运行时状态（切激活页不落盘），不改任何布局数据。
    ///
    /// `synthetic` 模式见 `DrawerBenchLayout`：跑同一份合成布局，优化前后数字可比。
    private func maybeRunDrawerOpenBench(synthetic: DrawerBenchLayout.Mode?) {
        let requested = ProcessInfo.processInfo.environment["NOTCHCENTER_DRAWER_BENCH"]
        guard requested == "1" || synthetic != nil, let panelController else { return }
        if let synthetic, !installSyntheticBenchLayout(panelController, mode: synthetic) {
            print("!!! 合成基准布局生成失败（一个可用抽屉块都没有？），基准结束")
            NSApp.terminate(nil)
            return
        }
        let rounds = ProcessInfo.processInfo.environment["NOTCHCENTER_DRAWER_BENCH_ROUNDS"]
            .flatMap(Int.init) ?? 3
        let pages = panelController.layoutEngine.drawerPages
        guard !pages.isEmpty else {
            print("!!! 没有抽屉页，基准结束")
            NSApp.terminate(nil)
            return
        }

        print("=== 抽屉打开基准启动（模式：\(synthetic?.pageLabel ?? "用户真实布局")）===")
        print("pages=\(pages) rounds=\(max(rounds, 1)) "
            + "cell=\(NotchGridMetrics.cellWidth)x\(NotchGridMetrics.cellHeight) "
            + "spacing=\(NotchGridMetrics.spacing) padding=\(NotchGridMetrics.contentPadding)")
        if let pair = panelController.activePair ?? panelController.pairs.first {
            print("screen=\(pair.screenFrame.size) maxDrawerHeight=\(panelController.maxDrawerHeight(for: pair))")
        }
        for page in pages {
            let blocks = panelController.layoutEngine.drawerBlocks(onPage: page).count
            let natural = panelController.layoutEngine.drawerWindowSize(page: page)
            let visible = panelController.drawerWindowSize(for: panelController.activePair, page: page)
            let title = panelController.layoutEngine.drawerPageTitles[String(page)] ?? ""
            print("  page \(page)[\(title)]: blocks=\(blocks) natural=\(natural) visible=\(visible)"
                + (natural.height > visible.height ? "  [屏幕封顶→可滚动]" : ""))
        }

        var steps: [(round: Int, page: Int)] = []
        for round in 1...max(rounds, 1) {
            for page in pages { steps.append((round, page)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.runDrawerBenchStep(0, steps: steps)
        }
    }

    /// 合成基准的布局装载：块型取本机**已加载可用**的抽屉块（与
    /// `buildDrawerElements` 同一条可用性判据——未安装插件的块会被静默跳过，
    /// 不筛会让 N 曲线残废），换模型后重建内容。
    private func installSyntheticBenchLayout(
        _ controller: NotchPanelController,
        mode: DrawerBenchLayout.Mode
    ) -> Bool {
        let shapes = controller.layoutEngine.drawerPages
            .flatMap { controller.layoutEngine.drawerBlocks(onPage: $0) }
            .filter { placement in
                guard let entry = controller.pluginManager.entry(for: placement.pluginID),
                      entry.isEnabled,
                      let block = controller.pluginManager.block(
                          pluginID: placement.pluginID,
                          blockID: placement.blockID
                      ) else { return false }
                return block.kind.occupiesDrawerGrid
            }
        guard let model = DrawerBenchLayout.writeSyntheticLayout(
            shapes: shapes,
            template: controller.layoutEngine.model,
            mode: mode
        ) else { return false }
        controller.layoutEngine.modelForTesting = model
        controller.updateScreenConstraint()
        controller.refreshCompactGeometry()
        controller.rebuildContent()
        return true
    }

    /// 基准单步：解钉 → 收起（若展开）→ 切页 → 展开 → 钉住 → **等这次展开
    /// 读完** → 下一步。
    ///
    /// **必须等会话收尾再走下一步**：重页（15+ 块）的"挂载 + 淡入"可达 1.5–2.4s，
    /// 固定步间隔会让下一次 `begin()` 顶掉上一次未收尾的会话——样本页码滞后一步、
    /// 淡入埋点串到下一次会话（实测出现过 page=5 的样本挂在 round3/page0 步骤上）。
    /// 等待上限由收集器自己的 5s 看门狗兜底，不会永久挂住。
    ///
    /// **必须钉住**：hover 触发模式下，鼠标不在抽屉停留区时 `handleMouseLocation`
    /// 会在 0.25s 后安排收起——不钉住量到的是"展开被中途打断"的读数（且
    /// 淡入段的埋点根本没机会落）。钉住只改停留守卫，不改展开路径本身。
    private func runDrawerBenchStep(_ index: Int, steps: [(round: Int, page: Int)]) {
        guard let controller = panelController else { return }
        guard index < steps.count else {
            print(DrawerOpenPerfCollector.shared.report())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return
        }
        let step = steps[index]
        print("--- bench round \(step.round) page \(step.page) ---")
        controller.isPinned = false
        if controller.isDrawerExpanded() {
            controller.collapse(animated: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            controller.uiState.drawerActivePage = step.page
            DrawerOpenPerfCollector.shared.pendingLabel = "r\(step.round)p\(step.page)"
            controller.expand(animated: true, activate: false)
            controller.isPinned = true
            self.waitForOpenToSettle(attempt: 0) {
                self.runDrawerBenchStep(index + 1, steps: steps)
            }
        }
    }

    /// 等当前展开的探针会话收尾（样本已入表）再继续；每 100ms 复查一次，
    /// 上限交给收集器的看门狗（会话被判未完成后同样收尾）。
    private func waitForOpenToSettle(attempt: Int, then next: @escaping () -> Void) {
        guard DrawerOpenPerfCollector.shared.isSessionActive, attempt < 80 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: next)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.waitForOpenToSettle(attempt: attempt + 1, then: next)
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