import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 长按浮窗
//
// 内容：Zen 余额 + 三个用量窗口的详细重置信息（绝对时刻 + 倒计时）
// + 峰谷时钟（24 小时表盘、红峰绿谷弧段、阶段倒计时，每秒走动）。

/// 浮窗内容视图。
struct OpenCodeUsagePopoverContentView: View {
    @ObservedObject var store: OpenCodeUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(NotchTokens.Hairline.divider)
            windowDetails
            Divider().overlay(NotchTokens.Hairline.divider)
            // TimelineView 每秒驱动：指针、时钟文字与阶段倒计时实时走动。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PeakClockView(now: context.date)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    static let size = CGSize(width: 272, height: 316)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("popover.title"))
                .font(NotchTokens.Text.system(13, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTokens.Foreground.body)
            Spacer()
            if let balance = store.snapshot?.zen?.balance {
                Text(balance, format: .currency(code: "USD"))
                    .font(NotchTokens.Text.system(13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(NotchTokens.Foreground.body)
            }
        }
    }

    @ViewBuilder
    private var windowDetails: some View {
        if let snapshot = store.snapshot, !snapshot.windows.isEmpty {
            VStack(spacing: 7) {
                ForEach([UsageWindowKind.rolling, .weekly, .monthly], id: \.self) { kind in
                    if let window = snapshot.windows[kind] {
                        WindowDetailRow(kind: kind, window: window)
                    }
                }
                metaLine(for: snapshot)
            }
        } else if let message = store.errorMessage {
            Text(message)
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.muted)
        } else {
            Text(store.isConfigured ? L("usage.loading") : L("usage.notConfigured"))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.muted)
        }
    }

    /// 数据新鲜度 + 订阅套餐/支付方式等元信息。
    private func metaLine(for snapshot: UsageSnapshot) -> some View {
        var parts: [String] = []
        if let plan = snapshot.zen?.subscriptionPlan { parts.append(plan) }
        if let payment = snapshot.zen?.paymentMethodType { parts.append(payment) }
        parts.append(LF("popover.updatedAgo", OpenCodeUsageParser.formatReset(seconds: max(0, Int(Date().timeIntervalSince(snapshot.updatedAt))))))
        return Text(parts.joined(separator: " · "))
            .font(NotchTokens.Text.system(9))
            .foregroundStyle(NotchTokens.Foreground.disabled)
            .lineLimit(1)
    }
}

// MARK: 单窗口详情行：标签 + 百分比条 + 百分比 + 重置时刻与倒计时

private struct WindowDetailRow: View {
    let kind: UsageWindowKind
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(kind.shortLabel)
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .frame(width: 34, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchTokens.Surface.track)
                    Capsule()
                        .fill(Self.barColor(percent: window.percent))
                        .frame(width: geo.size.width * CGFloat(window.percent / 100))
                }
            }
            .frame(height: 5)

            Text("\(window.percentText)%")
                .font(NotchTokens.Text.system(10, weight: .medium, design: .monospaced))
                .foregroundStyle(Self.barColor(percent: window.percent))
                .frame(width: 30, alignment: .trailing)
                .minimumScaleFactor(0.75)
        }
        HStack {
            Text(resetAbsoluteTime)
                .font(NotchTokens.Text.system(9))
                .foregroundStyle(NotchTokens.Foreground.muted)
            Spacer()
            Text(LF("popover.resetsIn", OpenCodeUsageParser.formatReset(seconds: window.resetInSec)))
                .font(NotchTokens.Text.system(9, weight: .medium, design: .monospaced))
                .foregroundStyle(window.isRateLimited ? Color.red.opacity(0.9) : NotchTokens.Foreground.muted)
        }
        .padding(.leading, 42)
    }

    /// 重置的绝对本地时刻（now + resetInSec）。
    private var resetAbsoluteTime: String {
        guard window.resetInSec > 0 else { return L("popover.resetsSoon") }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return LF("popover.resetsAt", formatter.string(from: Date().addingTimeInterval(TimeInterval(window.resetInSec))))
    }

    private static func barColor(percent: Double) -> Color {
        switch percent {
        case ..<70: return Color.green.opacity(0.85)
        case ..<100: return Color.yellow.opacity(0.9)
        default: return Color.red.opacity(0.9)
        }
    }
}

// MARK: 峰谷时钟（24 小时表盘）

/// 24 小时表盘（可复用组件）：轨道圆环 + 红/绿弧段 + 24 根刻度 + 单针 +
/// 中心点。几何按直径等比缩放——浮窗与抽屉卡内的峰谷时钟共用同一实现。
/// 峰/谷色统一取 `PeakClockPalette`（全插件唯一转换点）。
struct PeakClockDial: View {
    let now: Date
    var diameter: CGFloat = 84

    private static let peakColor = PeakClockPalette.peak
    private static let offPeakColor = PeakClockPalette.offPeak

    var body: some View {
        let liveColor = PeakClockLogic.isPeak(now) ? Self.peakColor : Self.offPeakColor
        let arcs = arcSegments
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: diameter * 0.065)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, item in
                arc(item.0, color: item.1)
            }
            // 24 根小时刻度，0/6/12/18 点加长。
            ForEach(0..<24, id: \.self) { hour in
                Capsule()
                    .fill(Color.white.opacity(hour % 6 == 0 ? 0.38 : 0.18))
                    .frame(width: 1, height: hour % 6 == 0 ? diameter * 0.083 : diameter * 0.048)
                    .offset(y: -diameter * 0.482)
                    .rotationEffect(.degrees(Double(hour) * 15))
            }
            Rectangle()
                .fill(liveColor)
                .frame(width: diameter * 0.024, height: diameter * 0.31)
                .offset(y: -diameter * 0.155)
                .rotationEffect(.degrees(PeakClockLogic.handAngle(now)))
            Circle()
                .fill(liveColor)
                .frame(width: diameter * 0.071, height: diameter * 0.071)
        }
        .frame(width: diameter, height: diameter)
    }

    /// 峰（红）/谷（绿）弧段集合。
    private var arcSegments: [(PeakClockLogic.ClockArc, Color)] {
        let peaks = PeakClockLogic.peakArcs(now)
        return peaks.map { ($0, Self.peakColor) }
            + PeakClockLogic.offPeakArcs(of: peaks).map { ($0, Self.offPeakColor) }
    }

    /// 表盘角度弧段 → trim 圆弧（trim 起点 3 点钟方向，需转回 12 点钟起点）。
    private func arc(_ clockArc: PeakClockLogic.ClockArc, color: Color) -> some View {
        Circle()
            .trim(
                from: clockArc.startDegree / 360,
                to: max(clockArc.startDegree / 360 + 0.005, clockArc.endDegree / 360)
            )
            .stroke(color, style: StrokeStyle(lineWidth: diameter * 0.065, lineCap: .butt))
            .rotationEffect(.degrees(-90))
    }
}

/// 峰谷时钟完整视图（浮窗用）：表盘 + 数字时钟 + 阶段倒计时 + 图例。
struct PeakClockView: View {
    let now: Date

    private static let peakColor = PeakClockPalette.peak
    private static let offPeakColor = PeakClockPalette.offPeak

    var body: some View {
        let peak = PeakClockLogic.isPeak(now)
        let liveColor = peak ? Self.peakColor : Self.offPeakColor

        return HStack(spacing: 12) {
            PeakClockDial(now: now, diameter: 84)

            VStack(alignment: .leading, spacing: 4) {
                Text(clockTime)
                    .font(NotchTokens.Text.system(17, weight: .medium, design: .monospaced))
                    .foregroundStyle(liveColor)
                HStack(spacing: 5) {
                    Circle()
                        .fill(liveColor)
                        .frame(width: 6, height: 6)
                    Text(peak ? L("clock.peakRemaining") : L("clock.offPeakRemaining"))
                        .font(NotchTokens.Text.system(9))
                        .foregroundStyle(NotchTokens.Foreground.muted)
                    Text(PeakClockLogic.formatCountdown(PeakClockLogic.phaseRemainingSeconds(now)))
                        .font(NotchTokens.Text.system(9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(liveColor)
                }
                legend
            }
            Spacer(minLength: 0)
        }
    }

    private var clockTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: now)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Circle().fill(Self.peakColor).frame(width: 6, height: 6)
            Text(L("clock.peak")).font(NotchTokens.Text.system(9)).foregroundStyle(NotchTokens.Foreground.muted)
            Circle().fill(Self.offPeakColor).frame(width: 6, height: 6)
            Text(L("clock.offPeak")).font(NotchTokens.Text.system(9)).foregroundStyle(NotchTokens.Foreground.muted)
        }
    }
}

// MARK: 浮窗入口

@MainActor
enum OpenCodeUsagePopover {
    static let cardSize = OpenCodeUsagePopoverContentView.size

    static func present(store: OpenCodeUsageStore, frameInWindow: CGRect) {
        BlockPopover.shared.present(anchoredTo: frameInWindow, cardSize: cardSize) {
            OpenCodeUsagePopoverContentView(store: store)
        }
    }

    static func dismiss() {
        BlockPopover.shared.dismiss()
    }
}
