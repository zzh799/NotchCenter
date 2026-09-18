import SwiftUI

// MARK: - 服务控制块（Dsh / Calibre 同源卡片，框架级统一实现）
//
// 历史上两个插件各持一份 180 行、1:1 相同的 ServiceBlockView（靠注释人工
// 同步）。本组件把「卡片壳 + 紧凑/完整双排布 + 开关 + 启停点击 + 长按浮窗
// 触发」上提到 Kit，插件侧只保留：监视器绑定、状态 → 文案/指示灯映射
// （L10n 在插件内）与浮窗入口。样式值一律引用 `NotchTokens`。
//
// 启停（busy）期的表达按排布分流：完整排布用状态行文案，紧凑排布没有状态行，
// 改在图标位显示旋转指示（见 `ServiceBusyRing`）——否则整卡在启停期间毫无变化。

/// 窄块紧凑排布阈值（宽度不足时隐藏指示灯 / 状态 / 端口 / 开关）：
/// 退化为「图标 + 名称」——开启态白色底（适当浓度）+ 强调色图标 + 深色名称，
/// 关闭态保持卡片默认底 + 淡白（亮灰）图标。
public enum ServiceBlockCompactMetrics {
    /// 低于该宽度即切紧凑排布：窄块没有横向余量容纳开关与状态行。
    public static let widthThreshold: CGFloat = 110
    /// 紧凑图标字号。
    public static let iconSize: CGFloat = 15
    /// 图标位槽高：静态图标与启停旋转指示共用，busy 前后不跳行。
    public static let iconSlotHeight: CGFloat = 18
    /// 启停旋转指示的直径（对齐 `iconSize`）与弧线宽。
    public static let busyRingDiameter: CGFloat = 15
    public static let busyRingLineWidth: CGFloat = 2
    /// 开启态背景圆角（对齐 Kit `BlockCard` 的卡片壳圆角）。
    public static let cornerRadius: CGFloat = NotchTokens.Radius.card
    /// 开启态背景白色浓度：接近实心的白，略透出卡片壳以融入深色抽屉。
    public static let onBackgroundOpacity: CGFloat = 0.6

    /// 是否走紧凑排布（纯值，便于单测）。
    public static func isCompact(width: CGFloat) -> Bool {
        width < widthThreshold
    }
}

/// 服务控制类插件的标准抽屉块：1×1 / 2×1 两种跨度。
/// 外观（卡片壳/悬停/按压增亮）走 `BlockCard`，长按浮窗触发走
/// `blockPopoverTrigger`；点击（开关以外的区域）→ `onTap`（通常为启停），
/// 长按（0.2s）→ `onLongPress`（插件自行弹浮窗）。
public struct ServiceBlockView: View {
    private let name: String
    private let iconSystemName: String
    private let helpText: String
    private let isOn: Bool
    private let isBusy: Bool
    private let statusText: String
    private let portText: String?
    private let dotColor: Color
    private let onTap: () -> Void
    private let onLongPress: (CGRect) -> Void
    private let refresh: () async -> Void

    /// - Parameters:
    ///   - name/iconSystemName: 服务显示名与 SF Symbol（如 "server.rack"）。
    ///   - isOn/isBusy: 服务运行态与切换进行中（busy 时开关禁用，紧凑排布
    ///     改在图标位显示旋转指示）。
    ///   - statusText/portText: 状态行文案（busy 时调用方直接给在飞动作文案，
    ///     如 Starting… / Stopping…）；端口仅在运行中且探测到时给值。
    ///   - dotColor: 指示灯颜色（状态语义由调用方映射，如运行=绿）。
    ///   - onTap: 卡片点击动作（紧凑排布下是唯一启停入口）。
    ///   - onLongPress: 长按浮窗回调，frame 为宿主窗口坐标系。
    ///   - refresh: 块出现时的一次即时探测（如 `await monitor.refreshOnce()`）。
    public init(
        name: String,
        iconSystemName: String,
        helpText: String,
        isOn: Bool,
        isBusy: Bool,
        statusText: String,
        portText: String?,
        dotColor: Color,
        onTap: @escaping () -> Void,
        onLongPress: @escaping (CGRect) -> Void,
        refresh: @escaping () async -> Void
    ) {
        self.name = name
        self.iconSystemName = iconSystemName
        self.helpText = helpText
        self.isOn = isOn
        self.isBusy = isBusy
        self.statusText = statusText
        self.portText = portText
        self.dotColor = dotColor
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.refresh = refresh
    }

    public var body: some View {
        // 宽度在同一个 GeometryReader 内读一次，同时决定排布与按压反馈档位：
        // 紧凑排布只留「图标 + 名称」，按压是整卡唯一的即时反馈。
        GeometryReader { proxy in
            let isCompact = ServiceBlockCompactMetrics.isCompact(width: proxy.size.width)
            // 手势顺序、长按抑制点击、开关自行消费点击等语义都在触发器内统一实现。
            card(isCompact: isCompact)
                .blockPopoverTrigger(
                    onTap: { _ in onTap() },
                    onLongPress: onLongPress,
                    pressFeedback: Self.pressFeedback(isCompact: isCompact, isOn: isOn)
                )
        }
        .help(helpText)
        // 状态行文案与开/关底色翻转走同一条短 easeOut，避免状态切换时硬切
        // （曲线与抽屉收起同为 easeOut 0.16，见 Motion.stateChange）。
        .animation(NotchTokens.Motion.stateChange, value: statusText)
        .animation(NotchTokens.Motion.stateChange, value: isOn)
        // 监视器低频轮询之外，展开瞬间补一次即时探测，保证状态新鲜度。
        .task { await refresh() }
    }

    /// 按压反馈档位（纯值函数，测试覆盖）：紧凑开启态整块是白底（见
    /// `onBackgroundOpacity`），白色按压叠加在其上零对比，必须换压暗档；
    /// 其余情形（完整排布的深底卡片、紧凑关闭态）走加强增亮档——这张卡
    /// 没有开关子控件时按压就是全部反馈，`standard` 档的差值太小。
    /// `nonisolated`：`View` 一致性给整个类型带上了主 actor 隔离，纯值判定不必受它约束。
    public nonisolated static func pressFeedback(isCompact: Bool, isOn: Bool) -> BlockPressFeedback {
        (isCompact && isOn) ? .dimmed : .emphasized
    }

    private func card(isCompact: Bool) -> some View {
        BlockCard(hoverEffect: true) { _ in
            // 宽度决定排布：窄块只留「图标 + 名称」，宽块才铺指示灯 / 状态 /
            // 端口 / 开关（探针只校验最小尺寸下的单行带，两种排布都居中，不越界）。
            Group {
                if isCompact {
                    compactContent
                } else {
                    detailContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 紧凑排布（窄块：图标 + 名称）

    private var compactContent: some View {
        VStack(spacing: 4) {
            // 启停进行中：图标位换成旋转指示，名称保留——窄块没有状态行，
            // 没有它整卡在启停期间（含紧凑态唯一的启停入口被点中时）毫无变化。
            Group {
                if isBusy {
                    ServiceBusyRing(
                        diameter: ServiceBlockCompactMetrics.busyRingDiameter,
                        color: isOn ? Color.accentColor : NotchTokens.Foreground.secondary
                    )
                } else {
                    Image(systemName: iconSystemName)
                        .font(NotchTokens.Text.system(ServiceBlockCompactMetrics.iconSize, weight: .medium))
                        // 开启：强调色图标压在白色底上；关闭：淡白（亮灰）图标留在默认卡片底上。
                        .foregroundStyle(isOn ? Color.accentColor : NotchTokens.Foreground.muted)
                }
            }
            .frame(height: ServiceBlockCompactMetrics.iconSlotHeight)
            Text(name)
                .font(NotchTokens.Text.system(10, weight: .semibold, design: .rounded))
                // 开启态名称落在白色底上转深色保证对比，关闭态维持淡白层级。
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : NotchTokens.Foreground.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 开启态整块上适当浓度的白色，关闭态不画背景（沿用 BlockCard 的默认底）。
        .background {
            if isOn {
                RoundedRectangle(
                    cornerRadius: ServiceBlockCompactMetrics.cornerRadius,
                    style: .continuous
                )
                .fill(Color.white.opacity(ServiceBlockCompactMetrics.onBackgroundOpacity))
            }
        }
    }

    // MARK: 完整排布（宽块：指示灯 + 名称 + 状态 + 端口 + 开关）

    private var detailContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(NotchTokens.Text.system(11, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(statusText)
                    .font(NotchTokens.Text.caption)
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .lineLimit(1)
                if let portText {
                    Text(portText)
                        .font(NotchTokens.Text.caption)
                        .foregroundStyle(NotchTokens.Foreground.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in onTap() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(isBusy)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 启停进行中的旋转指示

/// 启停（busy）期间紧凑排布的图标位替代物：一段循环旋转的弧。
/// 静止的图标无法表达「已按下、正在启停」，而窄块没有状态行可承载文案，
/// 故用旋转表达「进行中」；旋转周期见 `NotchTokens.Motion.spin`。
/// `accessibilityReduceMotion` 为真时保持静止（仍是一段弧，与静态图标可区分）。
private struct ServiceBusyRing: View {
    let diameter: CGFloat
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: ServiceBlockCompactMetrics.busyRingLineWidth,
                    lineCap: .round
                )
            )
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear { startIfAllowed() }
            .onChange(of: reduceMotion) { _, _ in startIfAllowed() }
    }

    private func startIfAllowed() {
        guard !reduceMotion, !isSpinning else { return }
        withAnimation(NotchTokens.Motion.spin) {
            isSpinning = true
        }
    }
}
