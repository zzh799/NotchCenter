import SwiftUI

/// Single source of truth for the tab-dot pager metrics. NotebookView's
/// tabRowCount estimates wrapped rows with these exact numbers while
/// TabPagerControl/WrappingHStack lay out with them; changing one side without
/// the other desyncs the toolbar height estimate from the real layout.
enum TabDotMetrics {
    static let itemWidth: CGFloat = 26
    static let itemHeight: CGFloat = 24
    static let horizontalSpacing: CGFloat = 6
    static let verticalSpacing: CGFloat = 4
    /// Combined top+bottom padding of TabPagerControl (2pt each side).
    static let verticalPadding: CGFloat = 4
    /// Trailing width reserved inside the pager for the add-tab plus button.
    static let plusButtonReservedWidth: CGFloat = 34
    /// Floor for the wrapping width so tiny windows still wrap sanely.
    static let minWrapWidth: CGFloat = 160
}

struct TabPagerControl: View {
    @ObservedObject var store: NoteStore
    let editorInteractionState: EditorInteractionState
    let availableWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            WrappingHStack(
                availableWidth: dotWrapAvailableWidth,
                horizontalSpacing: TabDotMetrics.horizontalSpacing,
                verticalSpacing: TabDotMetrics.verticalSpacing
            ) {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == store.activeTabID
                    Button {
                        rememberCurrentSelection()
                        withAnimation(tabSwitchAnimation) {
                            store.selectTab(tab.id)
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
                        .frame(width: TabDotMetrics.itemWidth, height: TabDotMetrics.itemHeight)
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

            Button {
                rememberCurrentSelection()
                withAnimation(tabSwitchAnimation) {
                    store.addTab()
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabIconButtonStyle())
            .fixedSize()
            .help("New note")
            .accessibilityLabel("New note")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Wrap width for the dot row, mirroring NotebookView.tabRowCount.
    private var dotWrapAvailableWidth: CGFloat {
        max(availableWidth - TabDotMetrics.plusButtonReservedWidth, TabDotMetrics.minWrapWidth)
    }

    private var tabSwitchAnimation: Animation {
        .spring(response: 0.26, dampingFraction: 0.82)
    }

    private func rememberCurrentSelection() {
        guard let range = editorInteractionState.currentSelectionRange() else { return }
        store.updateSelection(for: store.activeTabID, range: range)
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
