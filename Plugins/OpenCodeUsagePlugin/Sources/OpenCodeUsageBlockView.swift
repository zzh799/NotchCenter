import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图：同心环用量图 + Zen 余额（对应参考实现的环形按钮 + 面板）
//
// 外/中/内三环分别是 5h 滚动 / 每周 / 每月窗口；点击打开 dashboard，
// 右上角小按钮手动刷新。medium 跨度额外显示余额与图例，small 只留环。
// 卡片壳与长按浮窗触发统一走 Kit 的 BlockCard / blockPopoverTrigger。

struct OpenCodeUsageBlockView: View {
    @ObservedObject private var store = OpenCodeUsageStore.shared

    var body: some View {
        BlockCard(hoverEffect: true) { isHovering in
            content
                .overlay(alignment: .topTrailing) {
                    refreshButton(hovering: isHovering)
                }
        }
        // 手势顺序、长按抑制点击等语义都在触发器内统一实现。
        .blockPopoverTrigger(
            onTap: { _ in openDashboard() },
            onLongPress: { frameInWindow in
                OpenCodeUsagePopover.present(store: store, frameInWindow: frameInWindow)
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if !store.isConfigured {
            placeholder
        } else if let snapshot = store.snapshot {
            usageContent(snapshot)
        } else if store.isLoading {
            VStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(L("usage.loading"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            errorView
        }
    }

    // MARK: 正常数据

    /// 重置信息只在长按浮窗里展示，主 UI 保持紧凑（环 + 余额 + 图例）。
    private func usageContent(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 12) {
            UsageRingsView(windows: snapshot.windows, outerDiameter: 56)
                .frame(width: 60)

            VStack(alignment: .leading, spacing: 3) {
                if let balance = snapshot.zen?.balance {
                    Text(balance, format: .currency(code: "USD"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(L("usage.zenBalance"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                legend(for: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
    }

    /// 图例："5h 42% · Week 13% · Month 3%"。
    private func legend(for snapshot: UsageSnapshot) -> some View {
        let parts = [UsageWindowKind.rolling, .weekly, .monthly].compactMap { kind -> String? in
            guard let window = snapshot.windows[kind] else { return nil }
            return "\(kind.shortLabel) \(window.percent)%"
        }
        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: 未配置 / 出错

    private var placeholder: some View {
        VStack(spacing: 5) {
            Image(systemName: "gauge")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.38))
            Text(L("usage.notConfigured"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }

    private var errorView: some View {
        VStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.72))
            Text(store.errorMessage ?? L("usage.unavailable"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }

    // MARK: 刷新按钮

    private func refreshButton(hovering: Bool) -> some View {
        Button {
            store.forceRefresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 0.88 : 0.55))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isLoading || !store.isConfigured)
        .opacity((store.isLoading || !store.isConfigured) ? 0.35 : 1)
        .help(L("usage.refreshHelp"))
    }

    // MARK: 动作

    private func openDashboard() {
        guard store.isConfigured,
              let baseURL = OpenCodeUsageConfigLogic.effectiveBaseURL(store.config),
              let workspaceID = store.config.workspaceID,
              let url = URL(string: baseURL.absoluteString + "/workspace/\(workspaceID)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// 秒数 → 紧凑时长文案（"1h 23m" / "45m" / "2d"）。
    static func formatReset(seconds: Int) -> String {
        guard seconds > 0 else { return "soon" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }
}

// MARK: - 同心环

/// 三环同心用量图：外环 rolling、中环 weekly、内环 monthly；缺失的窗口不画。
struct UsageRingsView: View {
    let windows: [UsageWindowKind: UsageWindow]
    var outerDiameter: CGFloat

    private struct RingSpec {
        let kind: UsageWindowKind
        let scale: CGFloat
        let lineWidth: CGFloat
    }

    private var specs: [(UsageWindowKind, CGFloat, CGFloat)] {
        [
            (.rolling, 1.0, 4.5),
            (.weekly, 0.72, 3.5),
            (.monthly, 0.46, 3),
        ]
    }

    var body: some View {
        ZStack {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                ring(
                    window: windows[spec.0],
                    diameter: outerDiameter * spec.1,
                    lineWidth: spec.2
                )
            }
        }
        .frame(width: outerDiameter, height: outerDiameter)
    }

    @ViewBuilder
    private func ring(window: UsageWindow?, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            if let window {
                Circle()
                    .trim(from: 0, to: max(0.02, Double(window.percent) / 100))
                    .stroke(Self.ringColor(percent: window.percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// 语义色只用于用量状态：< 70 绿、< 100 黄、耗尽红。
    static func ringColor(percent: Int) -> Color {
        switch percent {
        case ..<70: return Color.green.opacity(0.85)
        case ..<100: return Color.yellow.opacity(0.9)
        default: return Color.red.opacity(0.9)
        }
    }
}
