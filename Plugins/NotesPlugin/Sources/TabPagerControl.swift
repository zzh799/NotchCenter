import NotchCenterKit
import SwiftUI

struct TabPagerControl: View {
    @ObservedObject var store: NotesStore
    let activeTabID: UUID
    let editorInteractionState: EditorInteractionState
    let onSelectTab: (UUID) -> Void
    /// 圆点换行可用的宽度：块宽扣掉两侧内容内边距**与右上角悬浮新建角标的槽位**
    /// （角标见 `NotesBlockView`）。槽位恒留——角标只在悬浮时进视图树，若让圆点
    /// 铺满整行，悬浮瞬间圆点就被浮动角标压住（同「角标必须落在自身命中区内」的
    /// 教训，见抽屉分页文档）。
    let availableWidth: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // 页面指示器圆点（多标签时自动换行，与旧行为一致）
            WrappingHStack(
                availableWidth: availableWidth,
                horizontalSpacing: 6,
                verticalSpacing: 4
            ) {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == activeTabID
                    Button {
                        editorInteractionState.commitSelection(to: store, tabID: activeTabID)
                        withAnimation(tabSwitchAnimation) {
                            onSelectTab(tab.id)
                        }
                    } label: {
                        ZStack {
                            if isSelected {
                                Circle()
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 14, height: 14)
                            }

                            Circle()
                                .fill(isSelected ? NotchTokens.Foreground.body : NotchTokens.Foreground.unavailable)
                                .frame(width: isSelected ? 7 : 6, height: isSelected ? 7 : 6)
                                .shadow(color: .white.opacity(isSelected ? 0.42 : 0), radius: 3)
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .animation(tabSwitchAnimation, value: isSelected)
                    }
                    .buttonStyle(TabDotButtonStyle(isSelected: isSelected))
                    .help(store.title(for: tab.id))
                    .accessibilityLabel(
                        isSelected
                            ? LF("notes.tab.current", store.title(for: tab.id))
                            : LF("notes.tab.open", store.title(for: tab.id))
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            editorInteractionState.commitSelection(to: store, tabID: activeTabID)
                            withAnimation(tabSwitchAnimation) {
                                store.removeTab(tab.id)
                            }
                        } label: {
                            Label(L("notes.deleteTab"), systemImage: "trash")
                        }
                        .disabled(store.tabs.count <= 1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var tabSwitchAnimation: Animation {
        NotchTokens.Motion.tabSwitch
    }
}

private struct WrappingHStack: Layout {
    let availableWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = layoutSubviews(in: availableWidth, subviews: subviews)
        return CGSize(width: availableWidth, height: result.size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layoutSubviews(in: min(bounds.width, availableWidth), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func layoutSubviews(
        in availableWidth: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            origins.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }

        return (
            CGSize(width: contentWidth, height: y + rowHeight),
            origins
        )
    }
}
