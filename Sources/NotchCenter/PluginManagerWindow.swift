import AppKit
import NotchCenterKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 插件管理窗口（文档 §8）

@MainActor
final class PluginManagerWindowController: NSWindowController {
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager

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
            rootView: PluginManagerView(pluginManager: pluginManager)
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 插件管理视图：发现列表 + 启用开关 + 安装/卸载 + 说明文档展示（文档 §8.1 / §8.2 / 附录 A-29）。
/// 插件设置不在这里内嵌：统一走编辑模式齿轮触发的 SettingPopover 浮窗。
struct PluginManagerView: View {
    @ObservedObject var pluginManager: PluginManager

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
        .background(NotchTokens.Surface.windowPane)
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
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                Spacer()
                Button(action: installBundle) {
                    Image(systemName: "plus")
                        .font(NotchTokens.Text.system(11, weight: .bold))
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
                        .font(NotchTokens.Text.system(12, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.hover)
                        .lineLimit(1)

                    badge(entry.metadata.isBuiltIn ? L("manager.badge.builtIn") : L("manager.badge.user"), tint: NotchTokens.Foreground.unavailable)

                    if !entry.metadata.isAPICompatible {
                        badge(L("manager.badge.incompatible"), tint: .red.opacity(0.9))
                    }
                }

                Text(entry.metadata.pluginID)
                    .font(NotchTokens.Text.system(10, design: .monospaced))
                    .foregroundStyle(NotchTokens.Foreground.disabled)
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
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(isSelected ? NotchTokens.Surface.track : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPluginID = entry.id
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(NotchTokens.Text.system(8, weight: .semibold))
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
                            .font(NotchTokens.Text.system(16, weight: .bold))
                            .foregroundStyle(NotchTokens.Foreground.body)
                        Text(entry.metadata.pluginID)
                            .font(NotchTokens.Text.system(11, design: .monospaced))
                            .foregroundStyle(NotchTokens.Foreground.disabled)
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
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.disabled)

                if let description = entry.metadata.pluginDescription, !description.isEmpty {
                    Text(description)
                        .font(NotchTokens.Text.system(11))
                        .foregroundStyle(NotchTokens.Foreground.muted)
                }

                Divider().overlay(NotchTokens.Hairline.divider)

                if entry.loadError != nil {
                    Text(LF("manager.loadFailed", entry.loadError ?? ""))
                        .font(NotchTokens.Text.system(11))
                        .foregroundStyle(.red.opacity(0.9))
                } else {
                    // 原插件设置嵌入的位置改为展示说明文档（插件 bundle 内 README.md）。
                    PluginReadmeSection(entry: entry)
                }

                Spacer()
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(NotchTokens.Text.system(26))
                    .foregroundStyle(NotchTokens.Foreground.placeholder)
                Text(L("manager.selectHint"))
                    .font(NotchTokens.Text.system(12))
                    .foregroundStyle(NotchTokens.Foreground.placeholder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedEntry: PluginEntry? {
        guard let selectedPluginID else { return nil }
        return pluginManager.entry(for: selectedPluginID)
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

/// 详情区插件说明文档：读取并渲染插件 bundle 内的 README.md
/// （原设置面板分区展示移入此处，占据原插件设置嵌入的位置；
/// 设置入口统一走编辑模式齿轮触发的 SettingPopover 浮窗）。
struct PluginReadmeSection: View {
    @ObservedObject var entry: PluginEntry
    @State private var document: String?

    var body: some View {
        ScrollView {
            Group {
                if let document, !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReadmeMarkdownView(markdown: document)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L("manager.noReadme"))
                        .font(NotchTokens.Text.system(11))
                        .foregroundStyle(NotchTokens.Foreground.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: entry.id) {
            // 选中即读；先清空再赋值在同一主线程回合内完成，不渲染中间态。
            document = nil
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

extension NotchPanelController {
    /// 打开插件管理窗口（懒加载，缓存实例）。
    func showPluginManager() {
        let controller = pluginManagerWindowController ?? {
            let controller = PluginManagerWindowController(pluginManager: pluginManager)
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
