import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 长按浮窗（生命周期与表现统一走 Kit 的 BlockPopover）
//
// 内容：Zen 余额 + 三个用量窗口的详细重置信息（绝对时刻 + 倒计时）
// + 峰谷时钟（24 小时表盘、红峰绿谷弧段、阶段倒计时，每秒走动）。

/// 浮窗内容视图。
struct OpenCodeUsagePopoverContentView: View {
    @ObservedObject var store: OpenCodeUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Color.white.opacity(0.045))
            windowDetails
            Divider().overlay(Color.white.opacity(0.045))
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
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
            Spacer()
            if let balance = store.snapshot?.zen?.balance {
                Text(balance, format: .currency(code: "USD"))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.92))
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
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.58))
        } else {
            Text(store.isConfigured ? L("usage.loading") : L("usage.notConfigured"))
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.58))
        }
    }

    /// 数据新鲜度 + 订阅套餐/支付方式等元信息。
    private func metaLine(for snapshot: UsageSnapshot) -> some View {
        var parts: [String] = []
        if let plan = snapshot.zen?.subscriptionPlan { parts.append(plan) }
        if let payment = snapshot.zen?.paymentMethodType { parts.append(payment) }
        parts.append(LF("popover.updatedAgo", OpenCodeUsageParser.formatReset(seconds: max(0, Int(Date().timeIntervalSince(snapshot.updatedAt))))))
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 9))
            .foregroundStyle(Color.white.opacity(0.38))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.76))
                .frame(width: 34, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Self.barColor(percent: window.percent))
                        .frame(width: geo.size.width * Double(window.percent) / 100)
                }
            }
            .frame(height: 5)

            Text("\(window.percent)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Self.barColor(percent: window.percent))
                .frame(width: 30, alignment: .trailing)
        }
        HStack {
            Text(resetAbsoluteTime)
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.58))
            Spacer()
            Text(LF("popover.resetsIn", OpenCodeUsageParser.formatReset(seconds: window.resetInSec)))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(window.isRateLimited ? Color.red.opacity(0.9) : Color.white.opacity(0.58))
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

    private static func barColor(percent: Int) -> Color {
        switch percent {
        case ..<70: return Color.green.opacity(0.85)
        case ..<100: return Color.yellow.opacity(0.9)
        default: return Color.red.opacity(0.9)
        }
    }
}

// MARK: 峰谷时钟（24 小时表盘）

struct PeakClockView: View {
    let now: Date

    private static let peakColor = Color(red: PeakClockLogic.peakColor.red, green: PeakClockLogic.peakColor.green, blue: PeakClockLogic.peakColor.blue)
    private static let offPeakColor = Color(red: PeakClockLogic.offPeakColor.red, green: PeakClockLogic.offPeakColor.green, blue: PeakClockLogic.offPeakColor.blue)

    var body: some View {
        let peak = PeakClockLogic.isPeak(now)
        let liveColor = peak ? Self.peakColor : Self.offPeakColor
        let peaks = PeakClockLogic.peakArcs(now)

        return HStack(spacing: 12) {
            dial(peaks: peaks, handColor: liveColor)
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 4) {
                Text(clockTime)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(liveColor)
                HStack(spacing: 5) {
                    Circle()
                        .fill(liveColor)
                        .frame(width: 6, height: 6)
                    Text(peak ? L("clock.peakRemaining") : L("clock.offPeakRemaining"))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.58))
                    Text(PeakClockLogic.formatCountdown(PeakClockLogic.phaseRemainingSeconds(now)))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
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
            Text(L("clock.peak")).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.58))
            Circle().fill(Self.offPeakColor).frame(width: 6, height: 6)
            Text(L("clock.offPeak")).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.58))
        }
    }

    // MARK: 表盘

    /// 24 小时表盘：轨道圆环 + 红/绿弧段 + 24 根刻度 + 单针 + 中心点。
    private func dial(peaks: [PeakClockLogic.ClockArc], handColor: Color) -> some View {
        let offPeaks = PeakClockLogic.offPeakArcs(of: peaks)
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 5.5)
            ForEach(Array((peaks.map { ($0, Self.peakColor) } + offPeaks.map { ($0, Self.offPeakColor) }).enumerated()), id: \.offset) { _, item in
                arc(item.0, color: item.1)
            }
            // 24 根小时刻度，0/6/12/18 点加长。
            ForEach(0..<24, id: \.self) { hour in
                Capsule()
                    .fill(Color.white.opacity(hour % 6 == 0 ? 0.38 : 0.18))
                    .frame(width: 1, height: hour % 6 == 0 ? 7 : 4)
                    .offset(y: -40.5)
                    .rotationEffect(.degrees(Double(hour) * 15))
            }
            Rectangle()
                .fill(handColor)
                .frame(width: 2, height: 26)
                .offset(y: -13)
                .rotationEffect(.degrees(PeakClockLogic.handAngle(now)))
            Circle()
                .fill(handColor)
                .frame(width: 6, height: 6)
        }
    }

    /// 表盘角度弧段 → trim 圆弧（trim 起点 3 点钟方向，需转回 12 点钟起点）。
    private func arc(_ clockArc: PeakClockLogic.ClockArc, color: Color) -> some View {
        Circle()
            .trim(
                from: clockArc.startDegree / 360,
                to: max(clockArc.startDegree / 360 + 0.005, clockArc.endDegree / 360)
            )
            .stroke(color, style: StrokeStyle(lineWidth: 5.5, lineCap: .butt))
            .rotationEffect(.degrees(-90))
    }
}

// MARK: 浮窗入口（无状态薄门面：单例互斥、窗口配置与弹出动画都在 Kit）

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
