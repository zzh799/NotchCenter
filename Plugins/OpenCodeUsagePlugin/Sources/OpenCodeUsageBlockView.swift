import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图：同心环用量图 + Zen 余额（对应参考实现的环形按钮 + 面板）
//
// 外/中/内三环分别是 5h 滚动 / 每周 / 每月窗口；点击打开 dashboard，
// 右上角小按钮手动刷新。medium 跨度额外显示余额与图例，small 只留环。

struct OpenCodeUsageBlockView: View {
    @ObservedObject private var store = OpenCodeUsageStore.shared
    @State private var isHovering = false
    /// 块在宿主窗口坐标系中的 frame（GeometryReader 实时捕获），用于浮窗定位。
    @State private var frameInWindow: CGRect?
    /// 长按进行中：背景微亮提示浮窗即将弹出（GestureState，手势中断自动复位）。
    @GestureState private var isPressing = false

    var body: some View {
        baseContent
            .background(
                // NSHostingView 里 SwiftUI 的 .global 空间即宿主窗口坐标。
                // 块随抽屉动画/缩放移动时持续更新，长按弹出的锚点始终准确。
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frameInWindow = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            frameInWindow = newFrame
                        }
                }
            )
            .animation(.easeOut(duration: 0.12), value: isPressing)
    }

    private var baseContent: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isPressing ? 0.055 : (isHovering ? 0.04 : 0.025)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(isPressing ? 0.20 : 0.09), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                refreshButton
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            // 手势顺序同 DshPlugin：长按优先于点击；整卡（含背景区）都可长按
            // 弹浮窗，点击（非刷新按钮区）打开 dashboard。
            .simultaneousGesture(longPressGesture)
            .onTapGesture {
                if !isPressing {
                    openDashboard()
                }
            }
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

    private var refreshButton: some View {
        Button {
            store.forceRefresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isHovering ? 0.88 : 0.55))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isLoading || !store.isConfigured)
        .opacity((store.isLoading || !store.isConfigured) ? 0.35 : 1)
        .help(L("usage.refreshHelp"))
    }

    // MARK: 长按手势 / 动作

    /// 纯 LongPressGesture：按住满 0.5s 的瞬间即触发浮窗，**无需等鼠标
    /// 释放**。不能用 sequenced(before: DragGesture)——onEnded 会推迟到
    /// 第二阶段（拖拽）结束。挂在整卡上（含背景区）。
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                showPopover()
            }
            .updating($isPressing) { _, state, _ in state = true }
    }

    private func showPopover() {
        guard let frameInWindow else { return }
        OpenCodeUsagePopover.present(store: store, frameInWindow: frameInWindow)
    }

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
