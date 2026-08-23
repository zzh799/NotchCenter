import SwiftUI

struct TabPagerControl: View {
    @ObservedObject var store: NotesStore
    let activeTabID: UUID
    let editorInteractionState: EditorInteractionState
    let onSelectTab: (UUID) -> Void
    /// 新建笔记入口：由所属块实例提供（创建 + 定向记忆 + 挂起焦点），返回新标签 ID。
    let onCreateNote: () -> UUID
    let availableWidth: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // 左侧：页面指示器圆点（多标签时自动换行，与旧行为一致）
            WrappingHStack(
                availableWidth: max(availableWidth - 34, 160),
                horizontalSpacing: 6,
                verticalSpacing: 4
            ) {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == activeTabID
                    Button {
                        rememberCurrentSelection()
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
                                .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.34))
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
                            ? "Current note: \(store.title(for: tab.id))"
                            : "Open note: \(store.title(for: tab.id))"
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            rememberCurrentSelection()
                            withAnimation(tabSwitchAnimation) {
                                store.removeTab(tab.id)
                            }
                        } label: {
                            Label("Delete This Note", systemImage: "trash")
                        }
                        .disabled(store.tabs.count <= 1)
                    }
                }
            }

            Spacer(minLength: 0)

            // 右侧：新建按钮
            Button {
                rememberCurrentSelection()
                let newTabID = onCreateNote()
                withAnimation(tabSwitchAnimation) {
                    onSelectTab(newTabID)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New note")
            .accessibilityLabel("New note")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var tabSwitchAnimation: Animation {
        .spring(response: 0.26, dampingFraction: 0.82)
    }

    private func rememberCurrentSelection() {
        guard let range = editorInteractionState.currentSelectionRange() else { return }
        store.updateSelection(for: activeTabID, range: range)
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
