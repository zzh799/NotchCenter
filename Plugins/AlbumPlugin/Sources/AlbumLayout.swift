import NotchCenterKit
import SwiftUI

// MARK: - 布局常量（探针与视图同源）

/// 两个块的版式常量。**探针与视图必须由同一套常量推导**：打包期的最小尺寸遮挡
/// 校验按 `minSize` 调用探针，视图若另有一套数字，校验过的几何就不是用户看到的几何。
enum AlbumLayout {
    /// 内容内边距（图片四周留白，与其它官方块同值）。
    static let inset = NotchTokens.Space.cardPadding
    /// 图片圆角。
    static let radius = NotchTokens.Radius.chip
    /// 悬停角标的内缩：与宿主编辑角标同一环（`DrawerBlockContainer` 的 `padding(6)`）。
    static let badgeInset: CGFloat = 6
    /// 说明带高度。
    static let captionHeight: CGFloat = 26
    /// 说明带出现的最小块尺寸：再小就只留图，说明带会把画面切掉半张。
    static let captionMinWidth: CGFloat = 180
    static let captionMinHeight: CGFloat = 150
    /// 无来源/降级态里图标与文字的出现门槛。
    static let stateTitleMinWidth: CGFloat = 130
    static let stateTitleMinHeight: CGFloat = 84
    static let stateMessageMinHeight: CGFloat = 122
    static let stateActionMinHeight: CGFloat = 118
    static let stateSymbolSize: CGFloat = 20

    /// 图片区（= 块内容盒内缩后的矩形）。
    static func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: inset,
            y: inset,
            width: max(size.width - inset * 2, 0),
            height: max(size.height - inset * 2, 0))
    }

    /// 单个探针：图片区是块内唯一"必须完整可见"的 UI，说明带与角标都压在它上面。
    /// 悬浮角标**不单列探针**（两探针相交会被判自叠），这是官方块的统一纪律。
    static func probes(id: String, for size: CGSize) -> [BlockProbe] {
        [BlockProbe(id: id, rect: contentRect(for: size))]
    }

    static func showsCaptionBand(in size: CGSize) -> Bool {
        size.width >= captionMinWidth && size.height >= captionMinHeight
    }

    static func showsStateTitle(in size: CGSize) -> Bool {
        size.width >= stateTitleMinWidth && size.height >= stateTitleMinHeight
    }

    static func showsStateMessage(in size: CGSize) -> Bool {
        size.height >= stateMessageMinHeight && size.width >= stateTitleMinWidth
    }

    static func showsStateAction(in size: CGSize) -> Bool {
        size.height >= stateActionMinHeight && size.width >= stateTitleMinWidth
    }
}

// MARK: - 插件本地视觉常量

/// 本插件自有的两处视觉，`NotchTokens` 覆盖不到，收敛在此并注明豁免理由：
///
/// 1. **说明带的黑色渐变**。它压在任意一张照片上（可能是雪地，也可能是夜空），
///    白色文字的对比度无法靠"再叠一阶白"保证，必须用黑色遮罩。token 里的
///    `Surface` 全是白 alpha 阶梯，语义不匹配。
/// 2. **换图淡入曲线**。`Motion` 里的档位是为抽屉展开/悬停调的；照片交叉淡入
///    需要稍长一点的 easeOut，否则切换像闪一下。
enum AlbumPalette {
    static let scrimTop = Color.black.opacity(0)
    static let scrimBottom = Color.black.opacity(0.62)
    static let scrimTitle = NotchTokens.Foreground.selected
    static let scrimPosition = NotchTokens.Foreground.secondary
    /// 图片底衬：没有图时用轨道色，不能留一个同色空洞。
    static let placeholder = NotchTokens.Surface.track
    static let crossfade = Animation.easeOut(duration: 0.35)
}
