import SwiftUI

// MARK: - 设置面板（文档 §6.1 / §4.8）
/// 承接原状态栏菜单中的核心设置项：触发模式、抽屉列数、插件管理入口。

@MainActor
final class SettingsWindowController: NSWindowController {
    private let panelController: NotchPanelController

    init(panelController: NotchPanelController) {
        self.panelController = panelController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchCenter Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: SettingsView(controller: panelController)
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    let controller: NotchPanelController
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var layoutEngine: LayoutEngine

    init(controller: NotchPanelController) {
        self.controller = controller
        self.settingsStore = controller.settingsStore
        self.layoutEngine = controller.layoutEngine
    }

    var body: some View {
        Form {
            Section("Interaction") {
                Picker("Trigger Mode", selection: $settingsStore.triggerMode) {
                    ForEach(SettingsStore.TriggerMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Layout") {
                Picker("Drawer Columns", selection: columnBinding) {
                    ForEach(2...8, id: \.self) { columns in
                        Text("\(columns) Columns").tag(columns)
                    }
                }
            }

            Section("Plugins") {
                Button("Plugin Manager…") {
                    controller.showPluginManager()
                }
            }

            Section {
                Button("Quit NotchCenter", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 260)
        .environment(\.colorScheme, .dark)
    }

    private var columnBinding: Binding<Int> {
        Binding(
            get: { layoutEngine.userMaxColumns },
            set: { newValue in
                layoutEngine.setUserMaxColumns(newValue)
                controller.refreshAfterLayoutChange()
            }
        )
    }
}
