import SwiftUI

// MARK: - 服务控制块（Dsh / Calibre 同源卡片，框架级统一实现）
//
// 历史上两个插件各持一份 180 行、1:1 相同的 ServiceBlockView（靠注释人工
// 同步）。本组件把「卡片壳 + 紧凑/完整双排布 + 开关 + 启停点击 + 长按浮窗
// 触发」上提到 Kit，插件侧只保留：监视器绑定、状态 → 文案/指示灯映射
// （L10n 在插件内）与浮窗入口。样式值一律引用 `NotchTokens`。

/// 窄块紧凑排布阈值（宽度不足时隐藏指示灯 / 状态 / 端口 / 开关）：
/// 退化为「图标 + 名称」——开启态白色底（适当浓度）+ 强调色图标 + 深色名称，
/// 关闭态保持卡片默认底 + 淡白（亮灰）图标。
public enum ServiceBlockCompactMetrics {
    /// 低于该宽度即切紧凑排布：窄块没有横向余量容纳开关与状态行。
    public static let widthThreshold: CGFloat = 110
    /// 紧凑图标字号。
    public static let iconSize: CGFloat = 15
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
    ///   - isOn/isBusy: 服务运行态与切换进行中（busy 时开关禁用）。
    ///   - statusText/portText: 状态行文案（busy 时调用方直接给 Starting… /
    ///     Stopping…）；端口仅在运行中且探测到时给值。
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
            onTap: { _ in onTap() },
            onLongPress: onLongPress
        )
        .help(helpText)
        // 状态行文案与开/关底色翻转走同一条短 easeOut，避免状态切换时硬切
        // （曲线与抽屉收起同为 easeOut 0.16，见 Motion.stateChange）。
        .animation(NotchTokens.Motion.stateChange, value: statusText)
        .animation(NotchTokens.Motion.stateChange, value: isOn)
        // 监视器低频轮询之外，展开瞬间补一次即时探测，保证状态新鲜度。
        .task { await refresh() }
    }

    // MARK: 紧凑排布（窄块：图标 + 名称）

    private var compactContent: some View {
        VStack(spacing: 4) {
            Image(systemName: iconSystemName)
                .font(NotchTokens.Text.system(ServiceBlockCompactMetrics.iconSize, weight: .medium))
                // 开启：强调色图标压在白色底上；关闭：淡白（亮灰）图标留在默认卡片底上。
                .foregroundStyle(isOn ? Color.accentColor : NotchTokens.Foreground.muted)
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
