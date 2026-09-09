import NotchCenterKit
import SwiftUI

// MARK: - 无屏空态（三档分级，single / sliders 共用）
//
// 无外接屏时两块显示同一空态。旧实现是固定 52 图标 + 完整长文案，
// 在最小单元（75x60）下竖向必溢出，文本被卡片底边切掉。本视图按
// 可用 frame 高度分级，只降信息密度不改视觉语言（图标在上、文本在下）。
enum BrightnessEmptyPresentation: Equatable {
    /// 极限矮块：只剩灰色图标，完整文案进 help / 无障碍标签。
    case iconOnly
    /// 常规小块：小图标 + 短文案（两行内）。
    case compact
    /// 高块：原完整空态（大图标 + 完整文案）。
    case full

    /// 切档高度：低于 90 即最小单元一档（75x60）的图标态；
    /// 低于 140 覆盖默认单元高（120）的小块态；其余走完整态。
    static let iconOnlyHeight: CGFloat = 90
    /// 默认单元高 120 落在此档内；窄块（宽 <130，如单列 75/150）纵使够高
    /// 也放不下完整长文案，同样走紧凑态。
    static let compactHeight: CGFloat = 140
    static let compactWidth: CGFloat = 130

    static func resolve(frame: CGSize) -> BrightnessEmptyPresentation {
        if frame.height < iconOnlyHeight { return .iconOnly }
        if frame.height < compactHeight || frame.width < compactWidth { return .compact }
        return .full
    }
}

private enum BrightnessEmptyMetrics {
    static let fullIconFont: CGFloat = 22
    static let fullIconCircle: CGFloat = 52
    static let compactIconFont: CGFloat = 14
    static let compactIconCircle: CGFloat = 30
    static let iconOnlyFont: CGFloat = 20
}

/// 无屏空态的唯一实现：调用方传入块真实尺寸，内部分级渲染。
struct BrightnessEmptyView: View {
    let size: CGSize

    private var presentation: BrightnessEmptyPresentation {
        BrightnessEmptyPresentation.resolve(frame: size)
    }

    var body: some View {
        Group {
            switch presentation {
            case .iconOnly:
                Image(systemName: "sun.max")
                    .font(NotchTokens.Text.system(
                        BrightnessEmptyMetrics.iconOnlyFont, weight: .light))
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                    .help(L("drawer.empty.title"))
                    .accessibilityLabel(Text(L("drawer.empty.title")))
            case .compact:
                VStack(spacing: 6) {
                    Image(systemName: "sun.max")
                        .font(NotchTokens.Text.system(
                            BrightnessEmptyMetrics.compactIconFont, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.disabled)
                        .frame(
                            width: BrightnessEmptyMetrics.compactIconCircle,
                            height: BrightnessEmptyMetrics.compactIconCircle)
                        .background(Circle().fill(.white.opacity(0.07)))
                    Text(L("drawer.empty.short"))
                        .font(NotchTokens.Text.system(11, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .help(L("drawer.empty.title"))
                }
                .padding(.horizontal, 8)
            case .full:
                VStack(spacing: 10) {
                    Image(systemName: "sun.max")
                        .font(NotchTokens.Text.system(
                            BrightnessEmptyMetrics.fullIconFont, weight: .light))
                        .foregroundStyle(NotchTokens.Foreground.disabled)
                        .frame(
                            width: BrightnessEmptyMetrics.fullIconCircle,
                            height: BrightnessEmptyMetrics.fullIconCircle)
                        .background(Circle().fill(.white.opacity(0.07)))
                    Text(L("drawer.empty.title"))
                        .font(NotchTokens.Text.system(12, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
