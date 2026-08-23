import AppKit
import SwiftUI

// MARK: - 长按浮窗（独立 NSPanel，决策 6）

/// 浮窗内容：自启开关 + PID + 端口 + 状态文字（含冲突警告）+ 重启按钮（决策 9）。
struct DshPopoverContentView: View {
    @ObservedObject var monitor: DshServiceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DSH Web")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))

            row("Status", text: statusText, warning: isWarning)
            row("PID", text: monitor.status.pid.map(String.init) ?? "—", warning: false)
            row("Port", text: monitor.status.port.map(String.init) ?? "—", warning: false)

            Divider()
                .overlay(Color.white.opacity(0.045))

            HStack {
                Text("Launch at Login")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.76))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { monitor.autostartOn },
                    set: { monitor.setAutostart($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(monitor.isBusy)
            }

            Button {
                monitor.restart()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                    )
            }
            .buttonStyle(.plain)
            .disabled(monitor.isBusy)

            if let message = monitor.message {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 220, height: 190)
        // 近黑半透明 + 发丝描边（DESIGN.md §2.1 / §2.3），与抽屉同质感。
        .background(
            Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    private var statusText: String {
        switch monitor.status.state {
        case .managed: return "Managed by launchd"
        case .loadedNotRunning: return "Loaded, not running"
        case .unmanagedExternal: return "Unmanaged process listening"
        case .portConflict(let n): return "\(n) instances conflict"
        case .stopped: return "Stopped"
        }
    }

    private var isWarning: Bool {
        switch monitor.status.state {
        case .unmanagedExternal, .portConflict: return true
        default: return false
        }
    }

    private func row(_ title: String, text: String, warning: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.58))
            Spacer()
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(warning ? Color.orange : Color.white.opacity(0.92))
        }
    }
}

/// 浮窗窗口控制器：单例持有 NSPanel，锚定块附近弹出，点击外部自动关闭。
@MainActor
final class DshPopoverController {
    static let shared = DshPopoverController()

    /// 浮窗内容固定尺寸（避免 NSHostingView 刚创建时 fittingSize 未布局为 0）。
    private static let popoverSize = CGSize(width: 220, height: 190)

    private var panel: NSPanel?
    /// 点击外部关闭：本地鼠标监听。
    private var eventMonitor: Any?

    private init() {}

    /// 在块附近弹出浮窗。`frameInWindow` 为块在宿主窗口坐标系中的 frame
    /// （SwiftUI .global 空间），经宿主窗口 convertToScreen 转为屏幕坐标。
    func present(monitor: DshServiceMonitor, frameInWindow blockFrame: CGRect) {
        dismiss()

        // 块视图挂在某个 NotchPanel 的 hosting 树里：取包含当前鼠标位置的
        // 可见窗口作为宿主（长按发生时光标就在块上）。
        let mouse = NSEvent.mouseLocation
        guard let hostWindow = NSApp.windows.first(where: { window in
            window.isVisible && window.frame.contains(mouse)
        }) else { return }
        // SwiftUI .global 是左上原点、y 向下；convertToScreen 要 AppKit
        // 窗口坐标（左下原点、y 向上）。先做 y 翻转再转换，否则浮窗会被
        // 镜像到屏幕底部。
        let flipped = CGRect(
            x: blockFrame.minX,
            y: hostWindow.frame.height - blockFrame.maxY,
            width: blockFrame.width,
            height: blockFrame.height
        )
        let screenFrame = hostWindow.convertToScreen(flipped)

        let content = NSHostingView(
            rootView: DshPopoverContentView(monitor: monitor)
                .frame(width: Self.popoverSize.width, height: Self.popoverSize.height)
        )

        let origin = anchorPoint(for: screenFrame, size: Self.popoverSize)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: Self.popoverSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar + 2
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = content
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.orderFrontRegardless()
        self.panel = panel

        // 点击浮窗以外区域关闭。
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel {
                self.dismiss()
            }
            return event
        }
    }

    func dismiss() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    /// 锚定在块的下方居中；越界时向上翻转。坐标为屏幕坐标系（y 自底向上）。
    private func anchorPoint(for blockFrame: CGRect, size: CGSize) -> CGPoint {
        let x = blockFrame.midX - size.width / 2
        var y = blockFrame.minY - size.height - 8
        if y < 0 { y = blockFrame.maxY + 8 }
        return CGPoint(x: x, y: y)
    }
}
