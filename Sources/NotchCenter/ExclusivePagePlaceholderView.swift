import NotchCenterKit
import SwiftUI

// MARK: - 整页块不可用时的宿主占位

/// 整页块的插件被停用 / 卸载（或块定义已不存在）时，宿主在那一整页上给的占位视图。
///
/// 为什么只有整页块有占位、普通块维持"静默跳过"：普通块失效留下的是一格空白，
/// 整页块失效留下的是一整页空白——后者没有解释，用户只会以为面板坏了。
/// 这一处分叉有明确理由，见 Agent Note 2026-09-10-plugin-page-blocks。
///
/// 视觉与普通抽屉块刻意不同（不套 `BlockCard`，见 `DrawerBlockContainer` 的整页分支）：
/// 这是宿主自己的说明态，不该伪装成插件内容。
struct ExclusivePagePlaceholderView: View {
    /// 被停用的插件名（取自插件元数据，用户据此去设置里找）。
    let pluginName: String

    var body: some View {
        VStack(spacing: NotchTokens.Space.blockGap) {
            Image(systemName: "puzzlepiece.extension")
                .font(NotchTokens.Text.system(24, weight: .light))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .frame(width: 48, height: 48)
                .background(Circle().fill(NotchTokens.Surface.fill))
            Text(LF("panel.page.unavailable.title", pluginName))
                .font(NotchTokens.Text.system(13, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(L("panel.page.unavailable.body"))
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NotchGridMetrics.contentPadding)
        .accessibilityElement(children: .combine)
    }
}
