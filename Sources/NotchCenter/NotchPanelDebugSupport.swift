import AppKit
import NotchCenterKit

// MARK: - 插件管理窗口与调试支持

extension NotchPanelController {
    /// 开发期调试：模拟点击钉住按钮（走与视图相同的动作路径）。
    func debugTogglePin() {
        drawerActions().onTogglePin()
    }

    /// 开发期调试：把所有屏幕的面板内容渲染为 PNG（无需屏幕录制权限）。
    func capturePanelsForDebug(suffix: String = "") {
        func writePNG(of view: NSView?, to path: String) {
            guard let view else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        for (index, pair) in pairs.enumerated() {
            let tag = pairs.count > 1 ? "\(suffix)_\(index)" : suffix
            writePNG(of: pair.hotPanel.contentView, to: "/tmp/nc_hot\(tag).png")
            writePNG(of: pair.drawerPanel.contentView, to: "/tmp/nc_drawer\(tag).png")
            print("debug[\(index)] \(pair.screen.localizedName) hot=\(pair.hotPanel.frame) drawer=\(pair.drawerPanel.frame)")
        }
        print("debug expanded=\(isExpanded) screens=\(pairs.count)")
        print("debug sizes: content=\(layoutEngine.drawerContentSize()) window=\(layoutEngine.drawerWindowSize()) blocks=\(layoutEngine.drawerBlocks.count)")
        let layout = primaryLayout()
        print("debug compact: height=\(layout.compactHeight) notch=\(layout.notchSize) count=\(compactIconCount)")
    }

    /// 开发期调试：把设置面板窗口渲染为 PNG（NOTCHCENTER_SETTINGS_PROBE 用）。
    func captureSettingsWindowForDebug(suffix: String = "") {
        guard let window = settingsWindowController?.window,
              let contentView = window.contentView else {
            print("debug settings: window not available")
            return
        }
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        contentView.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let path = "/tmp/nc_settings\(suffix).png"
            try? data.write(to: URL(fileURLWithPath: path))
            print("debug settings: captured \(Int(bounds.width))x\(Int(bounds.height)) -> \(path)")
        }
        print("debug settings frame=\(NSStringFromRect(window.frame)) level=\(window.level.rawValue)")
        print("debug settings presented=\(isSettingsPresented) expanded=\(isExpanded)")
    }

    /// 开发期调试：直接切到设置面板的某一页（探针抓图用）。
    func debugSelectSettingsPage(_ page: SettingsPage) {
        settingsWindowController?.select(page)
    }

    /// 拖拽落点自动化探针（NOTCHCENTER_DRAGDROP_PROBE=1）：绕开真实鼠标事件，
    /// 直接驱动协调器（begin → updatePointer(at:) → commit），逐块拖到目标区
    /// 中心，验证落点判定与落位；真实手势路径由人工验证。
    func runDragDropProbe() {
        guard let pair = activePair ?? pairs.first else {
            print("dragdrop: no screen pair")
            return
        }
        // 探针会真实落位（写 layout.json）：先快照，结束前回滚，
        // 避免把调试用的块留在用户的日常布局里。
        let snapshot = layoutEngine.model
        let visible = visibleDrawerFrame(for: pair)
        // 快速区中心：可见面板顶部、紧凑带高度的一半处。
        let compactPoint = NSPoint(
            x: visible.midX,
            y: visible.maxY - pair.layout.compactHeight / 2
        )
        // 抽屉网格首行中心：紧凑带 + 顶栏之下再往下半格。
        let gridPoint = NSPoint(
            x: visible.midX,
            y: visible.maxY - pair.layout.compactHeight
                - NotchGridMetrics.drawerTopBarHeight
                - NotchGridMetrics.cellHeight / 2
        )
        print("dragdrop visible=\(NSStringFromRect(visible)) compact=\(NSStringFromPoint(compactPoint)) grid=\(NSStringFromPoint(gridPoint))")

        for entry in pluginManager.entries where entry.isEnabled && entry.instance != nil {
            for block in entry.blocks {
                let span: GridSpan
                if block.kind == .drawer {
                    let defaultSpan = block.defaultSize?.gridSpan ?? (columns: 1, rows: 1)
                    span = GridSpan(columns: defaultSpan.columns, rows: defaultSpan.rows)
                } else {
                    span = GridSpan(columns: 1, rows: 1)
                }
                let payload = BlockDragCoordinator.Payload(
                    pluginID: entry.id,
                    blockID: block.id,
                    kind: block.kind,
                    displayName: block.displayName,
                    symbolName: block.symbolName,
                    span: span
                )
                let target = block.kind == .compact ? compactPoint : gridPoint
                let isCompact = block.kind == .compact
                let before = isCompact
                    ? layoutEngine.compactSlots.count
                    : layoutEngine.drawerBlocks.count

                BlockDragCoordinator.shared.beginIfNeeded(payload)
                BlockDragCoordinator.shared.updatePointer(at: target)
                let zone = BlockDragCoordinator.shared.zone
                BlockDragCoordinator.shared.commit()

                let after = isCompact
                    ? layoutEngine.compactSlots.count
                    : layoutEngine.drawerBlocks.count
                print(
                    "dragdrop \(entry.id)/\(block.id) kind=\(block.kind) "
                        + "point=\(NSStringFromPoint(target)) zone=\(String(describing: zone)) "
                        + "count=\(before)->\(after)"
                )
            }
        }
        print("dragdrop layoutIssues=\(layoutEngine.validate().count)")

        // 回滚：恢复探针开始前的布局（落位验证已经打印，不留痕迹）。
        layoutEngine.modelForTesting = snapshot
        refreshCompactGeometry()
        rebuildContent()
        print("dragdrop restored compact=\(layoutEngine.compactSlots.count) drawer=\(layoutEngine.drawerBlocks.count)")
    }

    func showPluginManager() {
        let controller = pluginManagerWindowController ?? {
            #if DEBUG
            let sizeLabAction: (() -> Void)? = { [weak self] in self?.showSizeLab() }
            #else
            let sizeLabAction: (() -> Void)? = nil
            #endif
            let controller = PluginManagerWindowController(
                pluginManager: pluginManager,
                onOpenSizeLab: sizeLabAction
            )
            pluginManagerWindowController = controller
            return controller
        }()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// 开发期调试：块尺寸对照实验室（同一组件在全部跨度档下的批量并排对比）。
    func showSizeLab() {
        SizeLabWindowController.shared.show(pluginManager: pluginManager, hostController: self)
    }
    #endif

}
