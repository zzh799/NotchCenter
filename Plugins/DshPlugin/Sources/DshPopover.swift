import NotchCenterKit
import SwiftUI

// MARK: - 长按浮窗（生命周期与表现统一走 Kit 的 BlockPopover）

/// 浮窗内容：自启开关 + PID + 端口 + 状态文字（含冲突警告）+ 重启按钮（决策 9）。
/// 背景卡片、描边、弹出动画由 BlockPopover 统一提供，这里只排布内容。
struct DshPopoverContentView: View {
    @ObservedObject var monitor: DshServiceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DSH Web")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))

            row(L("dsh.label.status"), text: statusText, warning: isWarning)
            row("PID", text: monitor.status.pid.map(String.init) ?? "—", warning: false)
            row("Port", text: monitor.status.port.map(String.init) ?? "—", warning: false)

            Divider()
                .overlay(Color.white.opacity(0.045))

            HStack {
                Text(L("dsh.launchAtLogin"))
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
                Label(L("dsh.restart"), systemImage: "arrow.clockwise")
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
    }

    private var statusText: String {
        switch monitor.status.state {
        case .managed: return L("dsh.state.managed")
        case .loadedNotRunning: return L("dsh.state.loadedNotRunning")
        case .unmanagedExternal: return L("dsh.state.unmanagedExternal")
        case .portConflict(let n): return LF("dsh.conflict.popover", n)
        case .stopped: return L("dsh.state.stopped")
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

// MARK: 浮窗入口（无状态薄门面：单例互斥、窗口配置与弹出动画都在 Kit）

@MainActor
enum DshPopover {
    static let cardSize = CGSize(width: 220, height: 190)

    static func present(monitor: DshServiceMonitor, frameInWindow: CGRect) {
        BlockPopover.shared.present(anchoredTo: frameInWindow, cardSize: cardSize) {
            DshPopoverContentView(monitor: monitor)
        }
    }

    static func dismiss() {
        BlockPopover.shared.dismiss()
    }
}
