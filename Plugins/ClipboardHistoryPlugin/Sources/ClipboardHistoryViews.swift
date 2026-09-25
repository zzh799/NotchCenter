import AppKit
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
// 置顶 / 最近分组不设文字标题：组界画细线表达，条目置顶态由行尾按钮选中态表达；
// 分组语义走行的 accessibilityLabel 前缀——列表已扁平进 LazyVStack，节容器不复存在
// （为什么必须扁平见 `ClipboardListItem` 的类型注释）。
// 历史来自共享单例，显示偏好（条数）来自本 placement 的实例模型。
//
// 富媒体（2026-09-20 决策记录 D9）：**图片行与其余行不等高**——图片给 44pt 放得下
// 32×20 缩略图，文本与文件行维持 30pt。多花 10pt 换"图片能一眼认出来"：抽屉块的
// 存在意义就是认出是哪一条然后取走，认不出的图片在抽屉里等于不存在。

/// 两处列表共用的行度量。
///
/// 与 `ClipboardLibraryMetricsProbe` 分开的理由：那一族常量是**库页纵向骨架**、被
/// 打包期探针逐条镜像，改一个数就要同步 `clipboardLibraryLayoutProbes`；而行高不进
/// 探针（列表在块内自管滚动），两处列表又必须一致。混在一起会让"改行高也要动探针"
/// 这个假约束传下去。
enum ClipboardRowMetrics {
    /// 文本 / 文件行高。等于库页原本的固定行高，也是抽屉块内容驱动的既有高度。
    static let textRowHeight: CGFloat = 30
    /// 图片行高：放得下缩略图与两侧留白。
    static let imageRowHeight: CGFloat = 44
    /// 图片缩略图显示尺寸（1.6:1 贴近截图比例，按 `.fill` 裁切）。
    static let thumbnailWidth: CGFloat = 32
    static let thumbnailHeight: CGFloat = 20

    /// 某条目的行高。
    static func height(for entry: ClipboardEntry) -> CGFloat {
        entry.kind == .image ? imageRowHeight : textRowHeight
    }
}

/// 条目在两处列表里的**展示文本**与无障碍标签。
///
/// 放在视图层而不是 `ClipboardHistoryLogic`：这里要 L10n 与 `NSString` 的路径拆分，
/// 而逻辑层刻意不依赖 AppKit / 本地化资源。
enum ClipboardEntryPresentation {
    /// 展示文本。
    ///
    /// 图片没有正文（决策记录 D4 存空串而非编造描述串），所以展示上补一个类型名；
    /// 文件显示**文件名**而不是整条路径——路径太长且大部分前缀是噪音。
    static func displayText(for entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image:
            return L("library.kind.image")
        case .file:
            let names = entry.fileURLs.map { ($0 as NSString).lastPathComponent }
            guard let first = names.first else { return entry.text }
            return names.count == 1 ? first : LF("drawer.file.multiple", first, names.count)
        case .text, .link, .color:
            return entry.text
        }
    }

    /// 行无障碍标签：分组名 + 内容。多文件只报数量，逐条念路径会读很久。
    static func accessibilityLabel(for entry: ClipboardEntry, section: ClipboardSectionKind) -> String {
        let group = L(section.titleKey)
        if entry.kind == .file, entry.fileURLs.count > 1 {
            return LF("drawer.row.a11y.files", group, entry.fileURLs.count)
        }
        return LF("drawer.row.a11y", group, displayText(for: entry))
    }
}

/// 落盘缩略图的展示视图。列表行、长按预览、悬浮预览共用同一份缩略图，差别只在裁不裁：
/// 列表行 `fill`（要的是等尺寸，比例不齐才整齐），预览卡 `fit`（要的是看全，`fill` 裁掉
/// 边缘等于丢内容）。
///
/// **只有这一份派生图**：长边 512px，正好覆盖预览卡最大显示边长（256pt）在 Retina 下的
/// 2× 需求。原图只在**写回**时被读——预览曾经读过原图，但悬浮预览是高频路径，为它解一张
/// 数 MB 的图不可接受，而把派生图提到够用的大小就能同时满足两者（决策记录
/// 2026-09-20-clipboard-hover-preview 的 D5）。
///
/// 同步读 + 内存缓存，不做异步加载：读取本身是亚毫秒级，为省这点时间给每一行加一套
/// 加载状态机与占位动画，复杂度换不来可感知的收益。缓存则必须有——列表每次重刷都会
/// 重跑 body。
struct ClipboardImageView: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    let contentMode: ContentMode

    var body: some View {
        Group {
            if let url, let image = ClipboardImageCache.shared.image(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                // 缩略图生成失败或文件被外部清掉时的占位，不留空洞。
                Rectangle().fill(NotchTokens.Surface.track)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                .strokeBorder(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
        )
    }
}

/// 缩略图的内存缓存。
///
/// 容量按条目上限给：512px 缩略图解码后约 650KB，全满约 33MB，`NSCache` 会在内存压力
/// 下自行回收，不需要额外的失效逻辑。
///
/// 失败也要记账（`missing`）：读不到就说明这个文件没了（生成失败或被外部清掉），
/// 每次 body 求值都重试一次 `NSImage(contentsOf:)` 等于把省下的 syscall 又还回去。
/// 记账集合以同样的容量封顶，条目被删后残留的路径不会无限堆积。
@MainActor
final class ClipboardImageCache {
    static let shared = ClipboardImageCache()

    private let cache = NSCache<NSURL, NSImage>()
    private var missing: Set<URL> = []
    private let limit: Int

    private init() {
        limit = ClipboardHistoryLogic.maxEntries
        cache.countLimit = limit
    }

    func image(at url: URL) -> NSImage? {
        if missing.contains(url) { return nil }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else {
            if missing.count < limit { missing.insert(url) }
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

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
    /// 悬浮预览的计时与目标（组件见 `ClipboardHoverPreview.swift`）。
    @StateObject private var hover = ClipboardHoverPreviewModel()

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
            ZStack(alignment: .topLeading) {
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
                hoverPreviewLayer
            }
            // 行与浮层共用这个名字空间：行的 hover 报出的光标位置直接就是浮层的摆放基准。
            .coordinateSpace(name: ClipboardHoverSpace.list)
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
            // 抽屉收起后视图树仍在（温存），悬浮卡必须跟着"用户看不见了"这个事实收掉。
            if !presented { hover.cancel() }
        }
        // 列表内容一变，光标底下换的可能是另一条：收起比留在旧内容上诚实。
        .onChange(of: query) { _, _ in hover.cancel() }
        .onChange(of: store.entries) { _, _ in hover.cancel() }
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
        } else {
            // 只算一次：扁平结果既是"搜索无果"的判据，也直接就是列表内容。
            let items = displayedItems
            if items.isEmpty {
                searchEmptyState
            } else {
                historyList(items)
            }
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

    // MARK: 派生数据

    /// 扁平后的展示项（分组、搜索过滤、按实例条数截断在此一次算完）。
    private var displayedItems: [ClipboardListItem] {
        let filtered = ClipboardHistoryLogic.filtered(store.entries, query: query)
        // 诊断压帽与实例配置取小：只改"物化多少行"，不动分区与排序语义。
        let limit = ClipboardHistoryLogic.effectiveDisplayCount(instance.config.displayCount)
        let pinned = filtered.filter(\.pinned)
        let plain = filtered.filter { !$0.pinned }
        // 置顶已占去 k 位时，最近区补 (limit - k) 位，避免超长。
        let remaining = max(limit - min(pinned.count, limit), 0)
        return ClipboardHistoryLogic.listItems(
            pinned: Array(pinned.prefix(limit)),
            recent: remaining > 0 ? Array(plain.prefix(remaining)) : []
        )
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

    /// 列表本体：`LazyVStack` + 单一 `ForEach`——行是惰性容器的**直接子项**（组界占一项），
    /// 因此只物化视口内的十来行。置顶/解顶时条目的 id 始终落在同一个 `ForEach` 里、
    /// 不再跨容器搬家，视图身份稳定、内容随值重刷（旧写法拿不到行级惰性，见
    /// `ClipboardListItem` 的类型注释）。
    private func historyList(_ items: [ClipboardListItem]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    listItemView(item)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func listItemView(_ item: ClipboardListItem) -> some View {
        switch item {
        case .sectionBreak:
            // 置顶组与最近组的组界发丝线（DESIGN.md §2.3 分隔线基准），纯装饰。
            Rectangle()
                .fill(NotchTokens.Hairline.divider)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .accessibilityHidden(true)
        case .entry(let entry, let section):
            ClipboardRowView(
                entry: entry,
                section: section,
                justCopied: store.justCopiedID == entry.id,
                copyFailed: store.copyFailedID == entry.id,
                thumbnailURL: store.thumbnailURL(for: entry),
                onCopy: {
                    hover.cancel()
                    store.copyBack(entry)
                },
                onTogglePin: { store.togglePin(id: entry.id) },
                onDelete: { store.delete(id: entry.id) },
                onLongPress: { frame in
                    // 长按期间光标是静止的，不停掉计时的话悬浮卡会在浮窗背后同时长出来。
                    hover.cancel()
                    presentPreview(frame, entry: entry)
                }
            )
            .padding(.horizontal, 8)
            .onContinuousHover(coordinateSpace: .named(ClipboardHoverSpace.list)) { phase in
                switch phase {
                case .active(let location): hover.hover(entry: entry, at: location)
                case .ended: hover.end(entry: entry)
                }
            }
        }
    }

    /// 悬浮预览层。
    ///
    /// 挂在块内容盒里而不是走 `BlockPopover`：零窗口开销，而且**由构造保证**不可能越出
    /// 块矩形——卡片一旦伸出抽屉可见矩形，光标落在伸出部分就等于离开宿主停留区，抽屉
    /// 会被收起（见 `BlockPopover.cardInset` 那段注释）。所以这里不需要任何"夹到抽屉矩形"
    /// 的额外逻辑，夹在块内容盒内即可。
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

    /// 长按全文预览（`BlockPopover` 独立窗口）：可滚动、可选中复制。
    ///
    /// 与悬浮预览分工：悬浮是"快速一瞥"（不吃点击、不可交互），长按是"看全并取用"。
    /// 两者不共用载体——`BlockPopover` 是进程内单例，悬浮若也走它会与长按互相顶掉。
    private func presentPreview(_ frameInWindow: CGRect, entry: ClipboardEntry) {
        BlockPopover.shared.present(
            anchoredTo: frameInWindow,
            cardSize: CGSize(width: 280, height: 200)
        ) {
            ClipboardEntryPreviewCard(entry: entry, imageURL: store.thumbnailURL(for: entry))
        }
    }
}

// MARK: - 历史行（主体点击写回 + 长按浮窗预览，操作按钮同行）

private struct ClipboardRowView: View {
    let entry: ClipboardEntry
    /// 所属分组：容器已扁平化，分组语义只能由行自己带上（见下方 accessibilityLabel）。
    let section: ClipboardSectionKind
    let justCopied: Bool
    /// 上一次点击被拒（文件原路径已失效）：行内出一次提示，不弹窗打断。
    let copyFailed: Bool
    /// 缩略图：行内 32×20 用 `fill`、长按预览与悬浮预览用 `fit`，读的是同一份文件。
    let thumbnailURL: URL?
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// 长按回调由父层提供：弹出前它要先取消悬浮预览计时，而这个行视图看不到那份状态。
    let onLongPress: (CGRect) -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if justCopied {
                    Image(systemName: "checkmark")
                        .font(NotchTokens.Text.system(9, weight: .semibold))
                        .foregroundStyle(NotchTokens.Semantic.accentGreen)
                        .accessibilityLabel(Text(L("drawer.button.copied")))
                }
                if entry.kind == .image {
                    ClipboardImageView(
                        url: thumbnailURL,
                        width: ClipboardRowMetrics.thumbnailWidth,
                        height: ClipboardRowMetrics.thumbnailHeight,
                        contentMode: .fill
                    )
                } else if entry.kind == .file {
                    Image(systemName: entry.kind.symbolName)
                        .font(NotchTokens.Text.system(10, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.placeholder)
                }
                Text(ClipboardHistoryLogic.diagnosticText(ClipboardEntryPresentation.displayText(for: entry)))
                    .font(NotchTokens.Text.system(11.5))
                    .foregroundStyle(copyFailed ? NotchTokens.Foreground.disabled : NotchTokens.Foreground.body)
                    .lineLimit(1)
                    .truncationMode(entry.kind == .file ? .middle : .tail)
                if copyFailed {
                    Text(L("drawer.copy.failed"))
                        .font(NotchTokens.Text.system(9.5, weight: .medium))
                        .foregroundStyle(NotchTokens.Semantic.unavailable)
                        .lineLimit(1)
                }
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
        .frame(height: ClipboardRowMetrics.height(for: entry))
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .fill(justCopied ? NotchTokens.Surface.fillHighlighted : NotchTokens.Surface.fill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .strokeBorder(
                    copyFailed ? NotchTokens.Semantic.unavailable : NotchTokens.Hairline.drawerEdge,
                    lineWidth: 1
                )
        }
        .animation(NotchTokens.Motion.hover, value: justCopied)
        // 主体点击 = 写回、长按 = 全文预览：单手势管线（blockPopoverTrigger，
        // TapGesture 与长按并存真机不触发的红线结论），行尾图标按钮自行消费点击。
        .blockPopoverTrigger(
            onTap: { _ in onCopy() },
            onLongPress: { frame in onLongPress(frame) },
            cornerRadius: NotchTokens.Radius.button
        )
        .contextMenu {
            Button(entry.pinned ? L("drawer.button.unpin") : L("drawer.button.pin"), action: onTogglePin)
            Button(L("drawer.button.delete"), action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ClipboardEntryPresentation.accessibilityLabel(for: entry, section: section)))
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

/// 长按预览浮窗内容：图片给 `fit` 的缩略图（不裁切），其余给全文 + 内嵌滚动（支持选中复制）。
private struct ClipboardEntryPreviewCard: View {
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
            }
            if entry.kind == .image {
                // `fit` 给全图；512px 缩略图正好覆盖 256pt 在 Retina 下的 2× 需求。
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

// MARK: - 实例设置（本组件：显示条数 / 全局：自动清理）

/// 抽屉块齿轮开的就是这一份。显示条数按实例走（每实例存储），自动清理是全局设置，
/// 用「全局」小节标题把作用域写在明面上（决策记录 2026-09-25-clipboard-auto-cleanup D8）。
struct ClipboardInstanceSettingsView: View {
    @ObservedObject var instance: ClipboardInstanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClipboardSettingsSection(title: L("settings.section.instance")) {
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
            }

            ClipboardSettingsSection(title: L("settings.section.global")) {
                VStack(alignment: .leading, spacing: 6) {
                    ClipboardAutoCleanupSettingsRow()
                    ClipboardAutoCleanupNote()
                }
            }
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
