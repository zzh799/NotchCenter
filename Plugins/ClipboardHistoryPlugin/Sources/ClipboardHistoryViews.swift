import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（搜索 + 置顶区 + 最近列表）
//
// 交互（2026-09-06 重构，推翻原共识 Q8/Q9，见 agent-note 同日记录）：
// 条目主体点击 = 写回剪贴板（单行截断显示），长按 = BlockPopover 全文预览浮窗；
// 「置顶 / 删除」图标按钮同行放行尾。清空经卡片内 InlineConfirmOverlay 浮层
// 确认——模态弹窗抢焦点，鼠标移过去抽屉就会收回。
// 历史来自共享单例，显示偏好（条数）来自本 placement 的实例模型。

struct ClipboardHistoryBlockView: View {
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var instance: ClipboardInstanceModel
    let placementID: String
    let isPreview: Bool

    @State private var query = ""
    @State private var confirmingClear = false

    init(instance: ClipboardInstanceModel, placementID: String, isPreview: Bool) {
        self.store = ClipboardHistoryStore.shared
        self.instance = instance
        self.placementID = placementID
        self.isPreview = isPreview
    }

    var body: some View {
        BlockCard(hoverEffect: false) { _ in
            VStack(spacing: 0) {
                searchField
                if store.isPaused {
                    pausedBanner
                }
                listContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            visibilityProbeLayer
        }
        .onAppear {
            guard !isPreview else { return }
            ClipboardHistoryStore.shared.viewDidAppear(placementID: placementID)
        }
        .onDisappear {
            guard !isPreview else { return }
            ClipboardHistoryStore.shared.viewDidDisappear(placementID: placementID)
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
        .animation(.easeOut(duration: 0.15), value: confirmingClear)
        .colorScheme(.dark)
    }

    /// 列表区三态（空历史 / 搜索无果 / 列表）：抽出独立计算属性，给类型检查器减负。
    @ViewBuilder
    private var listContent: some View {
        if store.entries.isEmpty {
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

    /// 拍平后的展示条目（分区信息由 historyList 内按需重算标题行）。
    private var displayedEntries: [ClipboardEntry] {
        displayedSections.flatMap(\.entries)
    }

    // MARK: 派生数据

    /// 按置顶 / 最近分区、经搜索过滤、按实例条数截断后的展示节。
    private var displayedSections: [ClipboardSection] {
        let filtered = ClipboardHistoryLogic.filtered(store.entries, query: query)
        let limit = instance.config.displayCount
        let pinned = filtered.filter(\.pinned)
        let plain = filtered.filter { !$0.pinned }
        var sections: [ClipboardSection] = []
        if !pinned.isEmpty {
            sections.append(ClipboardSection(title: L("drawer.section.pinned"), entries: Array(pinned.prefix(limit))))
        }
        // 置顶已占去 k 位时，最近区补 (limit - k) 位，避免超长。
        let remaining = max(limit - min(pinned.count, limit), 0)
        if !plain.isEmpty, remaining > 0 {
            sections.append(ClipboardSection(title: L("drawer.section.recent"), entries: Array(plain.prefix(remaining))))
        }
        return sections
    }

    // MARK: 子视图

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            TextField(L("drawer.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .focusable(false)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled(true)
            }
            Spacer(minLength: 0)
            Button {
                confirmingClear = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled(true)
            .help(L("menu.clear"))
            .accessibilityLabel(Text(L("menu.clear")))
            .disabled(store.entries.allSatisfy { $0.pinned })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 11, weight: .medium))
            Text(L("drawer.paused.banner"))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.white.opacity(0.04))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(0.07)))
            Text(L("drawer.empty.title"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(L("drawer.empty.hint"))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(L("drawer.search.empty"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(displayedSections) { section in
                    ClipboardSectionView(
                        section: section,
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

/// 展示节模型（具名 Identifiable，避免匿名元组拖慢类型检查）。
private struct ClipboardSection: Identifiable {
    var id: String { title }
    let title: String
    let entries: [ClipboardEntry]
}

/// 单节渲染（标题 + 行列），从 historyList 抽出给类型检查器减负。
private struct ClipboardSectionView: View {
    let section: ClipboardSection
    let justCopiedID: UUID?
    let onCopy: (ClipboardEntry) -> Void
    let onTogglePin: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void

    var body: some View {
        Text(section.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 12)
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
                if entry.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if justCopied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
                        .accessibilityLabel(Text(L("drawer.button.copied")))
                }
                Text(entry.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                iconButton(
                    systemName: entry.pinned ? "pin.slash" : "pin",
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(justCopied ? 0.055 : 0.03))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.12), value: justCopied)
        // 主体点击 = 写回、长按 = 全文预览：单手势管线（blockPopoverTrigger，
        // TapGesture 与长按并存真机不触发的红线结论），行尾图标按钮自行消费点击。
        .blockPopoverTrigger(
            onTap: { _ in onCopy() },
            onLongPress: { frame in presentPreview(frame) },
            cornerRadius: 7
        )
        .contextMenu {
            Button(entry.pinned ? L("drawer.button.unpin") : L("drawer.button.pin"), action: onTogglePin)
            Button(L("drawer.button.delete"), action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(entry.text))
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

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled(true)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// 长按预览浮窗内容：全文 + 内嵌滚动（长文本），支持选中复制。
private struct ClipboardEntryPreviewCard: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.92))
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(store.isPaused ? 0.4 : 0.72))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
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
