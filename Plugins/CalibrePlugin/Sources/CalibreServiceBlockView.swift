import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（服务名 + 开关 + 点击开网页 + 长按浮窗）

/// 窄块紧凑排布（宽度不足时隐藏指示灯 / 状态 / 端口 / 开关）：
/// 退化为「图标 + 名称」——开启态整块染系统强调色（半透明）+ 白色图标，
/// 关闭态保持卡片默认底 + 淡白（亮灰）图标。
/// （两个服务卡同源，改动需同步 DshServiceBlockView。）
enum ServiceBlockCompactMetrics {
    /// 低于该宽度即切紧凑排布：窄块没有横向余量容纳开关与状态行。
    static let widthThreshold: CGFloat = 110
    /// 紧凑图标字号。
    static let iconSize: CGFloat = 15
    /// 开启态背景圆角（对齐 Kit `BlockCard` 的卡片壳圆角 10）。
    static let cornerRadius: CGFloat = 10
    /// 开启态背景浓度：半透明，保留卡片发丝描边与悬停微亮。
    static let onBackgroundOpacity: CGFloat = 0.55

    /// 是否走紧凑排布（纯值，便于单测）。
    static func isCompact(width: CGFloat) -> Bool {
        width < widthThreshold
    }
}

/// CalibrePlugin 的抽屉块：1×1 / 2×1 两种跨度（决策 11）。
/// 外观（卡片壳/悬停/按压增亮）走 Kit 的 `BlockCard`，长按浮窗触发走
/// `blockPopoverTrigger`；本文件只保留数据 → 文案的映射与内容排布。
/// - 点击（开关以外的区域）→ 启停服务（紧凑排布下没有开关，这是唯一的启停入口）
/// - 长按（0.2s）→ 弹出独立 NSPanel 浮窗（决策 6），打开网页的入口已移入浮窗
struct CalibreServiceBlockView: View {
    /// 绑定插件级共享监视器（`CalibreServiceMonitor.shared`）：块视图每次展开都会
    /// 被宿主重建（收起时身份销毁），监视器必须活过视图生命周期，开关才能以
    /// 当前真实状态起渲染，而不是每次都从“关”起步重播打开动画。
    @ObservedObject private var monitor = CalibreServiceMonitor.shared

    var body: some View {
        BlockCard(hoverEffect: true) { _ in
            // 宽度决定排布：窄块只留「图标 + 名称」，宽块才铺指示灯 / 状态 /
            // 端口 / 开关（探针只校验最小尺寸下的单行带，两种排布都居中，不越界）。
            GeometryReader { proxy in
                Group {
                    if ServiceBlockCompactMetrics.isCompact(width: proxy.size.width) {
                        compactContent
                    } else {
                        detailContent
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        // 手势顺序、长按抑制点击、开关自行消费点击等语义都在触发器内统一实现。
        .blockPopoverTrigger(
            // 点击即启停（busy 期间 toggleRunning 自行忽略），打开网页改由浮窗承担。
            onTap: { _ in monitor.toggleRunning() },
            onLongPress: { frameInWindow in
                CalibrePopover.present(monitor: monitor, frameInWindow: frameInWindow)
            }
        )
        // 点击语义从「开网页」改成「启停」，补一条悬停提示纠正旧肌肉记忆。
        .help(L("calibre.block.help"))
        .animation(.easeOut(duration: 0.16), value: monitor.message)
        // 强调色底与图标色的开/关切换走同一条短 easeOut，避免状态翻转时硬切。
        .animation(.easeOut(duration: 0.16), value: monitor.isServiceOn)
        // 共享监视器按 10s 低频轮询；展开瞬间补一次即时探测，状态新鲜度
        // 与旧“每次新建监视器立即探测”的行为持平。
        .task { await monitor.refreshOnce() }
    }

    // MARK: 紧凑排布（窄块：图标 + 名称）

    private var compactContent: some View {
        let isOn = monitor.isServiceOn
        return VStack(spacing: 4) {
            Image(systemName: "books.vertical")
                .font(.system(size: ServiceBlockCompactMetrics.iconSize, weight: .medium))
                // 开启：白色图标压在强调色底上；关闭：淡白（亮灰）图标留在默认卡片底上。
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.6))
            Text("Calibre")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(isOn ? 0.92 : 0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 开启态整块上系统强调色，关闭态不画背景（沿用 BlockCard 的默认底）。
        .background {
            if isOn {
                RoundedRectangle(
                    cornerRadius: ServiceBlockCompactMetrics.cornerRadius,
                    style: .continuous
                )
                .fill(Color.accentColor.opacity(ServiceBlockCompactMetrics.onBackgroundOpacity))
            }
        }
    }

    // MARK: 完整排布（宽块：指示灯 + 名称 + 状态 + 端口 + 开关）

    private var detailContent: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibre")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(statusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
                if let portText {
                    Text(portText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(1)
                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .managed: return L("calibre.subtitle.runningShort")
        case .starting: return L("calibre.state.starting")
        case .loadedNotRunning: return L("calibre.state.loadedNotRunning")
        case .unmanagedExternal: return L("calibre.subtitle.unmanaged")
        case .portConflict(let n): return LF("calibre.subtitle.portConflict", n)
        case .stopped: return L("calibre.state.stopped")
        }
    }

    /// 端口仅在「运行中（managed）」且探测到端口时展示，单独成行，与状态位分离。
    private var portText: String? {
        guard case .managed = monitor.status.state,
              let port = monitor.status.port else { return nil }
        return LF("calibre.subtitle.port", String(port))
    }

    private var busyText: String {
        monitor.isServiceOn ? L("calibre.action.stopping") : L("calibre.action.starting")
    }
}
