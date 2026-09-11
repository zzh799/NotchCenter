import NotchCenterKit
import SwiftUI

// MARK: - 库页调色板（`ClipboardColorParsing` 的 SwiftUI 桥接）
//
// 颜色条目的色板是**数据可视化语义色**（用户复制的色值本身），不属于
// NotchTokens 的"白 + alpha"层级，故收敛为插件本地单点（豁免理由同上，
// 与 SystemMonitor 的 MetricPresentation 方向色同族）。

enum ClipboardLibraryPalette {
    /// 文本 → SwiftUI Color；不可识别返回 nil。
    static func color(from text: String) -> Color? {
        guard let components = ClipboardColorParsing.components(from: text) else { return nil }
        return Color(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: components.alpha
        )
    }
}

// MARK: - 剪贴板库页（clipboard.library 大组件）
//
// 与抽屉块的关系：`clipboard.history` 是"随手取一条"（单行截断 + 悬浮角标搜索），
// 本块是"翻库"——常驻搜索框 + 置顶看板 + 类型筛选 + 全文预览。二者共用同一份
// `ClipboardHistoryStore.shared` 历史。
//
// 渲染走宿主 BlockCard + 宿主抽屉 ScrollView；列表自身是页内 ScrollView，
// 页不再被套一层。`.newPageWhenOccupied` 只是"添加那一刻"的落点偏好。
//
// 富媒体说明：本期只采集纯文本，图片/文件类型是预留位（见 ClipboardEntryKind），
// 筛选栏因此只列实际可出现的三种类型。

/// 库页布局常量：**视图与打包期探针的唯一真源**（探针按这些常量推导区带，
/// 改布局必须同步这里；见 `ClipboardHistoryPlugin.clipboardLibraryLayoutProbes`）。
enum ClipboardLibraryMetricsProbe {
    static let padding: CGFloat = 12
    /// 顶部搜索行高。
    static let searchRowHeight: CGFloat = 26
    /// 类型筛选行高。
    static let filterRowHeight: CGFloat = 22
    /// 置顶看板卡宽 / 卡高。
    static let pinnedCardWidth: CGFloat = 150
    static let pinnedCardHeight: CGFloat = 54
    /// 看板/列表区块标题的行高。
    static let sectionTitleHeight: CGFloat = 16
    /// 列表行高。
    static let rowHeight: CGFloat = 30
    /// 区块间距。
    static let sectionGap: CGFloat = 12
}

private typealias ClipboardLibraryMetrics = ClipboardLibraryMetricsProbe

struct ClipboardLibraryView: View {
    let context: BlockContext

    @ObservedObject private var store = ClipboardHistoryStore.shared

    @State private var query = ""
    @State private var selectedKinds: Set<ClipboardEntryKind> = []
    @FocusState private var searchFocused: Bool

    init(context: BlockContext) {
        self.context = context
    }

    private var isPreview: Bool { context.layoutInfo.isPreview }

    /// 筛选 + 搜索后的结果，再切置顶/最近两段。
    private var sections: (pinned: [ClipboardEntry], recent: [ClipboardEntry]) {
        let matched = ClipboardHistoryLogic.libraryFiltered(
            store.entries,
            query: query,
            kinds: selectedKinds
        )
        return ClipboardHistoryLogic.librarySections(matched)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClipboardLibraryMetrics.sectionGap) {
            searchRow
            filterRow
            content
        }
        .padding(ClipboardLibraryMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { visibilityProbeLayer }
        .onAppear {
            guard !isPreview else { return }
            ClipboardHistoryStore.shared.viewDidAppear(placementID: context.placementID)
        }
        .onDisappear {
            guard !isPreview else { return }
            ClipboardHistoryStore.shared.viewDidDisappear(placementID: context.placementID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("library.a11y"))
    }

    // MARK: 搜索与筛选

    /// 常驻搜索输入行（库页有空间，不做抽屉块那种"角标展开"）。
    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.muted)
            TextField(L("library.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(NotchTokens.Text.system(12))
                .foregroundStyle(NotchTokens.Foreground.body)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(NotchTokens.Text.system(11))
                        .foregroundStyle(NotchTokens.Foreground.disabled)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled(true)
                .help(L("library.search.clear"))
            }
            Spacer(minLength: 0)
            if store.isPaused {
                Text(L("drawer.paused.banner"))
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ClipboardLibraryMetrics.searchRowHeight)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .fill(NotchTokens.Surface.fill)
        )
    }

    /// 类型筛选 chip 行：点击切换，全不选 = 不过滤。
    private var filterRow: some View {
        HStack(spacing: 6) {
            ForEach(ClipboardEntryKind.collectable, id: \.self) { kind in
                filterChip(kind)
            }
            Spacer(minLength: 0)
            if !selectedKinds.isEmpty {
                Text(LF("library.filtered", selectedKinds.count))
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
        }
        .frame(height: ClipboardLibraryMetrics.filterRowHeight)
    }

    private func filterChip(_ kind: ClipboardEntryKind) -> some View {
        let isOn = selectedKinds.contains(kind)
        return Button {
            if isOn {
                selectedKinds.remove(kind)
            } else {
                selectedKinds.insert(kind)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kind.symbolName)
                    .font(NotchTokens.Text.system(9, weight: .medium))
                Text(L(kind.localizationKey))
                    .font(NotchTokens.Text.system(10, weight: .medium))
            }
            .foregroundStyle(isOn ? NotchTokens.Foreground.selected : NotchTokens.Foreground.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? NotchTokens.Surface.fillHighlighted : NotchTokens.Surface.fill)
            )
            .overlay(
                Capsule().strokeBorder(
                    isOn ? NotchTokens.Hairline.chipSelected : .clear,
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled(true)
        .help(L(kind.localizationKey))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: 内容（置顶看板 + 最近列表）

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            emptyState(title: L("library.empty.title"), hint: L("library.empty.hint"), symbol: "clipboard")
        } else if sections.pinned.isEmpty, sections.recent.isEmpty {
            emptyState(title: L("library.noMatch.title"), hint: L("library.noMatch.hint"), symbol: "magnifyingglass")
        } else {
            // 列表自管滚动（纵向内容可能超过页高）；页自身不被宿主以外的
            // ScrollView 包裹，这里是唯一一层。
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: ClipboardLibraryMetrics.sectionGap) {
                    if !sections.pinned.isEmpty {
                        pinnedBoard(sections.pinned)
                    }
                    recentList(sections.recent)
                }
                .padding(.bottom, 2)
            }
        }
    }

    /// 置顶看板：横向卡片行（标题 + 两行摘要），点击写回、长按预览全文。
    private func pinnedBoard(_ entries: [ClipboardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("library.section.pinned"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(entries) { entry in
                        pinnedCard(entry)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pinnedCard(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: entry.kind.symbolName)
                    .font(NotchTokens.Text.system(9, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Spacer(minLength: 0)
                Button {
                    store.togglePin(id: entry.id)
                } label: {
                    Image(systemName: "pin.fill")
                        .font(NotchTokens.Text.system(9, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.body)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled(true)
                .help(L("drawer.button.unpin"))
            }
            Text(entry.text)
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.body)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(width: ClipboardLibraryMetrics.pinnedCardWidth,
               height: ClipboardLibraryMetrics.pinnedCardHeight,
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(NotchTokens.Surface.fillHighlighted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .strokeBorder(NotchTokens.Hairline.drawerEdge, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .blockPopoverTrigger(
            onTap: { _ in store.copyBack(entry) },
            onLongPress: { frame in presentPreview(frame, entry: entry) },
            cornerRadius: NotchTokens.Radius.chip
        )
        .contextMenu {
            Button(L("drawer.button.unpin")) { store.togglePin(id: entry.id) }
            Button(L("drawer.button.delete")) { store.delete(id: entry.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(entry.text))
    }

    /// 最近列表：单行截断，行尾置顶/删除；点击写回、长按预览。
    private func recentList(_ entries: [ClipboardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entries.isEmpty {
                sectionTitle(L("library.section.recent"))
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        recentRow(entry)
                        if index < entries.count - 1 {
                            Rectangle()
                                .fill(NotchTokens.Hairline.divider)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.symbolName)
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.placeholder)
                .frame(width: 14)
            if let swatch = colorSwatch(for: entry) {
                RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                    .fill(swatch)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                            .strokeBorder(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
                    )
            }
            Text(entry.text)
                .font(NotchTokens.Text.system(11.5))
                .foregroundStyle(NotchTokens.Foreground.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if store.justCopiedID == entry.id {
                Image(systemName: "checkmark")
                    .font(NotchTokens.Text.system(9, weight: .semibold))
                    .foregroundStyle(NotchTokens.Semantic.accentGreen)
            }
            HStack(spacing: 2) {
                rowIconButton(
                    systemName: entry.pinned ? "pin.fill" : "pin",
                    isActive: entry.pinned,
                    help: entry.pinned ? L("drawer.button.unpin") : L("drawer.button.pin")
                ) {
                    store.togglePin(id: entry.id)
                }
                rowIconButton(systemName: "trash", help: L("drawer.button.delete")) {
                    store.delete(id: entry.id)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: ClipboardLibraryMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .fill(store.justCopiedID == entry.id ? NotchTokens.Surface.fillHighlighted : .clear)
        )
        .contentShape(Rectangle())
        .blockPopoverTrigger(
            onTap: { _ in store.copyBack(entry) },
            onLongPress: { frame in presentPreview(frame, entry: entry) },
            cornerRadius: NotchTokens.Radius.button
        )
        .contextMenu {
            Button(entry.pinned ? L("drawer.button.unpin") : L("drawer.button.pin")) {
                store.togglePin(id: entry.id)
            }
            Button(L("drawer.button.delete")) { store.delete(id: entry.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(entry.text))
    }

    private func rowIconButton(
        systemName: String,
        isActive: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(isActive ? NotchTokens.Foreground.body : NotchTokens.Foreground.disabled)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled(true)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // MARK: 长按全文预览

    private func presentPreview(_ frameInWindow: CGRect, entry: ClipboardEntry) {
        BlockPopover.shared.present(
            anchoredTo: frameInWindow,
            cardSize: CGSize(width: 300, height: 220)
        ) {
            ClipboardLibraryPreviewCard(entry: entry)
        }
    }

    /// 颜色条目的色板解出（`#RRGGBB` / `#RGB` / `rgb(...)`）；非颜色返回 nil。
    private func colorSwatch(for entry: ClipboardEntry) -> Color? {
        guard entry.kind == .color else { return nil }
        return ClipboardLibraryPalette.color(from: entry.text)
    }

    // MARK: 基元

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(NotchTokens.Text.system(11, weight: .semibold))
            .foregroundStyle(NotchTokens.Foreground.secondary)
            .frame(height: ClipboardLibraryMetrics.sectionTitleHeight, alignment: .leading)
    }

    private func emptyState(title: String, hint: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system(20, weight: .light))
                .foregroundStyle(NotchTokens.Foreground.disabled)
            Text(title)
                .font(NotchTokens.Text.system(12, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(hint)
                .font(NotchTokens.Text.system(10.5))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var visibilityProbeLayer: some View {
        if !isPreview {
            ClipboardVisibilityProbe(
                onAttach: { windowID, isVisible in
                    ClipboardHistoryStore.shared.probeAttached(windowID: windowID, isVisible: isVisible)
                },
                onDetach: { windowID in
                    ClipboardHistoryStore.shared.probeDetached(windowID: windowID)
                },
                onVisibilityChange: { windowID, isVisible in
                    ClipboardHistoryStore.shared.probeVisibilityChanged(windowID: windowID, isVisible: isVisible)
                }
            )
            .frame(width: 0, height: 0)
        }
    }
}

/// 库页长按预览：全文 + 色块（颜色条目）+ 内嵌滚动 + 可选中复制。
private struct ClipboardLibraryPreviewCard: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: entry.kind.symbolName)
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(L(entry.kind.localizationKey))
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Spacer(minLength: 0)
                if let swatch = ClipboardLibraryPalette.color(from: entry.text) {
                    RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                        .fill(swatch)
                        .frame(width: 16, height: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                                .strokeBorder(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
                        )
                }
            }
            ScrollView(.vertical) {
                Text(entry.text)
                    .font(NotchTokens.Text.system(11.5))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}
