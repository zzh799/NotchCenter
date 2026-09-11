import NotchCenterKit
import SwiftUI

// MARK: - 组件可用性（Agent Note 2026-09-11-invalid-component-visibility）

/// 放置项指向的组件当前是否可用。三态的区别是**可逆性**：
///
/// - `.live`：正常渲染。
/// - `.pluginDisabled`：插件已发现但被停用——渲染不出来，但**停用可逆**（重新启用
///   即恢复摆放与画面），所以不算失效。
/// - `.missing`：插件已被移除，或插件的块定义已不存在——不可逆，只能重新添加，
///   属调试页「删除无效组件」的清理对象。
enum PlacementAvailability: Equatable {
    case live
    case pluginDisabled
    case missing

    /// 是否仍算有效（= 不该被清理）。停用中的摆放保留。
    var isLive: Bool { self != .missing }
}

// MARK: - 不可用组件占位

/// 组件不可用时的占位视图：抽屉块与紧凑槽共用同一套文案与图标。
///
/// 之所以需要它：抽屉对解析不到的放置项原先是**静默留白**，用户只看得到一个"洞"，
/// 分不清是插件被停用、被卸载，还是块定义没了（见 `NotchPanelContent.buildDrawerElements`）。
struct UnavailableBlockView: View {
    let availability: PlacementAvailability
    /// 紧凑带槽位极小：只画图标，说明走悬停提示。
    var compact = false

    var body: some View {
        if compact {
            icon
                .help(detail)
        } else {
            VStack(spacing: 4) {
                icon
                Text(title)
                    .font(NotchTokens.Text.system(11, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(hint)
                    .font(NotchTokens.Text.system(9))
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .background {
                // 虚线描边表明"这里是一格占位、不是坏掉的块"。
                RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                    .fill(NotchTokens.Surface.fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                            .strokeBorder(
                                NotchTokens.Hairline.divider,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    }
            }
            .help(detail)
        }
    }

    private var icon: some View {
        Image(systemName: availability == .pluginDisabled ? "pause.circle" : "questionmark.circle")
            .font(NotchTokens.Text.system(compact ? 14 : 18))
            .foregroundStyle(NotchTokens.Foreground.unavailable)
    }

    private var title: String {
        switch availability {
        case .live: return ""
        case .pluginDisabled: return L("block.unavailable.disabled.title")
        case .missing: return L("block.unavailable.missing.title")
        }
    }

    private var hint: String {
        switch availability {
        case .live: return ""
        case .pluginDisabled: return L("block.unavailable.disabled.hint")
        case .missing: return L("block.unavailable.missing.hint")
        }
    }

    private var detail: String { "\(title)：\(hint)" }
}
