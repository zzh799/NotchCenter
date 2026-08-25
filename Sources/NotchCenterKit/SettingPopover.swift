import AppKit
import SwiftUI

// MARK: - 设置浮窗（所有插件设置的统一浮层展示）
//
// 编辑模式下紧凑图标右上角 / 抽屉块左上角的齿轮按钮触发。窗口生命周期、
// 进程内互斥（同一时刻至多一张浮卡）、抽屉收起自动关闭、屏幕钳制定位与
// spring 弹出动画全部复用 BlockPopover 的既有管线——SettingPopover 只负责
// 「设置卡片」的标准版式：标题行（齿轮 + 插件名）+ 发丝分隔线 + 插件提供
// 的设置视图。任何插件设置都必须经它展示，不要在宿主或插件里自绘浮窗。

@MainActor
public final class SettingPopover {
    /// 进程内唯一入口：经 BlockPopover 单例天然与内容浮窗全局互斥。
    public static let shared = SettingPopover()

    /// 默认卡片尺寸：容纳官方插件的表单式设置视图（输入行 + 说明文字）。
    public static let defaultCardSize = CGSize(width: 300, height: 260)

    private init() {}

    /// 在锚定组件处弹出设置浮窗。
    /// - Parameters:
    ///   - frameInWindow: 锚定块在宿主窗口坐标系中的 frame（SwiftUI .global 空间），
    ///     内部经 BlockPopover 的既有管线换算为屏幕坐标并钳回可见区域。
    ///   - cardSize: 卡片内容区尺寸；设置视图在其中自由排布。
    ///   - placement: 与锚定块的相对摆放——紧凑小图标贴下方（.below），
    ///     抽屉块同心覆盖（.overlay，默认）。
    ///   - title: 标题行文字，通常传插件显示名；nil/空串时只显示齿轮图标。
    public func present(
        anchoredTo frameInWindow: CGRect,
        cardSize: CGSize = SettingPopover.defaultCardSize,
        placement: BlockPopoverPlacement = .overlay,
        title: String?,
        @ViewBuilder content: () -> some View
    ) {
        BlockPopover.shared.present(
            anchoredTo: frameInWindow,
            cardSize: cardSize,
            placement: placement
        ) {
            SettingPopoverCard(title: title, content: AnyView(content()))
        }
    }

    public func dismiss() {
        BlockPopover.shared.dismiss()
    }
}

/// 设置卡片标准版式：标题行 + 分隔线 + 内容区。深色环境、近黑半透明底、
/// 发丝描边与弹出动画由 BlockPopoverCard 统一施加，这里只做内部排版。
private struct SettingPopoverCard: View {
    let title: String?
    let content: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            // 内容区可滚动：设置内容超过默认卡片高度（如“实例外观 + 账户”
            // 多节表单）时不出卡片边界，各节仍按自然高度排布。
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
    }
}
