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
                .font(NotchTokens.Text.system(13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))

            row(L("dsh.label.status"), text: statusText, warning: isWarning)
            row("PID", text: monitor.status.pid.map(String.init) ?? "—", warning: false)
            row("Port", text: monitor.status.port.map(String.init) ?? "—", warning: false)

            Divider()
                .overlay(Color.white.opacity(0.045))

            HStack {
                Text(L("dsh.launchAtLogin"))
                    .font(NotchTokens.Text.system(11))
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

            // 重启与「打开网页」并排一行：网页入口从块的点击动作移入浮窗，
            // 两个动作等宽，浮窗高度不变。
            HStack(spacing: 8) {
                actionButton(L("dsh.restart"), systemImage: "arrow.clockwise", disabled: monitor.isBusy) {
                    monitor.restart()
                }
                // 打开网页不改系统状态，busy 期间仍可用（探测端口优先，回退硬编码 URL）。
                actionButton(L("dsh.openWeb"), systemImage: "safari") {
                    monitor.openWeb()
                }
            }

            if let message = monitor.message {
                Text(message)
                    .font(NotchTokens.Text.system(9))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(2)
            }
        }
        .padding(14)
    }

    /// 浮窗底部动作按钮：白底 0.055 + 发丝圆角，与项目按钮观感一致。
    private func actionButton(
        _ title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var statusText: String {
        switch monitor.status.state {
        case .managed: return L("dsh.state.managed")
        case .starting: return L("dsh.state.starting")
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
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(Color.white.opacity(0.58))
            Spacer()
            Text(text)
                .font(NotchTokens.Text.system(11, weight: .regular, design: .monospaced))
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
