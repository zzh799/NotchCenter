import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（服务名 + 开关 + 点击开网页 + 长按浮窗）

/// CalibrePlugin 的抽屉块：1×1 / 2×1 两种跨度（决策 11）。
/// 外观（卡片壳/悬停/按压增亮）走 Kit 的 `BlockCard`，长按浮窗触发走
/// `blockPopoverTrigger`；本文件只保留数据 → 文案的映射与内容排布。
/// - 点击开关以外区域 → 打开网页（探测端口优先，回退硬编码 URL）
/// - 长按（0.2s）→ 弹出独立 NSPanel 浮窗（决策 6）
struct CalibreServiceBlockView: View {
    @StateObject private var monitor: CalibreServiceMonitor

    init() {
        _monitor = StateObject(wrappedValue: CalibreServiceMonitor())
    }

    var body: some View {
        BlockCard(hoverEffect: true) { _ in
            HStack(spacing: 8) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calibre")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { monitor.isServiceOn },
                    set: { _ in monitor.toggleRunning() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(monitor.isBusy)
            }
            .padding(.horizontal, 10)
        }
        // 手势顺序、长按抑制点击、开关自行消费点击等语义都在触发器内统一实现。
        .blockPopoverTrigger(
            onTap: { monitor.openWeb() },
            onLongPress: { frameInWindow in
                CalibrePopover.present(monitor: monitor, frameInWindow: frameInWindow)
            }
        )
        .animation(.easeOut(duration: 0.16), value: monitor.message)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
    }

    private var dotColor: Color {
        switch monitor.status.state {
        case .managed:
            return .green
        case .loadedNotRunning:
            return .yellow
        case .unmanagedExternal:
            return .orange
        case .portConflict:
            return .red
        case .stopped:
            return .gray
        }
    }

    private var subtitle: String {
        // busy 时直接把 Starting… / Stopping… 显示在状态位上，不单独占一行。
        if monitor.isBusy { return busyText }
        switch monitor.status.state {
        case .managed:
            // 端口探测缺失时用 em dash 占位，与浮窗行展示保持一致。
            return LF("calibre.subtitle.running", monitor.status.port.map(String.init) ?? "—")
        case .loadedNotRunning: return L("calibre.state.loadedNotRunning")
        case .unmanagedExternal: return L("calibre.subtitle.unmanaged")
        case .portConflict(let n): return LF("calibre.subtitle.portConflict", n)
        case .stopped: return L("calibre.state.stopped")
        }
    }

    private var busyText: String {
        monitor.isServiceOn ? L("calibre.action.stopping") : L("calibre.action.starting")
    }
}
