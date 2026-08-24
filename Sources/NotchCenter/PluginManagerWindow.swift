import AppKit
import NotchCenterKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 插件管理窗口（文档 §8）

@MainActor
final class PluginManagerWindowController: NSWindowController {
    private let pluginManager: PluginManager
    private let hostController: any HostController

    init(pluginManager: PluginManager, hostController: any HostController) {
        self.pluginManager = pluginManager
        self.hostController = hostController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("manager.window.title")
        window.minSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: PluginManagerView(
                pluginManager: pluginManager,
                hostController: hostController
            )
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 插件管理视图：发现列表 + 启用开关 + 安装/卸载 + 设置嵌入（文档 §8.1 / §8.2 / 附录 A-29）。
struct PluginManagerView: View {
    @ObservedObject var pluginManager: PluginManager
    let hostController: any HostController

    @State private var selectedPluginID: String?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            pluginList
                .frame(width: 320)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .alert(
            L("manager.alert.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L("common.ok")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 列表

    private var pluginList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("manager.header.plugins"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button(action: installBundle) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .help(L("manager.install.help"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(pluginManager.entries) { entry in
                        pluginRow(entry)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func pluginRow(_ entry: PluginEntry) -> some View {
        let isSelected = selectedPluginID == entry.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.metadata.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)

                    badge(entry.metadata.isBuiltIn ? L("manager.badge.builtIn") : L("manager.badge.user"), tint: .white.opacity(0.35))

                    if !entry.metadata.isAPICompatible {
                        badge(L("manager.badge.incompatible"), tint: .red.opacity(0.9))
                    }
                }

                Text(entry.metadata.pluginID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { newValue in toggleEnabled(newValue, for: entry) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? .white.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPluginID = entry.id
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.14))
            )
            .foregroundStyle(tint)
    }

    // MARK: 详情

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.metadata.displayName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(entry.metadata.pluginID)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    if !entry.metadata.isBuiltIn {
                        Button(L("manager.uninstall")) {
                            uninstall(entry)
                        }
                        .controlSize(.small)
                    }
                }

                Text(LF("manager.version.api", entry.metadata.pluginVersion, entry.metadata.apiVersion))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))

                if let description = entry.metadata.pluginDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Divider().overlay(.white.opacity(0.1))

                if let settingsView = pluginEntrySettings(entry) {
                    ScrollView {
                        settingsView
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if entry.loadError != nil {
                    Text(LF("manager.loadFailed", entry.loadError ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.9))
                } else {
                    Text(L("manager.noSettings"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.25))
                Text(L("manager.selectHint"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedEntry: PluginEntry? {
        guard let selectedPluginID else { return nil }
        return pluginManager.entry(for: selectedPluginID)
    }

    private func pluginEntrySettings(_ entry: PluginEntry) -> AnyView? {
        guard let instance = entry.instance,
              let settingsView = instance.settingsView,
              let stateStore = entry.stateStore else {
            return nil
        }
        let context = PluginSettingsContext(
            pluginID: entry.id,
            stateStore: stateStore,
            hostController: hostController
        )
        return settingsView(context)
    }

    // MARK: 操作

    private func toggleEnabled(_ enabled: Bool, for entry: PluginEntry) {
        do {
            try pluginManager.setEnabled(enabled, pluginID: entry.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uninstall(_ entry: PluginEntry) {
        let alert = NSAlert()
        alert.messageText = LF("manager.uninstall.confirmTitle", entry.metadata.displayName)
        alert.informativeText = L("manager.uninstall.confirmBody")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("manager.uninstall"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try pluginManager.uninstall(pluginID: entry.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installBundle() {
        let panel = NSOpenPanel()
        panel.title = L("manager.openPanel.title")
        panel.message = L("manager.openPanel.message")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.bundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let entry = try pluginManager.installBundle(from: url)
            selectedPluginID = entry.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}