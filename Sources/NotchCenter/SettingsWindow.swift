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
    /// 插件清单（设置面板直接展示各插件的说明文档，随扫描结果刷新）。
    @ObservedObject private var pluginManager: PluginManager

    init(controller: NotchPanelController) {
        self.controller = controller
        self.settingsStore = controller.settingsStore
        self.layoutEngine = controller.layoutEngine
        self.pluginManager = controller.pluginManager
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

                // 每个插件的说明文档：展开时读取插件 bundle 内的 README.md
                // （build.sh 组装 bundle 时从插件源文件夹复制）。
                ForEach(pluginManager.entries) { entry in
                    PluginDocumentationDisclosure(entry: entry)
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

/// 单个插件的说明文档折叠区：标签为插件显示名 + ID；展开时懒加载并渲染
/// 插件 bundle 内的 README.md（经 ReadmeMarkdownView 轻量渲染）。
/// （internal 便于 ReadmeMarkdownTests 覆盖 loadReadme。）
struct PluginDocumentationDisclosure: View {
    @ObservedObject var entry: PluginEntry
    @State private var isExpanded = false
    @State private var document: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if let document, !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReadmeMarkdownView(markdown: document)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L("settings.plugins.noReadme"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.top, 2)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.metadata.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Text(entry.metadata.pluginID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.vertical, 1)
        }
        .onChange(of: isExpanded) { _, expanded in
            // 首次展开才读文件：设置面板打开时不做整表 IO。
            guard expanded, document == nil else { return }
            document = Self.loadReadme(bundleURL: entry.metadata.bundleURL)
        }
    }

    /// 读插件 bundle 内 Contents/Resources/README.md（build.sh 打包时复制；
    /// 第三方插件可能没有附带，缺文件/编码异常一律返回 nil 走占位文案）。
    /// 纯文件 IO 与 UI 无关：nonisolated 便于在任意上下文（含测试）调用。
    nonisolated static func loadReadme(bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL),
              let url = bundle.url(forResource: "README", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
