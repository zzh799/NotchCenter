import NotchCenterKit
import SwiftUI

// MARK: - 插件调色板与样式常量（收敛点，勿在调用处散写内联字面量）
//
// 除「清单颜色」这一项外，本插件所有前景/背景都走 `NotchTokens` 的白色 alpha 阶梯。
// 清单颜色是**用户数据**（用户自己给清单配的色），不是主题色，故按
// [DESIGN.md §2.4](../../../docs/DESIGN.md) 的语义色豁免处理：允许留在插件本地，
// 但必须收敛到这里，并注明豁免理由。

enum RemindersPalette {
    /// 智能视图徽章的圆底。token 未覆盖：`Surface.fill*` 是卡片填充的三档
    /// （0.025 / 0.04 / 0.055），徽章是圆形底衬，取值对齐 Kit `IconCircleBadge`
    /// 的常态 0.14（同一视觉角色不另开数值）。
    static let badgeNeutral = Color.white.opacity(0.14)

    /// 清单颜色作徽章圆底时的稀释比例：**低 alpha 作底 + 原色作符号**。
    /// 不用"实色底 + 白符号"是因为 Reminders 的调色板含黄色，白符号在黄底上
    /// 对比度不可用；低 alpha 底 + 原色符号在任何色相上都可读，且与白色 alpha
    /// 阶梯的设计语言一致。
    static let badgeTintOpacity: Double = 0.22

    /// 撤销条 / 提示条的底色与描边（浮层角色，取 token 里的窗口底色）。
    static let toastSurface = NotchTokens.Surface.window
    static let toastStroke = NotchTokens.Hairline.drawerEdge

    /// 大态的头部线与行间分隔线。token 未覆盖：`Hairline.divider`（0.045）在深色
    /// 卡上实测等于看不见，达不到参考图"一条分隔"的效果；`Hairline.drawerEdge`
    /// （0.09）语义是抽屉外描边，借用会让同一数值承担两种角色。故按复刻图实测的
    /// 0.10 留在插件本地（决策记录 `2026-09-20-reminders-large-header` D3）。
    static let ruleStroke = Color.white.opacity(0.10)

    /// 大态行间分隔线的虚线节奏（复刻图实测：1pt 线宽、dash 2 / gap 1）。
    static let rowRuleDash: [CGFloat] = [2, 1]
}

// MARK: - 清单颜色 → SwiftUI 颜色

extension Color {
    /// 把 `RemindersListTint`（sRGB 纯值分量）桥成 SwiftUI 颜色。
    init(remindersTint: RemindersListTint) {
        self.init(
            .sRGB,
            red: remindersTint.red,
            green: remindersTint.green,
            blue: remindersTint.blue,
            opacity: remindersTint.opacity)
    }
}

// MARK: - 小尺寸圆角按钮（撤销条用，走 Kit 统一基体）

/// 撤销条上的动作按钮。参数与 CameraPlugin 权限引导按钮同族（字号按块内档收敛），
/// 复用 `RoundedHoverButtonBody` 而非自绘。
struct RemindersSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: NotchTokens.Text.system(11, weight: .semibold),
            normalOpacity: 0.07,
            hoverOpacity: 0.11,
            pressedOpacity: 0.15,
            strokeOpacity: 0.10,
            foregroundOpacity: 0.92,
            pressedForegroundOpacity: 0.60)
    }
}

// MARK: - 块在宿主窗口里的 frame（浮窗锚点）

/// 追踪块在 SwiftUI `.global` 空间（= 宿主窗口坐标）中的矩形。
///
/// **不能用 `context.layoutInfo.frame`**：宿主在正常渲染路径填的是网格本地坐标，
/// 只有编辑模式的设置路径才传真全局 frame，同一字段两义。浮窗锚点必须用这里。
struct RemindersGlobalFrameReader: View {
    let onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in onChange(frame) }
        }
    }
}
