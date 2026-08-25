import SwiftUI

// MARK: - 设置面板（文档 §6.1 / §4.8）
/// 承接原状态栏菜单中的核心设置项：触发模式、抽屉列数、插件管理入口。

@MainActor
final class SettingsWindowController: NSWindowController {
    private let panelController: NotchPanelController

    init(panelController: NotchPanelController) {
        self.panelController = panelController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("settings.window.title")
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
            Section(L("settings.section.interaction")) {
                Picker(L("settings.triggerMode"), selection: $settingsStore.triggerMode) {
                    ForEach(SettingsStore.TriggerMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            Section(L("settings.section.layout")) {
                Picker(L("settings.columns"), selection: columnBinding) {
                    ForEach(2...8, id: \.self) { columns in
                        Text(LF("settings.column.count", columns)).tag(columns)
                    }
                }
            }

            Section(L("settings.section.general")) {
                Toggle(isOn: launchAtLoginBinding) {
                    Text(L("settings.launchAtLogin"))
                }
                if let hint = launchAtLoginHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("settings.section.plugins")) {
                Button(L("settings.pluginManager")) {
                    controller.showPluginManager()
                }
            }

            // 语言覆盖写入 AppleLanguages，须重启才能让已加载的 bundle 重新选 lproj。
            Section(L("settings.language")) {
                Picker(L("settings.language"), selection: $settingsStore.languageOverride) {
                    Text(L("language.system")).tag(SettingsStore.LanguageOverride.system)
                    Text("简体中文").tag(SettingsStore.LanguageOverride.simplifiedChinese)
                    Text("English").tag(SettingsStore.LanguageOverride.english)
                }
                if settingsStore.languageOverride != .system {
                    Text(L("language.restartHint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(L("settings.quit"), role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 480)
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

    // MARK: 开机自启（SMAppService）

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                    launchAtLoginError = nil
                } catch {
                    // 注册失败后回读真实状态，避免开关与系统不一致。
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                    launchAtLoginError = error.localizedDescription
                }
            }
        )
    }

    /// 开发态裸二进制无法注册登录项；或注册出错时给出提示。
    private var launchAtLoginHint: String? {
        if let launchAtLoginError {
            return LF("settings.launchAtLogin.error", launchAtLoginError)
        }
        if Bundle.main.bundleURL.pathExtension != "app" {
            return L("settings.launchAtLogin.devHint")
        }
        return nil
    }
}
