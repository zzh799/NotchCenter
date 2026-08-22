import AppKit

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
        print("debug compact: layout.compact=\(layout.compactSize) notch=\(layout.notchSize)")
    }

    func showPluginManager() {
        let controller = pluginManagerWindowController ?? {
            let controller = PluginManagerWindowController(
                pluginManager: pluginManager,
                hostController: self
            )
            pluginManagerWindowController = controller
            return controller
        }()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
