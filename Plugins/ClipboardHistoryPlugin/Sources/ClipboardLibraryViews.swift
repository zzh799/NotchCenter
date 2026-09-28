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
// 富媒体说明：五类都已可采集（决策记录 2026-09-20-clipboard-media-types），筛选栏
// 列全五类。图标-only 的 chip 是**宽度约束逼出来的**——`minSize` 宽 300、内边距
// 12×2，内容只有 276pt，五个"图标 + 文字"的 chip 放不下（英文文案更多）。

/// 库页布局常量：**视图与打包期探针的唯一真源**（探针按这些常量推导区带，
/// 改布局必须同步这里；见 `ClipboardHistoryPlugin.clipboardLibraryLayoutProbes`）。
///
/// 行高与缩略图尺寸**不在此列**：列表行高与抽屉块共用 `ClipboardRowMetrics`，
/// 且它不进探针（列表在块内自管滚动），混进来会传下去"改行高也要动探针"的假约束。
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
    /// 区块间距。
    static let sectionGap: CGFloat = 12
}

private typealias ClipboardLibraryMetrics = ClipboardLibraryMetricsProbe

struct ClipboardLibraryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared

    @State private var query = ""
    @State private var selectedKinds: Set<ClipboardEntryKind> = []
    @FocusState private var searchFocused: Bool
    /// 悬浮预览的计时与目标（组件见 `ClipboardHoverPreview.swift`）。
    @StateObject private var hover = ClipboardHoverPreviewModel()

    /// 抽屉展开态。只用于收起时收掉悬浮卡（`hover.cancel()`）；采集不依赖它——
    /// 轮询随插件启停常驻（见 ClipboardPoller）。
    @Environment(\.isDrawerPresented) private var isDrawerPresented

    /// 筛选 + 搜索后的结果，再切置顶/最近两段。
    private var sections: (pinned: [ClipboardEntry], recent: [ClipboardEntry]) {
        let matched = ClipboardHistoryLogic.libraryFiltered(
            store.entries,
            query: query,
            kinds: selectedKinds
        )
        // 诊断压帽：库页渲染全部条目（不受实例显示条数约束），归因量测要能从
        // 外部把行数压下来，才能把"行数"与"块面积"两个自变量分开。
        return ClipboardHistoryLogic.librarySections(
            ClipboardHistoryLogic.applyingRowCap(matched)
        )
    }

    var body: some View {
        // 派生结果只算一次：`sections` 是计算属性，在 body 里多次访问会让一次渲染
        // 重复跑多轮「类型筛选 + 大小写不敏感全库扫描」。
        let sections = self.sections
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: ClipboardLibraryMetrics.sectionGap) {
                searchRow
                filterRow
                content(sections)
            }
            hoverPreviewLayer
        }
        // 行与浮层共用这个名字空间：行的 hover 报出的光标位置直接就是浮层的摆放基准。
        .coordinateSpace(name: ClipboardHoverSpace.list)
        .padding(ClipboardLibraryMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: isDrawerPresented) { _, presented in
            // 抽屉收起后视图树仍在（温存），悬浮卡必须跟着"用户看不见了"这个事实收掉。
            if !presented { hover.cancel() }
        }
        // 列表内容一变，光标底下换的可能是另一条：收起比留在旧内容上诚实。
        .onChange(of: query) { _, _ in hover.cancel() }
        .onChange(of: selectedKinds) { _, _ in hover.cancel() }
        .onChange(of: store.entries) { _, _ in hover.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("library.a11y"))
    }

    /// 悬浮预览层。挂在块内容盒里而不是走 `BlockPopover`：零窗口开销，且由构造保证
    /// 不可能越出块矩形——卡片伸出抽屉可见矩形会让光标"离开停留区"，抽屉被收起
    /// （见 `BlockPopover.cardInset` 那段注释）。理由与抽屉块同源。
    @ViewBuilder
    private var hoverPreviewLayer: some View {
        // 条目可能在这期间被删掉：shown 里存的是值的副本，不核对会留下一张"幽灵卡"。
        if let target = hover.shown, store.entries.contains(where: { $0.id == target.entry.id }) {
            ClipboardHoverPreviewLayer(
                target: target,
                thumbnailURL: store.thumbnailURL(for: target.entry)
            )
        }
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
    ///
    /// `ViewThatFits` 在两种排布里挑最富的一种——够宽时选中项展开成"图标 + 文字"，
    /// 不够宽时全部退回纯图标。不做横向滚动：宿主把抽屉的横向滑动用作切页手势，
    /// 被筛选行消费掉会打架（README 里那条"纵向列表不消费横向滑动"同理）。
    private var filterRow: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                chipStrip(showsLabels: true)
                chipStrip(showsLabels: false)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if !selectedKinds.isEmpty {
                Text(LF("library.filtered", selectedKinds.count))
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .lineLimit(1)
            }
        }
        .frame(height: ClipboardLibraryMetrics.filterRowHeight)
    }

    private func chipStrip(showsLabels: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(ClipboardEntryKind.collectable, id: \.self) { kind in
                filterChip(kind, showsLabels: showsLabels)
            }
        }
    }

    private func filterChip(_ kind: ClipboardEntryKind, showsLabels: Bool) -> some View {
        let isOn = selectedKinds.contains(kind)
        // 未选中一律只给图标；文字只在"够宽"且"已选中"时出现，用来回答
        // "我到底筛了哪几个"——纯图标靠悬停猜太慢。
        let showsText = showsLabels && isOn
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
                if showsText {
                    Text(L(kind.localizationKey))
                        .font(NotchTokens.Text.system(10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
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
    private func content(_ sections: (pinned: [ClipboardEntry], recent: [ClipboardEntry])) -> some View {
        if ClipboardHistoryLogic.diagnosticMode == .contentOff {
            // 诊断：摘掉列表/看板物化，只留块壳（见 DiagnosticMode 注释）。
            emptyState(title: L("library.empty.title"), hint: L("library.empty.hint"), symbol: "clipboard")
        } else if store.entries.isEmpty {
            emptyState(title: L("library.empty.title"), hint: L("library.empty.hint"), symbol: "clipboard")
        } else if sections.pinned.isEmpty, sections.recent.isEmpty {
            emptyState(title: L("library.noMatch.title"), hint: L("library.noMatch.hint"), symbol: "magnifyingglass")
        } else {
            // 列表自管滚动（纵向内容可能超过页高）；页自身不被宿主以外的
            // ScrollView 包裹，这里是唯一一层。区块也扁平进 `LazyVStack`
            // （`ForEach` 对容器透明），滚动到页底时才物化下方区块。
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: ClipboardLibraryMetrics.sectionGap) {
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
    /// 卡宽卡高固定，`LazyHStack` 因此只物化横向视口内的卡片。
    private func pinnedBoard(_ entries: [ClipboardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("library.section.pinned"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
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
        let copyFailed = store.copyFailedID == entry.id
        // 持续高亮（见 `ClipboardHistoryStore.currentClipboardEntryID`）：卡片底色
        // 常显 fillHighlighted、无处再亮，改用选中描边表达（与筛选 chip 选中态同款）。
        let isCurrent = store.currentClipboardEntryID == entry.id
        return VStack(alignment: .leading, spacing: 4) {
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
            if entry.kind == .image {
                HStack(spacing: 6) {
                    ClipboardImageView(
                        url: store.thumbnailURL(for: entry),
                        width: ClipboardRowMetrics.thumbnailWidth,
                        height: ClipboardRowMetrics.thumbnailHeight,
                        contentMode: .fill
                    )
                    Text(L("library.kind.image"))
                        .font(NotchTokens.Text.system(10))
                        .foregroundStyle(NotchTokens.Foreground.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(ClipboardHistoryLogic.diagnosticText(ClipboardEntryPresentation.displayText(for: entry)))
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(copyFailed ? NotchTokens.Foreground.disabled : NotchTokens.Foreground.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                .strokeBorder(
                    copyFailed ? NotchTokens.Semantic.unavailable
                        : isCurrent ? NotchTokens.Hairline.chipSelected
                        : NotchTokens.Hairline.drawerEdge,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .blockPopoverTrigger(
            onTap: { _ in
                hover.cancel()
                store.copyBack(entry)
            },
            onLongPress: { frame in
                // 长按期间光标静止，不停掉计时的话悬浮卡会在浮窗背后同时长出来。
                hover.cancel()
                presentPreview(frame, entry: entry)
            },
            cornerRadius: NotchTokens.Radius.chip
        )
        .onContinuousHover(coordinateSpace: .named(ClipboardHoverSpace.list)) { phase in
            switch phase {
            case .active(let location): hover.hover(entry: entry, at: location)
            case .ended: hover.end(entry: entry)
            }
        }
        .contextMenu {
            Button(L("drawer.button.unpin")) { store.togglePin(id: entry.id) }
            Button(L("drawer.button.delete")) { store.delete(id: entry.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ClipboardEntryPresentation.accessibilityLabel(for: entry, section: .pinned)))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// 最近列表：单行截断，行尾置顶/删除；点击写回、长按预览。
    /// 行高固定（`rowHeight`）——`LazyVStack` 无需测量全部行即可排布，只物化视口内的行。
    private func recentList(_ entries: [ClipboardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entries.isEmpty {
                sectionTitle(L("library.section.recent"))
                LazyVStack(spacing: 0) {
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
        let copyFailed = store.copyFailedID == entry.id
        // 持续高亮：本条内容等于当前剪贴板内容（状态追踪，见
        // `ClipboardHistoryStore.currentClipboardEntryID`），不是点击反馈。
        let isCurrent = store.currentClipboardEntryID == entry.id
        return HStack(spacing: 8) {
            if entry.kind == .image {
                ClipboardImageView(
                    url: store.thumbnailURL(for: entry),
                    width: ClipboardRowMetrics.thumbnailWidth,
                    height: ClipboardRowMetrics.thumbnailHeight,
                    contentMode: .fill
                )
            } else {
                Image(systemName: entry.kind.symbolName)
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.placeholder)
                    .frame(width: 14)
            }
            if let swatch = colorSwatch(for: entry) {
                RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                    .fill(swatch)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                            .strokeBorder(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
                    )
            }
            Text(ClipboardHistoryLogic.diagnosticText(ClipboardEntryPresentation.displayText(for: entry)))
                .font(NotchTokens.Text.system(11.5))
                .foregroundStyle(copyFailed ? NotchTokens.Foreground.disabled : NotchTokens.Foreground.body)
                .lineLimit(1)
                .truncationMode(entry.kind == .file ? .middle : .tail)
            Spacer(minLength: 6)
            if copyFailed {
                Text(L("drawer.copy.failed"))
                    .font(NotchTokens.Text.system(9.5, weight: .medium))
                    .foregroundStyle(NotchTokens.Semantic.unavailable)
                    .lineLimit(1)
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
        .frame(height: ClipboardRowMetrics.height(for: entry))
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .fill(isCurrent ? NotchTokens.Surface.fillHighlighted : .clear)
        )
        .contentShape(Rectangle())
        .blockPopoverTrigger(
            onTap: { _ in
                hover.cancel()
                store.copyBack(entry)
            },
            onLongPress: { frame in
                hover.cancel()
                presentPreview(frame, entry: entry)
            },
            cornerRadius: NotchTokens.Radius.button
        )
        .onContinuousHover(coordinateSpace: .named(ClipboardHoverSpace.list)) { phase in
            switch phase {
            case .active(let location): hover.hover(entry: entry, at: location)
            case .ended: hover.end(entry: entry)
            }
        }
        .contextMenu {
            Button(entry.pinned ? L("drawer.button.unpin") : L("drawer.button.pin")) {
                store.togglePin(id: entry.id)
            }
            Button(L("drawer.button.delete")) { store.delete(id: entry.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ClipboardEntryPresentation.accessibilityLabel(for: entry, section: .recent)))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
            ClipboardLibraryPreviewCard(
                entry: entry,
                imageURL: store.thumbnailURL(for: entry)
            )
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

}

/// 库页长按预览：图片给原图（不裁切），其余给全文 + 色块（颜色条目）+ 内嵌滚动 + 可选中复制。
private struct ClipboardLibraryPreviewCard: View {
    let entry: ClipboardEntry
    let imageURL: URL?

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
            if entry.kind == .image {
                ClipboardImageView(url: imageURL, width: 256, height: 160, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical) {
                    Text(entry.text)
                        .font(NotchTokens.Text.system(11.5))
                        .foregroundStyle(NotchTokens.Foreground.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
    }
}
