import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（放置实例级外观）
//
// 同一块类型可在抽屉放多个实例：数据一律来自共享的 OpenCodeUsageStore
// （单份抓取/缓存，所有实例同源），而**显示样式与峰谷倒计时开关是每个
// 实例私有的**——持久化在该实例的 placementStore 里，经注册表的共享
// ObservableObject 驱动多屏所有副本同步刷新。
//
// 样式：余量环（三环同心）· 余量表（三窗口横条量表）· 峰谷时钟（表盘）。
// 卡片壳与长按浮窗触发统一走 Kit 的 BlockCard / blockPopoverTrigger。

struct OpenCodeUsageBlockView: View {
    /// 本放置实例的外观模型（同一实例跨屏共享同一个对象）。
    @ObservedObject var instance: OpenCodeUsageInstanceModel
    @ObservedObject private var store = OpenCodeUsageStore.shared

    init(instance: OpenCodeUsageInstanceModel) {
        self.instance = instance
    }

    var body: some View {
        BlockCard(hoverEffect: true) { _ in
            content
                .overlay(alignment: .topTrailing) {
                    refreshButton
                }
        }
        // 手势顺序、长按抑制点击等语义都在触发器内统一实现；不设 onTap，点击无动作。
        .blockPopoverTrigger(
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

    // MARK: 正常数据（按实例样式分发）

    private func usageContent(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 8) {
            switch instance.appearance.style {
            case .rings:
                ringsContent(snapshot)
            case .meters:
                metersContent(snapshot)
            case .peakClock:
                peakClockContent
            }
            switch instance.appearance.footer {
            case .none:
                EmptyView()
            case .zenBalance:
                if let balance = snapshot.zen?.balance {
                    balanceRow(balance)
                }
            case .phaseCountdown:
                phaseRemainingView
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
    }

    /// 峰谷时钟与余量环共用同一个直径：两者是同一块的可切换样式，
    /// 尺寸不一致会让切换瞬间卡片主体跳变（环 56↔钟 64），统一取 60。
    private static let visualDiameter: CGFloat = 60

    /// 余量环：三环同心用量图。
    private func ringsContent(_ snapshot: UsageSnapshot) -> some View {
        UsageRingsView(windows: snapshot.windows, outerDiameter: Self.visualDiameter)
            .frame(width: Self.visualDiameter)
    }

    /// 余量表：每个用量窗口一条横向量表（标签 + 胶囊进度条 + 百分比）。
    private func metersContent(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 7) {
            ForEach([UsageWindowKind.rolling, .weekly, .monthly], id: \.self) { kind in
                if let window = snapshot.windows[kind] {
                    UsageMeterRow(kind: kind, window: window)
                }
            }
        }
    }

    /// 峰谷时钟：24 小时表盘实时走动（阶段倒计时由统一的 countdown 行承担）。
    private var peakClockContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            PeakClockDial(now: context.date, diameter: Self.visualDiameter)
                .frame(maxWidth: .infinity)
        }
    }

    /// 底部信息行统一是“图标 + 数字”的紧凑样式，不带文字说明；
    /// 鼠标悬停时经 .help 提示语义。

    private func balanceRow(_ balance: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "circle.dollar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.58))
            Text(balance, format: .currency(code: "USD"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .help(L("usage.zenBalance"))
    }

    /// 当前峰/谷阶段的剩余倒计时（每秒走字，语义同浮窗里的 PeakClock；
    /// 由实例的 footer == .phaseCountdown 控制显隐）。
    private var phaseRemainingView: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let peak = PeakClockLogic.isPeak(context.date)
            HStack(spacing: 4) {
                Image(systemName: peak ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(peak ? Self.peakIconColor : Self.offPeakIconColor)
                Text(PeakClockLogic.formatCountdown(PeakClockLogic.phaseRemainingSeconds(context.date)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .help(peak ? L("clock.peakRemaining") : L("clock.offPeakRemaining"))
        }
    }

    private static let peakIconColor = Color(
        red: PeakClockLogic.peakColor.red,
        green: PeakClockLogic.peakColor.green,
        blue: PeakClockLogic.peakColor.blue
    )
    private static let offPeakIconColor = Color(
        red: PeakClockLogic.offPeakColor.red,
        green: PeakClockLogic.offPeakColor.green,
        blue: PeakClockLogic.offPeakColor.blue
    )

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

    /// 组件默认圆形按钮样式（Kit `IconCircleButton`，与编辑模式角标同一外观）。
    /// 未配置 / 加载中禁用并置灰；悬停增亮与手型光标由组件自带。
    private var refreshButton: some View {
        IconCircleButton(
            systemImage: "arrow.clockwise",
            helpText: L("usage.refreshHelp")
        ) {
            store.forceRefresh()
        }
        .disabled(store.isLoading || !store.isConfigured)
        .opacity((store.isLoading || !store.isConfigured) ? 0.35 : 1)
        .padding(6)
    }

    // MARK: 动作

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

// MARK: - 余量表行（标签 + 胶囊进度条 + 百分比）

struct UsageMeterRow: View {
    let kind: UsageWindowKind
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 6) {
            Text(kind.blockLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.66))
                .frame(width: 14, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(UsageRingsView.ringColor(percent: window.percent))
                        .frame(width: geo.size.width * CGFloat(window.percent / 100))
                }
            }
            .frame(height: 4)

            Text("\(window.percentText)%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(UsageRingsView.ringColor(percent: window.percent))
                .frame(width: 30, alignment: .trailing)
                .minimumScaleFactor(0.75)
        }
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
                    .trim(from: 0, to: max(0.02, window.percent / 100))
                    .stroke(Self.ringColor(percent: window.percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// 语义色只用于用量状态：< 70 绿、< 100 黄、耗尽红。
    static func ringColor(percent: Double) -> Color {
        switch percent {
        case ..<70: return Color.green.opacity(0.85)
        case ..<100: return Color.yellow.opacity(0.9)
        default: return Color.red.opacity(0.9)
        }
    }
}
