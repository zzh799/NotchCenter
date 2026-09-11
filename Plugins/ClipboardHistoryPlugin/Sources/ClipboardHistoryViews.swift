import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（搜索按钮 + 置顶区 + 最近列表）
//
// 交互（2026-09-06 重构，推翻原共识 Q8/Q9，见 agent-note 同日记录）：
// 条目主体点击 = 写回剪贴板（单行截断显示），长按 = BlockPopover 全文预览浮窗；
// 「置顶 / 删除」图标按钮同行放行尾。清空经卡片内 InlineConfirmOverlay 浮层
// 确认——模态弹窗抢焦点，鼠标移过去抽屉就会收回。
// 顶部「搜索 / 清空」两颗组件默认圆形按钮（Kit IconCircleButton，与编辑模式
// 角标同一外观）默认隐藏、鼠标悬浮组件才显示，左搜索、右清空对称镜像编辑
// 模式的左上齿轮 / 右上移除；不占整行输入框——纵向空间全让给剪贴条目。
// 点搜索角标才展开输入行（行首同款搜索钮兼任收起，收起时清空查询）。
// 置顶 / 最近分组不设文字标题：组界画细线表达，条目置顶态由行尾按钮选中态表达，
// 分组语义走节容器 accessibilityLabel。
// 历史来自共享单例，显示偏好（条数）来自本 placement 的实例模型。

struct ClipboardHistoryBlockView: View {
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var instance: ClipboardInstanceModel
    let placementID: String
    let isPreview: Bool

    @State private var query = ""
    @State private var isSearchExpanded = false
    @State private var isHovering = false
    @State private var confirmingClear = false
    @FocusState private var searchFocused: Bool

    /// 抽屉是否展开。温存让 `onDisappear` 不再表示"用户看不到了"，而"被观察"
    /// 语义（决定轮询表起停）必须跟着真实可见性走。
    @Environment(\.isDrawerPresented) private var isDrawerPresented

    init(instance: ClipboardInstanceModel, placementID: String, isPreview: Bool) {
        self.store = ClipboardHistoryStore.shared
        self.instance = instance
        self.placementID = placementID
        self.isPreview = isPreview
    }

    var body: some View {
        BlockCard(hoverEffect: false) { _ in
            VStack(spacing: 0) {
                if isSearchExpanded {
                    searchInputRow
                }
                if store.isPaused {
                    pausedBanner
                }
                listContent
            }
            .animation(NotchTokens.Motion.hover, value: isSearchExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            visibilityProbeLayer
        }
        // 搜索 / 清空角标：与编辑模式角标同一交互——默认隐藏，鼠标悬浮组件才显示；
        // 左搜索、右清空，对称镜像编辑模式的左上齿轮 / 右上移除。搜索展开时隐藏。
        .overlay(alignment: .topLeading) {
            if isHovering, !isSearchExpanded {
                searchButton
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovering, !isSearchExpanded {
                clearAllButton
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .onAppear { syncObservation(presented: isDrawerPresented) }
        .onDisappear { syncObservation(presented: false) }
        .onChange(of: isDrawerPresented) { _, presented in
            syncObservation(presented: presented)
        }
        // 焦点移出（点击条目 / 其他区域 / 收起按钮）即收起搜索，输入行不悬空。
        .onChange(of: searchFocused) { _, focused in
            if !focused {
                collapseSearch()
            }
        }
        .overlay {
            if confirmingClear {
                InlineConfirmOverlay(
                    title: L("drawer.clear.title"),
                    message: L("drawer.clear.message"),
                    confirmTitle: L("drawer.clear.confirm"),
                    cancelTitle: L("drawer.clear.cancel"),
                    onConfirm: {
                        store.clearUnpinned()
                        confirmingClear = false
                    },
                    onCancel: { confirmingClear = false }
                )
            }
        }
        .animation(NotchTokens.Motion.hover, value: confirmingClear)
        .animation(NotchTokens.Motion.hover, value: isHovering)
        .colorScheme(.dark)
    }

    /// 列表区三态（空历史 / 搜索无果 / 列表）：抽出独立计算属性，给类型检查器减负。
    @ViewBuilder
    private var listContent: some View {
        if ClipboardHistoryLogic.diagnosticMode == .contentOff {
            // 诊断：摘掉行物化，只留块壳（见 DiagnosticMode 注释）。
            emptyState
        } else if store.entries.isEmpty {
            emptyState
        } else if displayedEntries.isEmpty {
            searchEmptyState
        } else {
            historyList
        }
    }

    @ViewBuilder
    private var visibilityProbeLayer: some View {
        // 可见性探针：isPreview 副本不插（预览层随时整层消失，不得认领共享状态）。
        if !isPreview, ClipboardHistoryLogic.diagnosticMode != .probeOff {
            ClipboardVisibilityProbe(
                onAttach: { windowID, isVisible in
                    store.probeAttached(windowID: windowID, isVisible: isVisible)
                },
                onDetach: { windowID in
                    store.probeDetached(windowID: windowID)
                },
                onVisibilityChange: { windowID, isVisible in
                    store.probeVisibilityChanged(windowID: windowID, isVisible: isVisible)
                }
            )
            .frame(width: 0, height: 0)
        }
    }

    /// 拍平后的展示条目（分组仅由 historyList 用细线与节容器 a11y 标签表达）。
    private var displayedEntries: [ClipboardEntry] {
        displayedSections.flatMap(\.entries)
    }

    // MARK: 派生数据

    /// 按置顶 / 最近分区、经搜索过滤、按实例条数截断后的展示节。
    private var displayedSections: [ClipboardSection] {
        let filtered = ClipboardHistoryLogic.filtered(store.entries, query: query)
        // 诊断压帽与实例配置取小：只改"物化多少行"，不动分区与排序语义。
        let limit = ClipboardHistoryLogic.effectiveDisplayCount(instance.config.displayCount)
        let pinned = filtered.filter(\.pinned)
        let plain = filtered.filter { !$0.pinned }
        var sections: [ClipboardSection] = []
        if !pinned.isEmpty {
            sections.append(ClipboardSection(kind: .pinned, entries: Array(pinned.prefix(limit))))
        }
        // 置顶已占去 k 位时，最近区补 (limit - k) 位，避免超长。
        let remaining = max(limit - min(pinned.count, limit), 0)
        if !plain.isEmpty, remaining > 0 {
            sections.append(ClipboardSection(kind: .recent, entries: Array(plain.prefix(remaining))))
        }
        return sections
    }

    // MARK: 顶部工具行（角标按钮 + 搜索输入行）

    /// 搜索展开时的输入行：行首同款圆形搜索钮兼任收起（收起即清空查询，避免
    /// 「过滤已生效但输入框不可见」的困惑）；焦点移出（点击条目 / 其他区域）
    /// 也会自动收起，见 body 的 onChange(of: searchFocused)。行尾清空按钮在
    /// 展开期间由右上角角标隐藏，输入行不重复放置，保持与折叠态同一颗按钮的语义。
    private var searchInputRow: some View {
        HStack(spacing: 6) {
            IconCircleButton(
                systemImage: "magnifyingglass",
                helpText: L("drawer.button.search.collapse")
            ) {
                collapseSearch()
            }
            TextField(L("drawer.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(NotchTokens.Text.system(12))
                .foregroundStyle(NotchTokens.Foreground.body)
                .focused($searchFocused)
                // 展开后立即可输入（面板 canBecomeKey，见 PanelWindows.swift）。
                .onAppear { searchFocused = true }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(NotchTokens.Text.system(12))
                        .foregroundStyle(NotchTokens.Foreground.disabled)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 搜索角标（左上角）：默认隐藏、悬浮显示；按下展开输入行。
    private var searchButton: some View {
        IconCircleButton(
            systemImage: "magnifyingglass",
            helpText: L("drawer.button.search")
        ) {
            isSearchExpanded = true
        }
    }

    /// 清空角标（右上角）：默认隐藏、悬浮显示；组件默认圆形按钮样式，
    /// 禁用态（全为置顶）置灰。
    private var clearAllButton: some View {
        IconCircleButton(
            systemImage: "trash",
            helpText: L("menu.clear")
        ) {
            confirmingClear = true
        }
        .disabled(store.entries.allSatisfy { $0.pinned })
        .opacity(store.entries.allSatisfy { $0.pinned } ? 0.35 : 1)
    }

    private func collapseSearch() {
        isSearchExpanded = false
        query = ""
        searchFocused = false
    }

    /// 按真实可见性登记/注销本实例（幂等，收起与卸载会各来一次）。
    private func syncObservation(presented: Bool) {
        guard !isPreview else { return }
        let placement = placementID
        if presented {
            store.viewDidAppear(placementID: placement)
        } else {
            store.viewDidDisappear(placementID: placement)
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .font(NotchTokens.Text.system(11, weight: .medium))
            Text(L("drawer.paused.banner"))
                .font(NotchTokens.Text.system(11, weight: .medium))
        }
        .foregroundStyle(NotchTokens.Foreground.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(NotchTokens.Surface.fillHover)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(NotchTokens.Text.system(22, weight: .light))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(0.07)))
            Text(L("drawer.empty.title"))
                .font(NotchTokens.Text.system(12, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(L("drawer.empty.hint"))
                .font(NotchTokens.Text.system(10.5))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(NotchTokens.Text.system(18, weight: .light))
                .foregroundStyle(NotchTokens.Foreground.unavailable)
            Text(L("drawer.search.empty"))
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.disabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView(.vertical) {
            // 普通 VStack 而非 LazyVStack:置顶/解顶会让同一 id 在两个分区
            // ForEach 容器间移动,LazyVStack 复用已物化的同 id 视图但不重刷
            // 内容(按钮停在旧态,重开抽屉才纠正);列表至多 50 条,惰性无收益。
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(displayedSections.enumerated()), id: \.element.id) { index, section in
                    ClipboardSectionView(
                        section: section,
                        showsTopDivider: index > 0,
                        justCopiedID: store.justCopiedID,
                        onCopy: { store.copyBack($0) },
                        onTogglePin: { store.togglePin(id: $0.id) },
                        onDelete: { store.delete(id: $0.id) }
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// 展示分区（具名 Identifiable，避免匿名元组拖慢类型检查）。
private enum ClipboardSectionKind: Hashable {
    case pinned
    case recent

    /// 视觉上已不用文字标题，仅供节容器 accessibilityLabel 复用。
    var titleKey: String {
        self == .pinned ? "drawer.section.pinned" : "drawer.section.recent"
    }
}

private struct ClipboardSection: Identifiable {
    var id: ClipboardSectionKind { kind }
    let kind: ClipboardSectionKind
    let entries: [ClipboardEntry]
}

/// 单节渲染（组间细线 + 行列表），从 historyList 抽出给类型检查器减负。
private struct ClipboardSectionView: View {
    let section: ClipboardSection
    let showsTopDivider: Bool
    let justCopiedID: UUID?
    let onCopy: (ClipboardEntry) -> Void
    let onTogglePin: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void

    var body: some View {
        Group {
            if showsTopDivider {
                // 置顶组与最近组的组界发丝线（DESIGN.md §2.3 分隔线基准）。
                Rectangle()
                    .fill(NotchTokens.Hairline.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                    .accessibilityHidden(true)
            }
            ForEach(section.entries) { entry in
                ClipboardRowView(
                    entry: entry,
                    justCopied: justCopiedID == entry.id,
                    onCopy: { onCopy(entry) },
                    onTogglePin: { onTogglePin(entry) },
                    onDelete: { onDelete(entry) }
                )
                .padding(.horizontal, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L(section.kind.titleKey)))
    }
}

// MARK: - 历史行（主体点击写回 + 长按浮窗预览，操作按钮同行）

private struct ClipboardRowView: View {
    let entry: ClipboardEntry
    let justCopied: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if justCopied {
                    Image(systemName: "checkmark")
                        .font(NotchTokens.Text.system(9, weight: .semibold))
                        .foregroundStyle(NotchTokens.Semantic.accentGreen)
                        .accessibilityLabel(Text(L("drawer.button.copied")))
                }
                Text(ClipboardHistoryLogic.diagnosticText(entry.text))
                    .font(NotchTokens.Text.system(11.5))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                iconButton(
                    systemName: entry.pinned ? "pin.fill" : "pin",
                    isActive: entry.pinned,
                    help: entry.pinned ? L("drawer.button.unpin") : L("drawer.button.pin"),
                    action: onTogglePin
                )
                iconButton(
                    systemName: "trash",
                    help: L("drawer.button.delete"),
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .fill(justCopied ? NotchTokens.Surface.fillHighlighted : NotchTokens.Surface.fill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .strokeBorder(NotchTokens.Hairline.drawerEdge, lineWidth: 1)
        }
        .animation(NotchTokens.Motion.hover, value: justCopied)
        // 主体点击 = 写回、长按 = 全文预览：单手势管线（blockPopoverTrigger，
        // TapGesture 与长按并存真机不触发的红线结论），行尾图标按钮自行消费点击。
        .blockPopoverTrigger(
            onTap: { _ in onCopy() },
            onLongPress: { frame in presentPreview(frame) },
            cornerRadius: NotchTokens.Radius.button
        )
        .contextMenu {
            Button(entry.pinned ? L("drawer.button.unpin") : L("drawer.button.pin"), action: onTogglePin)
            Button(L("drawer.button.delete"), action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ClipboardHistoryLogic.diagnosticText(entry.text)))
    }

    /// 长按全文预览：BlockPopover 盖在行上方，长文内嵌滚动、可选中复制；
    /// 点击浮窗外与抽屉收起由 BlockPopover 自行收窗。
    private func presentPreview(_ frameInWindow: CGRect) {
        BlockPopover.shared.present(
            anchoredTo: frameInWindow,
            cardSize: CGSize(width: 280, height: 200)
        ) {
            ClipboardEntryPreviewCard(text: entry.text)
        }
    }

    private func iconButton(
        systemName: String,
        isActive: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(isActive ? NotchTokens.Foreground.body : NotchTokens.Foreground.disabled)
                .frame(width: 22, height: 20)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                            .fill(NotchTokens.Surface.track)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled(true)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// 长按预览浮窗内容：全文 + 内嵌滚动（长文本），支持选中复制。
private struct ClipboardEntryPreviewCard: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(NotchTokens.Text.system(11.5))
                .foregroundStyle(NotchTokens.Foreground.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

// MARK: - 紧凑块（纯展示；点击展开由宿主默认交互处理）

/// 刘海区图标：暂停时变灰。interaction 为默认 .expandDrawer，宿主包一层
/// onTapGesture 展开抽屉，插件视图不自带点击手势。
struct ClipboardTrayView: View {
    let context: BlockContext
    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        let slot = context.layoutInfo.frame.size
        return ZStack {
            Image(systemName: store.isPaused ? "clipboard.fill" : "clipboard")
                .font(NotchTokens.Text.system(13, weight: .medium))
                .foregroundStyle(store.isPaused ? NotchTokens.Foreground.disabled : NotchTokens.Foreground.secondary)
        }
        .frame(width: slot.width, height: slot.height)
        .contentShape(Rectangle())
        .help(store.isPaused ? L("drawer.paused.banner") : L("block.compact.name"))
        .accessibilityLabel(Text(L("block.compact.name")))
    }
}

// MARK: - 实例设置（显示条数）

struct ClipboardInstanceSettingsView: View {
    @ObservedObject var instance: ClipboardInstanceModel

    var body: some View {
        HStack {
            Text(L("settings.displayCount"))
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Spacer()
            Picker(L("settings.displayCount"), selection: displayCountBinding) {
                ForEach(ClipboardHistoryLogic.allowedDisplayCounts, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayCountBinding: Binding<Int> {
        Binding(
            get: { instance.config.displayCount },
            set: {
                instance.update(ClipboardInstanceConfig(displayCount: $0))
            }
        )
    }
}
