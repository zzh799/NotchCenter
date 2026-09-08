import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（服务名 + 开关 + 点击启停 + 长按浮窗）
//
// 外观与交互统一在 Kit 的 `ServiceBlockView`（原 Calibre/Dsh 各持一份 1:1
// 复制，2026-09-08 上提）；本文件只保留监视器绑定、状态 → 文案/指示灯的
// 映射（L10n 在插件内）与浮窗入口。

/// DshPlugin 的抽屉块：1×1 / 2×1 两种跨度（决策 11）。
struct DshServiceBlockView: View {
    /// 绑定插件级共享监视器（`DshServiceMonitor.shared`）：块视图每次展开都会
    /// 被宿主重建（收起时身份销毁），监视器必须活过视图生命周期，开关才能以
    /// 当前真实状态起渲染，而不是每次都从“关”起步重播打开动画。
    @ObservedObject private var monitor = DshServiceMonitor.shared

    var body: some View {
        ServiceBlockView(
            name: "DSH Web",
            iconSystemName: "server.rack",
            helpText: L("dsh.block.help"),
            isOn: monitor.isServiceOn,
            isBusy: monitor.isBusy,
            statusText: statusText,
            portText: portText,
            dotColor: dotColor,
            // 点击即启停（busy 期间 toggleRunning 自行忽略），打开网页由浮窗承担。
            onTap: { monitor.toggleRunning() },
            onLongPress: { frameInWindow in
                DshPopover.present(monitor: monitor, frameInWindow: frameInWindow)
            },
            refresh: { await monitor.refreshOnce() }
        )
    }

    private var dotColor: Color {
        switch monitor.status.state {
        case .managed:
            return .green
        case .starting, .loadedNotRunning:
            return .yellow
        case .unmanagedExternal:
            return .orange
        case .portConflict:
            return .red
        case .stopped:
            return .gray
        }
    }

    private var statusText: String {
        // busy 时直接把 Starting… / Stopping… 显示在状态位上，不单独占一行。
        if monitor.isBusy { return busyText }
        switch monitor.status.state {
        case .managed: return L("dsh.state.running")
        case .starting: return L("dsh.state.starting")
        case .loadedNotRunning: return L("dsh.state.loadedNotRunning")
        case .unmanagedExternal: return L("dsh.state.unmanagedShort")
        case .portConflict(let n): return LF("dsh.conflict.block", n)
        case .stopped: return L("dsh.state.stopped")
        }
    }

    /// 端口仅在「运行中（managed）」且探测到端口时展示，单独成行，与状态位分离。
    private var portText: String? {
        guard case .managed = monitor.status.state,
              let port = monitor.status.port else { return nil }
        return LF("dsh.subtitle.port", String(port))
    }

    private var busyText: String {
        monitor.isServiceOn ? L("dsh.action.stopping") : L("dsh.action.starting")
    }
}
