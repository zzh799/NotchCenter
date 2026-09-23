import NotchCenterKit
import SwiftUI

// MARK: - 块视图：三态版式
//
// 版式全部读 `RemindersMetrics.layout(for:)`——同一份推导既喂视图、又喂打包期探针
// （见 `RemindersMetrics` 文件头）。三态由宽 × 高双轴断点决定，不是"大中小"。
//
// 交互沿仓库统一管线：行的"点击 = 勾选"走 `blockPopoverTrigger` 的 `DragGesture`
// （裸 `TapGesture` 真机不回调，是红线）；`onLongPress` 与点击**同义**——该管线
// 按满 0.2s 会抑制松手时的 `onTap`，留空等于把那一次按压吃掉（ClockPlugin 同款）。

struct RemindersBlockView: View {
    let context: BlockContext
    @ObservedObject var instance: RemindersInstanceModel

    @Environment(\.isDrawerPresented) private var isDrawerPresented

    var body: some View {
        let size = context.layoutInfo.frame.size
        let layout = RemindersMetrics.layout(for: size)

        BlockCard(hoverEffect: true) { _ in
            content(layout: layout)
        }
        .overlay(alignment: .bottom) { bottomLayer }
        .task { instance.activate() }
        .onChange(of: isDrawerPresented) { _, presented in
            // 温存契约：抽屉收起不卸载视图树，`.onDisappear` 只表达挂载/卸载。
            // 重新可见时幂等校准（覆盖睡眠唤醒、Reminders.app 里的改动），
            // 不可见时停掉在飞任务与瞬时浮层。
            if presented {
                instance.activate()
            } else {
                instance.suspend()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 三态内容

    @ViewBuilder
    private func content(layout: RemindersLayout) -> some View {
        if !instance.permission.isUsable {
            permissionGate(layout: layout)
        } else if instance.sourceRemoved {
            stateMessage(
                symbol: "checklist",
                title: L("state.removed.title"),
                hint: L("state.removed.hint"))
        } else {
            VStack(spacing: 0) {
                topZone(layout: layout)
                    .frame(
                        width: layout.size.width, height: layout.topBand.height,
                        alignment: .leading)
                listZone(layout: layout)
                    .frame(
                        width: layout.size.width, height: layout.listBand.height,
                        alignment: .top)
            }
            .frame(
                width: layout.size.width, height: layout.size.height,
                alignment: .topLeading)
        }
    }

    // MARK: 顶部区带（三态各异）

    @ViewBuilder
    private func topZone(layout: RemindersLayout) -> some View {
        switch layout.state {
        case .narrow:
            HStack(spacing: RemindersMetrics.rowSpacing) {
                nameLabel(layout: layout)
                Spacer(minLength: 0)
                countLabel(layout: layout)
            }
            .padding(edgeInsets(layout.topBand, content: layout.topContentRect))
        case .wide:
            // 顶行 = 徽章 + 大计数 + 名称（footer 上移，见决策
            // 2026-09-20-reminders-wide-footer-to-top）：计数与名称保持基线对齐，
            // 外层按中心对齐，徽章与文本行互不牵制。
            HStack(spacing: RemindersMetrics.rowSpacing) {
                badge
                HStack(alignment: .firstTextBaseline, spacing: RemindersMetrics.rowSpacing) {
                    countLabel(layout: layout)
                    nameLabel(layout: layout)
                }
                Spacer(minLength: 0)
            }
            .padding(edgeInsets(layout.topBand, content: layout.topContentRect))
        case .large:
            // 头部两行堆叠、左对齐：大计数在上、清单名在下（复刻图版式，
            // 原实现是同一行"计数左 + 名称右"）。区带底边的头部线见 `headerRule`。
            VStack(alignment: .leading, spacing: 0) {
                countLabel(layout: layout)
                nameLabel(layout: layout)
            }
            // 高度钉死为内容盒高、顶部对齐：两行行盒的自然和可能比内容盒高 1~2pt，
            // 不定高会把区带撑破、连带把底边的头部线推出区带。
            .frame(height: layout.topContentRect.height, alignment: .top)
            .padding(edgeInsets(layout.topBand, content: layout.topContentRect))
            .overlay(alignment: .bottom) { headerRule(layout: layout) }
        }
    }

    /// 大态顶部区带底边的头部线：宽度即内容盒全宽（左右各让出内边距）。
    /// 只画在区带底边——它是区带的分界，不是行列表的一部分，不随行滚动。
    @ViewBuilder
    private func headerRule(layout: RemindersLayout) -> some View {
        if layout.headerRuleHeight > 0 {
            Rectangle()
                .fill(RemindersPalette.ruleStroke)
                .frame(height: layout.headerRuleHeight)
                .padding(.horizontal, layout.rowInset)
        }
    }

    private func nameLabel(layout: RemindersLayout) -> some View {
        Text(sourceTitle)
            .font(NotchTokens.Text.system(layout.nameFontSize, weight: .semibold))
            .foregroundStyle(NotchTokens.Foreground.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func countLabel(layout: RemindersLayout) -> some View {
        Text("\(instance.items.count)")
            .font(NotchTokens.Text.system(layout.countFontSize, weight: .semibold))
            .foregroundStyle(NotchTokens.Foreground.body)
            .monospacedDigit()
    }

    /// 宽态的圆形徽章：**清单真实颜色**作低 alpha 圆底，符号用原色。
    /// 不用"实色底 + 白符号"——Reminders 调色板含黄色，白符号在黄底上不可读。
    /// 智能视图没有颜色可用（EventKit 不暴露），走中性圆底 + 语义符号。
    private var badge: some View {
        let appearance = badgeAppearance
        return Image(systemName: appearance.symbol)
            .font(NotchTokens.Text.system(13, weight: .medium))
            .foregroundStyle(appearance.glyph)
            .frame(width: RemindersMetrics.badgeDiameter, height: RemindersMetrics.badgeDiameter)
            .background(Circle().fill(appearance.fill))
            .accessibilityHidden(true)
    }

    private var badgeAppearance: (symbol: String, fill: Color, glyph: Color) {
        switch instance.source {
        case let .list(identifier):
            guard let descriptor = instance.lists.first(where: { $0.id == identifier }) else {
                return ("checklist", RemindersPalette.badgeNeutral, NotchTokens.Foreground.secondary)
            }
            let color = Color(remindersTint: descriptor.color)
            return ("checklist", color.opacity(RemindersPalette.badgeTintOpacity), color)
        case let .smart(smart):
            return (
                RemindersSourceText.symbol(for: smart),
                RemindersPalette.badgeNeutral,
                NotchTokens.Foreground.secondary)
        }
    }

    // MARK: 行列表区带

    @ViewBuilder
    private func listZone(layout: RemindersLayout) -> some View {
        if instance.items.isEmpty {
            stateMessage(
                symbol: emptyStateSymbol,
                title: emptyStateTitle,
                hint: nil)
        } else {
            // 块内自带滚动（与 CommandScheduler / ClipboardHistory 同款）：
            // 条目多于块高时在块内滚动，不撑破块、不溢出到邻居。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(instance.items.enumerated()), id: \.element.id) { index, item in
                        RemindersRowView(
                            item: item,
                            layout: layout,
                            showsDivider: layout.showsRowDividers
                                && index < instance.items.count - 1,
                            onComplete: { complete(item) })
                            .frame(height: layout.rowHeight)
                    }
                }
                .padding(.horizontal, layout.rowInset)
            }
            .frame(height: layout.listBand.height, alignment: .top)
        }
    }

    private func complete(_ item: RemindersItem) {
        // 预览副本（滑动切页的过渡视图）不得产生副作用：勾选会写 EventKit。
        guard !context.layoutInfo.isPreview else { return }
        instance.complete(item)
    }

    // MARK: 空态 / 权限引导

    private var emptyStateSymbol: String {
        switch instance.source {
        case .list: return "checklist"
        case let .smart(smart): return RemindersSourceText.symbol(for: smart)
        }
    }

    private var emptyStateTitle: String {
        switch instance.source {
        case .list: return L("state.empty.list")
        case let .smart(smart): return RemindersSourceText.emptyTitle(for: smart)
        }
    }

    private func stateMessage(symbol: String, title: String, hint: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system(16, weight: .regular))
                .foregroundStyle(NotchTokens.Foreground.disabled)
            Text(title)
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let hint {
                Text(hint)
                    .font(NotchTokens.Text.system(9))
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(RemindersMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 缺权限时的引导态。形态与 CameraPlugin 的 `CameraPermissionGateView` 同款，
    /// 且**唯一入口**是宿主「权限管理」弹窗——插件不代开系统设置。
    private func permissionGate(layout: RemindersLayout) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(NotchTokens.Text.system(12, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(L("gate.title"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                    .lineLimit(1)
            }
            Text(L("gate.message"))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Button(action: { RemindersCore.shared.presentPermissionGuide() }) {
                Text(L("gate.openSettings"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(RemindersSmallButtonStyle())
            .help(L("gate.openSettings.help"))
            .accessibilityLabel(L("gate.openSettings.help"))
            Spacer(minLength: 0)
        }
        .padding(RemindersMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 底部浮层（撤销条 / 一次性错误提示，同一个位置二选一）

    @ViewBuilder
    private var bottomLayer: some View {
        Group {
            if let notice = instance.notice {
                toastRow(text: notice, action: nil, actionTitle: nil)
            } else if let undoBar = instance.undoBar {
                toastRow(
                    text: LF("undo.completed", undoBar.title),
                    action: { instance.undoCompletion() },
                    actionTitle: L("undo.action"))
            }
        }
        .animation(NotchTokens.Motion.stateChange, value: instance.undoBar)
        .animation(NotchTokens.Motion.stateChange, value: instance.notice)
    }

    private func toastRow(text: String, action: (() -> Void)?, actionTitle: String?) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(RemindersSmallButtonStyle())
                    .help(L("undo.action.help"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: RemindersMetrics.undoBarHeight)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .fill(RemindersPalette.toastSurface))
        .overlay(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .strokeBorder(RemindersPalette.toastStroke, lineWidth: 1))
        .padding(RemindersMetrics.padding)
        .transition(.opacity)
    }

    // MARK: 杂项

    private var sourceTitle: String {
        RemindersSourceText.title(for: instance.source, lists: instance.lists)
    }

    /// 区带 → 实际内边距：四边都由版式给定。内容盒左右对称——块内已没有需要
    /// 让位的悬浮角标（换源入口 2026-09-21 起只在块齿轮的设置浮窗里）。
    private func edgeInsets(_ band: CGRect, content: CGRect) -> EdgeInsets {
        EdgeInsets(
            top: content.minY - band.minY,
            leading: content.minX - band.minX,
            bottom: band.maxY - content.maxY,
            trailing: band.maxX - content.maxX)
    }
}

// MARK: - 行

struct RemindersRowView: View {
    let item: RemindersItem
    let layout: RemindersLayout
    let showsDivider: Bool
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: layout.rowSpacing) {
            checklist
            Text(item.title.isEmpty ? L("row.untitled") : item.title)
                .font(NotchTokens.Text.system(layout.titleFontSize))
                .foregroundStyle(NotchTokens.Foreground.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if item.isRepeating {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(NotchTokens.Text.system(layout.repeatIconSize, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { divider }
        .contentShape(Rectangle())
        .blockPopoverTrigger(
            onTap: { _ in onComplete() },
            // 长按与点击同义：该管线按满 0.2s 会抑制松手时的 onTap，留空等于
            // 把这一次按压吃掉（同 ClockPlugin 的处理）。
            onLongPress: { _ in onComplete() },
            cornerRadius: NotchTokens.Radius.button)
        .help(L("row.help"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            item.isRepeating
                ? LF("row.a11y.repeating", item.title)
                : LF("row.a11y", item.title))
        .accessibilityAddTraits(.isButton)
    }

    /// 空心圆（未完成）。用 `strokeBorder` 而非 `stroke`：描边画在框内，
    /// 直径就是视觉直径，不随线宽外扩。
    private var checklist: some View {
        Circle()
            .strokeBorder(NotchTokens.Foreground.secondary, lineWidth: layout.checklistLineWidth)
            .frame(width: layout.checklistDiameter, height: layout.checklistDiameter)
    }

    /// 行间发丝分隔线。只画在缩进内（与截图的左卡/中卡一致），且在滚动内容里
    /// 随行滚动——不画最后一行，避免列表底部多一条悬空线。大态按复刻图走虚线，
    /// 且左端缩进到标题起点（避开勾选圈）。
    @ViewBuilder
    private var divider: some View {
        if showsDivider {
            let dashed = layout.rowDividerDashed
            RemindersHairlineShape()
                .stroke(
                    dashed ? RemindersPalette.ruleStroke : NotchTokens.Hairline.divider,
                    style: StrokeStyle(
                        lineWidth: 1,
                        dash: dashed ? RemindersPalette.rowRuleDash : []))
                .frame(height: 1)
                .padding(.leading, layout.dividerLeadingInset)
        }
    }
}

/// 行间发丝线的形状：在给定矩形的垂直中线画一条横线（线宽由 `stroke` 给）。
/// 单独成 Shape 是因为虚线节奏只能通过 `stroke(_:style:)` 表达，`Rectangle().fill`
/// 画不出虚线。
private struct RemindersHairlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
