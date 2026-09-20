import NotchCenterKit
import SwiftUI

// MARK: - 数据源的展示文案与符号

@MainActor
enum RemindersSourceText {
    static func title(for smart: RemindersSource.SmartList) -> String {
        switch smart {
        case .today: return L("source.smart.today")
        case .scheduled: return L("source.smart.scheduled")
        case .important: return L("source.smart.important")
        case .all: return L("source.smart.all")
        }
    }

    /// 智能视图的语义符号。`important` 用感叹号而非旗标——「旗标」在公开
    /// EventKit 里读不到（只有私有 ReminderKit 能读），本块提供的是「优先级」。
    static func symbol(for smart: RemindersSource.SmartList) -> String {
        switch smart {
        case .today: return "calendar"
        case .scheduled: return "calendar.badge.clock"
        case .important: return "exclamationmark.circle"
        case .all: return "tray.full"
        }
    }

    static func emptyTitle(for smart: RemindersSource.SmartList) -> String {
        switch smart {
        case .today: return L("state.empty.today")
        case .scheduled: return L("state.empty.scheduled")
        case .important: return L("state.empty.important")
        case .all: return L("state.empty.all")
        }
    }

    /// 数据源的显示名。具体清单的标题要在 `lists` 里现查——清单被删时回退到
    /// 「未知清单」（此处的调用点都还会另判 `sourceRemoved`）。
    static func title(for source: RemindersSource, lists: [RemindersListDescriptor]) -> String {
        switch source {
        case let .list(identifier):
            return lists.first(where: { $0.id == identifier })?.title ?? L("source.unknownList")
        case let .smart(smart):
            return title(for: smart)
        }
    }

    /// 源是否合法可用（具体清单须在册；智能视图恒可用）。
    static func isAvailable(_ source: RemindersSource, lists: [RemindersListDescriptor]) -> Bool {
        switch source {
        case let .list(identifier):
            return lists.contains { $0.id == identifier }
        case .smart:
            return true
        }
    }
}

// MARK: - 切换数据源浮窗（块内右上角角标）

@MainActor
enum RemindersSourcePicker {
    /// 卡片尺寸夹在块矩形内：卡片一旦伸出块矩形，伸出的部分收不到鼠标——光标
    /// 离开抽屉的"停留区"会触发收起，收起又会让浮窗自动关闭（见
    /// `BlockPopover.cardInset` 的说明）。因此只做「理想尺寸与可用空间取小」，
    /// 不做「固定大卡片」。
    static func cardSize(for blockSize: CGSize) -> CGSize {
        let available = CGSize(
            width: max(blockSize.width - BlockPopover.cardInset, 0),
            height: max(blockSize.height - BlockPopover.cardInset, 0))
        return CGSize(width: min(236, available.width), height: min(260, available.height))
    }

    static func present(
        instance: RemindersInstanceModel,
        blockSize: CGSize,
        frameInWindow: CGRect
    ) {
        BlockPopover.shared.present(
            anchoredTo: frameInWindow,
            cardSize: cardSize(for: blockSize)
        ) {
            RemindersSourcePickerCard(instance: instance)
        }
    }
}

struct RemindersSourcePickerCard: View {
    @ObservedObject var instance: RemindersInstanceModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                sectionLabel(L("source.section.smart"))
                ForEach(RemindersSource.SmartList.allCases, id: \.self) { smart in
                    optionRow(
                        source: .smart(smart),
                        symbol: RemindersSourceText.symbol(for: smart),
                        tint: nil,
                        title: RemindersSourceText.title(for: smart))
                }
                if !instance.lists.isEmpty {
                    sectionLabel(L("source.section.lists"))
                        .padding(.top, 6)
                    ForEach(instance.lists) { list in
                        optionRow(
                            source: .list(list.id),
                            symbol: "checklist",
                            tint: Color(remindersTint: list.color),
                            title: list.title)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(NotchTokens.Text.system(9, weight: .semibold))
            .foregroundStyle(NotchTokens.Foreground.disabled)
            .padding(.bottom, 2)
    }

    private func optionRow(
        source: RemindersSource,
        symbol: String,
        tint: Color?,
        title: String
    ) -> some View {
        let isSelected = instance.source == source
        return Button {
            instance.updateSource(source)
            BlockPopover.shared.dismiss()
        } label: {
            HStack(spacing: 6) {
                leadingMark(symbol: symbol, tint: tint)
                Text(title)
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(
                        isSelected
                            ? NotchTokens.Foreground.selected
                            : NotchTokens.Foreground.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(NotchTokens.Text.system(9, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.body)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// 具体清单显**真实颜色**圆点；智能视图显语义符号。两者都占同一宽度槽，
    /// 让标题左缘对齐。
    @ViewBuilder
    private func leadingMark(symbol: String, tint: Color?) -> some View {
        ZStack {
            if let tint {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: symbol)
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
        }
        .frame(width: 14)
    }
}
