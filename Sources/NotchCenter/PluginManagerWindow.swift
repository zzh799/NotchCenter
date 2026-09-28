import AppKit
import NotchCenterKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 插件管理视图（文档 §8）

/// 插件管理视图：发现列表 + 启用开关 + 安装/卸载 + 说明文档展示（文档 §8.1 / §8.2 / 附录 A-29）。
/// 插件设置不在这里内嵌：统一走编辑模式齿轮触发的 SettingPopover 浮窗。
/// 宿主把它挂在设置窗口的「插件」页（`SettingsWindow.swift`），自己不开独立窗口。
struct PluginManagerView: View {
    /// 宿主控制器：移除摆放后要它重裁抽屉（`refreshAfterEdit`）——摆放数量变了
    /// 抽屉自然高度就变，只 `rebuildContent` 会留一截空白。
    let controller: NotchPanelController
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var layoutEngine: LayoutEngine

    @State private var selectedPluginID: String?
    @State private var errorMessage: String?
    /// Toggle 的影子值：停用要过二次确认，用户取消时不能指望"真值没变、SwiftUI
    /// 自己会把开关拨回去"——开关已经动过了，得显式回滚。
    @State private var enabledOverride: [String: Bool] = [:]

    init(controller: NotchPanelController) {
        self.controller = controller
        self.pluginManager = controller.pluginManager
        self.layoutEngine = controller.layoutEngine
    }

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
        // 一次算完传给每行：逐行读 `inUsePluginIDs` 会让列表做 N 次全量遍历。
        let inUse = layoutEngine.inUsePluginIDs
        return VStack(spacing: 0) {
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
                        pluginRow(entry, isInUse: inUse.contains(entry.id))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func pluginRow(_ entry: PluginEntry, isInUse: Bool) -> some View {
        let isSelected = selectedPluginID == entry.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.metadata.displayName)
                        .font(NotchTokens.Text.system(12, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.hover)
                        .lineLimit(1)

                    badge(entry.metadata.isBuiltIn ? L("manager.badge.builtIn") : L("manager.badge.user"), tint: NotchTokens.Foreground.unavailable)

                    if isInUse {
                        badge(L("manager.badge.inUse"), tint: NotchTokens.Semantic.accentGreen)
                    }

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
                get: { enabledOverride[entry.id] ?? entry.isEnabled },
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
        // 开关已经动过了：先记进影子值让这一帧显示与用户操作一致，随后无论
        // 成功、失败还是被取消都清掉——回到 `entry.isEnabled` 这个真值。
        enabledOverride[entry.id] = enabled
        defer { enabledOverride[entry.id] = nil }

        guard enabled || confirmDisable(entry) else { return }
        do {
            if enabled {
                try pluginManager.setEnabled(true, pluginID: entry.id)
            } else {
                // 停用即放弃它在布局里的全部摆放（确认弹窗已把代价说清）：
                // 留着会渲染成「插件已停用」占位，而插件列表里它已经是"没在用"。
                try controller.disablePlugin(pluginID: entry.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 停用前二次确认

    /// 组件名预览条数：全列会把弹窗撑成一堵墙，列几个足够让用户认出来。
    private static let namePreviewLimit = 3

    /// 该插件在布局里的全部摆放，附带"是否可用"（判据同 `LayoutEngine.isLivePlacement`）。
    private func placements(ofPluginID pluginID: String) -> [(blockID: String, isLive: Bool)] {
        layoutEngine.placements(ofPluginID: pluginID).map {
            (
                blockID: $0.blockID,
                isLive: layoutEngine.isLivePlacement(pluginID: pluginID, blockID: $0.blockID)
            )
        }
    }

    /// 组件显示名：块目录 → 快捷动作注册表（紧凑槽位里也可能是动作 id）→
    /// 回退 `blockID`（正常路径前两者必有一中，兜底只为不显示空白）。
    private func placementName(pluginID: String, blockID: String) -> String {
        if let name = pluginManager.block(pluginID: pluginID, blockID: blockID)?.displayName {
            return name
        }
        return pluginManager.quickActionStore.action(id: blockID)?.displayName ?? blockID
    }

    /// 停用前二次确认：只有该插件确有**正在使用**的摆放时才弹——确认后这些
    /// 摆放会被移除，用户必须看见代价。返回 true = 可以继续停用。
    ///
    /// 计数与文案分两句：正在使用的按 `placementAvailability` 的 live 口径数，
    /// 失效残骸单独一句（它们会被一并删掉，但说成"正在使用中"就是撒谎）。
    private func confirmDisable(_ entry: PluginEntry) -> Bool {
        let all = placements(ofPluginID: entry.id)
        let live = all.filter(\.isLive)
        guard !live.isEmpty else { return true }

        let names = live.map { placementName(pluginID: entry.id, blockID: $0.blockID) }
        let preview = names.prefix(Self.namePreviewLimit)
            .joined(separator: L("common.listSeparator"))
        let alert = NSAlert()
        alert.messageText = LF("manager.disable.confirmTitle", entry.metadata.displayName)
        alert.informativeText = names.count > Self.namePreviewLimit
            ? LF("manager.disable.confirmBodyTruncated", names.count, preview)
            : LF("manager.disable.confirmBody", names.count, preview)
        if all.count > live.count {
            alert.informativeText += "\n\n"
                + LF("manager.disable.confirmStale", all.count - live.count)
        }
        alert.alertStyle = .warning
        // 破坏性动作不做默认按钮（与卸载确认的按钮序刻意相反）：卸载删的是插件
        // 文件、可以从别处重装；这里删的是用户攒出来的摆放，没有备份也重建不出来。
        alert.addButton(withTitle: L("common.cancel"))
        alert.addButton(withTitle: L("manager.disable.confirmAction"))
        return HostAlert.runModal(alert) == .alertSecondButtonReturn
    }

    private func uninstall(_ entry: PluginEntry) {
        let alert = NSAlert()
        alert.messageText = LF("manager.uninstall.confirmTitle", entry.metadata.displayName)
        alert.informativeText = L("manager.uninstall.confirmBody")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("manager.uninstall"))
        alert.addButton(withTitle: L("common.cancel"))
        guard HostAlert.runModal(alert) == .alertFirstButtonReturn else { return }
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
        // 非模态 + 抬层级 + 长寿命持有者三条都由收口负责（见 `SystemFilePanelPresenter`）：
        // 本视图活在设置窗内，锚点域是 `.utility`——文件面板默认层级 0，不抬会被设置窗压住。
        SystemFilePanelPresenter.shared.present(panel, anchor: .utility) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let entry = try pluginManager.installBundle(from: url)
                selectedPluginID = entry.id
            } catch {
                errorMessage = error.localizedDescription
            }
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
    #if DEBUG
    /// 开发期调试：块尺寸对照实验室（同一组件在全部跨度档下的批量并排对比）。
    func showSizeLab() {
        SizeLabWindowController.shared.show(pluginManager: pluginManager, hostController: self)
    }
    #endif
}
