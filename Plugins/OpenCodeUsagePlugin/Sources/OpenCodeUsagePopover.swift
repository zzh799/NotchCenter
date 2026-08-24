import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 长按浮窗（独立 NSPanel，模式与 DshPopoverController 一致）
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
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
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

    static let size = CGSize(width: 272, height: 316)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("OpenCode Usage")
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
            Text(store.isConfigured ? "Loading usage…" : "Set cookie & workspace in Plugin Manager")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.58))
        }
    }

    /// 数据新鲜度 + 订阅套餐/支付方式等元信息。
    private func metaLine(for snapshot: UsageSnapshot) -> some View {
        var parts: [String] = []
        if let plan = snapshot.zen?.subscriptionPlan { parts.append(plan) }
        if let payment = snapshot.zen?.paymentMethodType { parts.append(payment) }
        parts.append("updated \(OpenCodeUsageParser.formatReset(seconds: max(0, Int(Date().timeIntervalSince(snapshot.updatedAt))))) ago")
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
            Text("in \(OpenCodeUsageParser.formatReset(seconds: window.resetInSec))")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(window.isRateLimited ? Color.red.opacity(0.9) : Color.white.opacity(0.58))
        }
        .padding(.leading, 42)
    }

    /// 重置的绝对本地时刻（now + resetInSec）。
    private var resetAbsoluteTime: String {
        guard window.resetInSec > 0 else { return "Resets soon" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return "Resets \(formatter.string(from: Date().addingTimeInterval(TimeInterval(window.resetInSec))))"
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
                    Text(peak ? "Peak remaining " : "Off-peak remaining ")
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
            Text("Peak").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.58))
            Circle().fill(Self.offPeakColor).frame(width: 6, height: 6)
            Text("Off-Peak").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.58))
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

// MARK: 浮窗窗口控制器

/// 单例持有 NSPanel，锚定块附近弹出，点击外部自动关闭（同 DshPopoverController）。
@MainActor
final class OpenCodeUsagePopoverController {
    static let shared = OpenCodeUsagePopoverController()

    private var panel: NSPanel?
    /// 点击外部关闭：本地鼠标监听。
    private var eventMonitor: Any?

    private init() {}

    /// 在块附近弹出浮窗。`frameInWindow` 为块在宿主窗口坐标系中的 frame
    /// （SwiftUI .global 空间），经宿主窗口 convertToScreen 转为屏幕坐标。
    func present(store: OpenCodeUsageStore, frameInWindow blockFrame: CGRect) {
        dismiss()

        // 块视图挂在某个 NotchPanel 的 hosting 树里：取包含当前鼠标位置的
        // 可见窗口作为宿主（长按发生时光标就在块上）。
        let mouse = NSEvent.mouseLocation
        guard let hostWindow = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(mouse) }) else {
            return
        }
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
            rootView: OpenCodeUsagePopoverContentView(store: store)
                .frame(width: OpenCodeUsagePopoverContentView.size.width, height: OpenCodeUsagePopoverContentView.size.height)
        )

        let origin = anchorPoint(for: screenFrame, size: OpenCodeUsagePopoverContentView.size)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: OpenCodeUsagePopoverContentView.size),
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
