import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 权限管理弹窗（独立 NSPanel）
//
// 形态选择见 Agent Note 2026-09-11-permission-management-panel：**不复用**
// `BlockPopover`——它的 `present(anchoredTo:)` 必须锚定一个抽屉块在宿主窗口
// 坐标系里的 frame，而权限弹窗的两个入口（设置窗口的「权限管理」行、插件运行时
// 的自动弹出）都未必有锚定块、抽屉也未必在屏。硬套会弹到错误位置甚至不弹。
// 因此用独立 borderless NSPanel，视觉仍走 `NotchTokens` 保证与既有浮层同观感。

/// 权限管理弹窗的窗口控制器（进程内单例：任一时刻至多一扇）。
@MainActor
final class PermissionGuidePanel: NSObject, NSWindowDelegate {
    static let shared = PermissionGuidePanel()

    /// 卡片尺寸：7 行权限（每行 44pt，见 `SystemPermission.allCases`）+ 标题栏 + 底部说明。
    /// 行容器是可滚动的，所以尺寸偏小只会让末行需要滚一下；偏大则留白，两处都不致命——
    /// 但新增权限项时仍应同步抬高，保持"一屏列全、页脚不被挤走"的原始口径。
    static let cardSize = CGSize(width: 420, height: 514)

    private var panel: NSPanel?
    /// 点击窗外 / ESC 关闭。
    private var dismissMonitor: Any?
    /// App 重新激活时重取状态：用户去系统设置勾完权限切回来，弹窗要立刻反映。
    private var activationObserver: NSObjectProtocol?

    private override init() {
        super.init()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // 授权状态是系统侧事实，切回前台时重挂一次根视图即可拿到新值。
                self.refreshContent()
            }
        }
    }

    // MARK: 展示 / 收起

    func present(focus: [SystemPermission]) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.cardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        panel.contentView = NSHostingView(
            rootView: PermissionGuideCard(focus: focus) { [weak self] in
                self?.dismiss()
            }
        )
        // 水平居中、垂直略偏上（贴屏幕上方更符合"从刘海里弹出来"的观感）。
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: visible.midX - Self.cardSize.width / 2,
                    y: visible.maxY - Self.cardSize.height - 80
                )
            )
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        installDismissMonitor()
    }

    func dismiss() {
        removeDismissMonitor()
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
    }

    private func refreshContent() {
        guard let panel, let hosting = panel.contentView as? NSHostingView<PermissionGuideCard> else { return }
        // 重新赋值 rootView 强制重算权限状态（状态查询无副作用，安全）。
        hosting.rootView = PermissionGuideCard(focus: hosting.rootView.focus) { [weak self] in
            self?.dismiss()
        }
    }

    // MARK: 窗外点击 / ESC

    private func installDismissMonitor() {
        dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.type == .keyDown {
                // ESC(53) 关闭；其余按键交给面板内的控件。
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                return event
            }
            // 点击落在弹窗之外 → 关闭；点击弹窗内照常分发。用 event.window
            // 判断比逐点做命中测试可靠（弹窗是 borderless，contentView 即卡片）。
            if event.window !== self.panel {
                self.dismiss()
            }
            return event
        }
    }

    private func removeDismissMonitor() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
        }
        dismissMonitor = nil
    }
}

// MARK: - 卡片视图

/// 权限管理卡片：标题行 + 逐条权限行 + 底部说明。
///
/// `focus` 中的权限排在最前并高亮，其余仍然全列——用户进来一次就能顺手补齐
/// 其它权限，不必为了另一项再点一遍入口。
private struct PermissionGuideCard: View {
    let focus: [SystemPermission]
    let onClose: () -> Void

    /// 状态快照。刻意在 `body` 求值时重取（宿主在 App 重新激活时会重建本视图），
    /// 这样用户从系统设置勾完权限切回来就能立刻看到变化。
    private var rows: [(permission: SystemPermission, status: PermissionStatus, focused: Bool)] {
        let statuses = SystemPermission.allCases.map {
            (permission: $0, status: PermissionCenter.shared.status(of: $0), focused: focus.contains($0))
        }
        // 焦点项在前，其余保持清单顺序（stable partition）。
        return statuses.filter(\.focused) + statuses.filter { !$0.focused }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(NotchTokens.Hairline.divider)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(rows, id: \.permission) { row in
                        PermissionRowView(
                            permission: row.permission,
                            status: row.status,
                            focused: row.focused
                        )
                    }
                }
                .padding(14)
            }

            Text(L("permission.footer"))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: PermissionGuidePanel.cardSize.width, height: PermissionGuidePanel.cardSize.height)
        .background {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous)
                .fill(NotchTokens.Surface.drawer)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous)
                .strokeBorder(NotchTokens.Hairline.drawerEdge, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(NotchTokens.Text.system(13, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(L("permission.title"))
                .font(NotchTokens.Text.system(13, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.body)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(NotchTokens.Text.system(11, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
            .buttonStyle(.plain)
            .help(L("permission.close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 单条权限行

/// 一行权限：图标 + 名称 + 一句话用途 + 状态徽标 + 「Open Settings」跳转按钮。
private struct PermissionRowView: View {
    let permission: SystemPermission
    let status: PermissionStatus
    let focused: Bool

    @State private var isRequesting = false
    @State private var requestNote: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.symbolName)
                .font(NotchTokens.Text.system(14))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(NotchTokens.Text.system(12, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.body)
                    statusBadge
                }
                Text(purpose)
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if permission.requiresRelaunch, status == .authorized {
                    Text(L("permission.relaunchHint"))
                        .font(NotchTokens.Text.system(10))
                        .foregroundStyle(NotchTokens.Semantic.unavailable)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let requestNote {
                    Text(requestNote)
                        .font(NotchTokens.Text.system(10))
                        .foregroundStyle(NotchTokens.Semantic.unavailable)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                Button(action: openSettings) {
                    Text(L("permission.openSettings"))
                        .font(NotchTokens.Text.system(10, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.body)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                        .fill(NotchTokens.Surface.fillHighlighted)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                        .strokeBorder(NotchTokens.Hairline.drawerEdge, lineWidth: 1)
                }
                .help(L("permission.openSettings.help"))

                // 只有"还没问过"才有意义弹系统授权窗；已拒绝/受限时系统不再弹窗，
                // 按钮退场，避免用户点了没反应。
                if status.canRequest {
                    Button(action: request) {
                        Text(isRequesting ? L("permission.requesting") : L("permission.request"))
                            .font(NotchTokens.Text.system(10, weight: .semibold))
                            .foregroundStyle(NotchTokens.Foreground.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRequesting)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(focused ? NotchTokens.Surface.fillHighlighted : NotchTokens.Surface.fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .strokeBorder(
                    focused ? NotchTokens.Hairline.chipSelected : NotchTokens.Hairline.divider,
                    lineWidth: 1
                )
        }
    }

    // MARK: 呈现

    private var name: String { L("permission.name.\(permission.rawValue)") }

    private var purpose: String { L("permission.purpose.\(permission.rawValue)") }

    private var iconColor: Color {
        switch status {
        case .authorized: return NotchTokens.Semantic.accentGreen
        case .denied, .restricted: return NotchTokens.Semantic.unavailable
        case .notDetermined: return NotchTokens.Foreground.disabled
        }
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(NotchTokens.Text.system(9, weight: .semibold))
            .foregroundStyle(iconColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                    .fill(NotchTokens.Surface.track)
            }
    }

    private var statusLabel: String {
        switch status {
        case .authorized: return L("permission.status.authorized")
        case .denied: return L("permission.status.denied")
        case .restricted: return L("permission.status.restricted")
        case .notDetermined: return L("permission.status.notDetermined")
        }
    }

    // MARK: 动作

    /// 跳转按钮：URL 由 Kit 的纯函数构造（可单测），这里只负责打开。
    private func openSettings() {
        NSWorkspace.shared.open(SystemSettingsURL.url(for: permission))
    }

    private func request() {
        isRequesting = true
        requestNote = nil
        Task {
            let outcome = await PermissionCenter.shared.request(permission)
            isRequesting = false
            switch outcome {
            case .authorized:
                requestNote = nil
            case .denied, .restricted:
                // 请求被拒 → 明确告诉用户下一步是去系统设置，而不是"再点一次"。
                requestNote = L("permission.request.deniedHint")
            case let .failed(reason):
                requestNote = reason
            }
        }
    }
}
