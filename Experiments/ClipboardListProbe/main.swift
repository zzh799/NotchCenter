// ClipboardListProbe —— 剪贴板列表「惰性化 + 跨分区移动」独立验证窗口
//
// 为什么单独做：在生产插件里这件事没法快速迭代（要 assemble_app 拷 dylib、要跑抽屉
// 基准、要独占机器），而「置顶/解顶跨分区时同 id 视图不重刷」这条结论当年没有留下
// 可复现记录。本窗口把两件事抽出来放进同一份数据源做 A/B：
//
//   左面板 = 当前生产写法（节嵌套；结构可在「非惰性 VStack / 嵌套 LazyVStack」间切换）
//   右面板 = 目标写法（行扁平进 LazyVStack + 无状态行）
//
// 两块硬指标：
//   1. 已物化行数 —— 证明惰性到底有没有生效（嵌套写法下惰性只作用于「节」）；
//   2. 一致性断言 —— 每行把自己「实际渲染用的值」上报，与模型逐字段比对，不一致即计入
//      冲突。这把「按钮停在旧态」从目测传闻变成窗口内可自动跑到红的断言。
//
// 运行：
//   ./run.sh                     开窗口（手动对拍 + 压测按钮）
//   PROBE_SELFTEST=1 ./run.sh    无窗口自检，只验数据层与不变量

import AppKit
import Combine
import SwiftUI

// MARK: - 视图常量

enum ProbeMetrics {
    /// 行高固定：目标写法靠它 + 整表一个 GeometryReader 推算长按锚点，
    /// 从而把逐行 GeometryReader 全部去掉。两侧共用，保证 A/B 可比。
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 4
    static let sectionTitleHeight: CGFloat = 20
    static let paneListHeight: CGFloat = 380
}

// MARK: - 模型

enum SectionKind: String, Hashable {
    case pinned
    case recent

    var title: String { self == .pinned ? "置顶" : "最近" }
}

struct Entry: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var capturedAt = Date()
    var pinned = false
}

/// 行渲染值的完整快照。行把它上报给 ledger，ledger 拿它跟模型比对。
struct RowStamp: Equatable {
    var rowID: String
    var pinned: Bool
    var text: String
    var section: String
}

/// 扁平列表的元素：节标题也是 item，行因此成为 LazyVStack 的直接子项。
///
/// id 必须**全局唯一**：节标题占 "header." 前缀、条目占 "entry." 前缀。
/// 两个 id 空间混用（例如节直接用 kind、条目直接用 uuid）在扁平化后可能碰撞。
enum RowItem: Identifiable {
    case header(SectionKind)
    case entry(Entry)

    var id: String {
        switch self {
        case .header(let kind): return "header.\(kind.rawValue)"
        case .entry(let entry): return "entry.\(entry.id.uuidString)"
        }
    }

    var isEntry: Bool {
        if case .entry = self { return true }
        return false
    }
}

/// 嵌套写法用的节容器（对齐生产 ClipboardSection）。
struct SectionBlock: Identifiable {
    var id: SectionKind { kind }
    let kind: SectionKind
    let entries: [Entry]
}

// MARK: - 纯逻辑（对齐生产 ClipboardHistoryLogic 的口径）

enum ProbeLogic {
    static func insertionIndex(pinned: Bool, in entries: [Entry]) -> Int {
        entries.prefix(while: \.pinned).count
    }

    static func togglingPin(id: UUID, in entries: [Entry], maxPinned: Int, maxEntries: Int) -> [Entry] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        var next = entries
        var entry = next.remove(at: index)
        entry.pinned.toggle()
        next.insert(entry, at: insertionIndex(pinned: entry.pinned, in: next))
        return sanitized(next, maxPinned: maxPinned, maxEntries: maxEntries)
    }

    static func removing(id: UUID, from entries: [Entry]) -> [Entry] {
        guard entries.contains(where: { $0.id == id }) else { return entries }
        return entries.filter { $0.id != id }
    }

    static func clearingUnpinned(_ entries: [Entry]) -> [Entry] {
        entries.filter(\.pinned)
    }

    static func recording(_ text: String, into entries: [Entry], maxPinned: Int, maxEntries: Int) -> [Entry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        if entries.first?.text == trimmed { return entries }
        var next = entries
        if let index = next.firstIndex(where: { $0.text == trimmed }) {
            var hit = next.remove(at: index)
            hit.capturedAt = Date()
            next.insert(hit, at: insertionIndex(pinned: hit.pinned, in: next))
        } else {
            next.insert(Entry(text: trimmed), at: insertionIndex(pinned: false, in: next))
        }
        return sanitized(next, maxPinned: maxPinned, maxEntries: maxEntries)
    }

    /// 置顶区上限 + 总量上限（与生产同语义：溢出先解顶、再从末尾淘汰未置顶）。
    static func sanitized(_ entries: [Entry], maxPinned: Int, maxEntries: Int) -> [Entry] {
        var pinned = entries.filter(\.pinned)
        var plain = entries.filter { !$0.pinned }
        if pinned.count > maxPinned {
            let overflow = pinned[maxPinned...]
            pinned = Array(pinned.prefix(maxPinned))
            plain = Array(overflow.map { entry in
                var copy = entry
                copy.pinned = false
                return copy
            }) + plain
        }
        var combined = pinned + plain
        if combined.count > maxEntries {
            var kept: [Entry] = []
            var dropped = 0
            let overflow = combined.count - maxEntries
            for entry in combined.reversed() {
                if dropped < overflow, !entry.pinned {
                    dropped += 1
                    continue
                }
                kept.append(entry)
            }
            combined = Array(kept.reversed())
            if combined.count > maxEntries {
                combined = Array(combined.prefix(maxEntries))
            }
        }
        return combined
    }

    static func buildItems(_ entries: [Entry]) -> [RowItem] {
        let pinned = entries.filter(\.pinned)
        let plain = entries.filter { !$0.pinned }
        var items: [RowItem] = []
        if !pinned.isEmpty {
            items.append(.header(.pinned))
            items.append(contentsOf: pinned.map(RowItem.entry))
        }
        if !plain.isEmpty {
            items.append(.header(.recent))
            items.append(contentsOf: plain.map(RowItem.entry))
        }
        return items
    }

    static func buildSections(_ entries: [Entry]) -> [SectionBlock] {
        let pinned = entries.filter(\.pinned)
        let plain = entries.filter { !$0.pinned }
        var blocks: [SectionBlock] = []
        if !pinned.isEmpty { blocks.append(SectionBlock(kind: .pinned, entries: pinned)) }
        if !plain.isEmpty { blocks.append(SectionBlock(kind: .recent, entries: plain)) }
        return blocks
    }
}

// MARK: - 数据源（两侧面板共用）

final class ProbeStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var items: [RowItem] = []
    @Published private(set) var sections: [SectionBlock] = []
    /// 每次变更自增：面板据此触发「重建计时 + 一致性校验」。
    @Published private(set) var revision = 0

    @Published var capacity = 50
    @Published var maxPinned = 5

    private var seq = 0

    var entryRowCount: Int { entries.count }

    func seed(_ count: Int) {
        capacity = max(capacity, count)
        seq = count
        entries = (0..<count).map { index in
            Entry(text: Self.sampleText(index: index))
        }
        rebuildDerived()
        revision &+= 1
    }

    func recordRandom() {
        seq += 1
        entries = ProbeLogic.recording(
            "新复制 #\(seq) \(UUID().uuidString.prefix(6))",
            into: entries,
            maxPinned: maxPinned,
            maxEntries: capacity
        )
        rebuildDerived()
        revision &+= 1
    }

    func togglePin(_ id: UUID) {
        mutate { ProbeLogic.togglingPin(id: id, in: $0, maxPinned: maxPinned, maxEntries: capacity) }
    }

    func delete(_ id: UUID) {
        mutate { ProbeLogic.removing(id: id, from: $0) }
    }

    func clearUnpinned() {
        mutate { ProbeLogic.clearingUnpinned($0) }
    }

    /// 把最后一条置顶：典型「跨分区、且目标行通常在视口之外」的场景。
    func pinLast() {
        guard let last = entries.last else { return }
        togglePin(last.id)
    }

    /// 解顶第一条置顶项：典型「从置顶区落回最近区首位」的场景。
    func unpinFirstPinned() {
        guard let first = entries.first(where: \.pinned) else { return }
        togglePin(first.id)
    }

    func randomEntry() -> Entry? {
        entries.randomElement()
    }

    /// 模型侧应该长成的行渲染值；返回 nil = 该行不该存在。
    func expectedStamp(forRowID rowID: String) -> RowStamp? {
        if rowID.hasPrefix("entry.") {
            guard let uuid = UUID(uuidString: String(rowID.dropFirst("entry.".count))),
                  let entry = entries.first(where: { $0.id == uuid })
            else { return nil }
            return RowStamp(
                rowID: rowID,
                pinned: entry.pinned,
                text: entry.text,
                section: (entry.pinned ? SectionKind.pinned : .recent).rawValue
            )
        }
        if rowID.hasPrefix("header.") {
            let raw = String(rowID.dropFirst("header.".count))
            guard let kind = SectionKind(rawValue: raw) else { return nil }
            let exists = entries.contains { ($0.pinned ? SectionKind.pinned : .recent) == kind }
            guard exists else { return nil }
            return RowStamp(rowID: rowID, pinned: kind == .pinned, text: Self.headerText(kind), section: kind.rawValue)
        }
        return nil
    }

    static func headerText(_ kind: SectionKind) -> String { "header:\(kind.rawValue)" }

    private func mutate(_ transform: ([Entry]) -> [Entry]) {
        entries = transform(entries)
        rebuildDerived()
        revision &+= 1
    }

    private func rebuildDerived() {
        items = ProbeLogic.buildItems(entries)
        sections = ProbeLogic.buildSections(entries)
    }

    private static func sampleText(index: Int) -> String {
        // 掺入少量长正文，防止样本单调到掩盖文本测量成本。
        if index % 17 == 3 {
            return "长正文样本 #\(index) " + String(repeating: "lorem ipsum dolor sit amet ", count: 40)
        }
        return "剪贴条目 #\(index) 内容样本 \(UUID().uuidString.prefix(8))"
    }
}

// MARK: - 面板台账（物化计数 + 一致性断言）

final class PaneLedger: ObservableObject {
    @Published var liveCount = 0
    @Published var peakCount = 0
    @Published var totalRows = 0
    /// 从「触发重建」到「第一行上报挂载」的耗时，仅用于同窗口内横向对比。
    @Published var firstMountMillis: Double?
    @Published var mismatches: [String] = []

    private var live: Set<String> = []
    private var stamps: [String: RowStamp] = [:]
    private var mountStart: Double?

    /// 只重置计时与冲突，**不清空** live / stamps：数据变更时旧行不会重新 onAppear，
    /// 清空会让断言只剩「新出现的行」，等于把检测能力删掉。
    func beginRebuild() {
        mountStart = CFAbsoluteTimeGetCurrent()
        mismatches = []
    }

    private func noteFirstEventIfNeeded() {
        guard let start = mountStart else { return }
        firstMountMillis = (CFAbsoluteTimeGetCurrent() - start) * 1000
        mountStart = nil
    }

    func rowAppeared(_ stamp: RowStamp) {
        noteFirstEventIfNeeded()
        live.insert(stamp.rowID)
        stamps[stamp.rowID] = stamp
        liveCount = live.count
        peakCount = max(peakCount, live.count)
    }

    func rowDisappeared(_ rowID: String) {
        live.remove(rowID)
        stamps.removeValue(forKey: rowID)
        liveCount = live.count
    }

    func rowValueChanged(_ stamp: RowStamp) {
        noteFirstEventIfNeeded()
        stamps[stamp.rowID] = stamp
    }

    /// 逐行把「上报的渲染值」与模型比对。任何字段不一致 = 视图显示旧态。
    func verify(expect: (String) -> RowStamp?) {
        var issues: [String] = []
        for rowID in live.sorted() {
            guard let wanted = expect(rowID) else {
                issues.append("幽灵行 \(rowID)：模型里已不存在，视图仍在")
                continue
            }
            guard let reported = stamps[rowID] else {
                issues.append("缺上报 \(rowID)")
                continue
            }
            if reported != wanted {
                issues.append(
                    "\(rowID) 显示 \(reported.section)/\(reported.pinned ? "置顶" : "普通")"
                        + " ≠ 模型 \(wanted.section)/\(wanted.pinned ? "置顶" : "普通")"
                )
            }
        }
        mismatches = issues
    }
}

/// 面板级滚动请求（压测需要把目标行滚进视口才能验到惰性面板）。
final class ScrollRequest: ObservableObject {
    @Published var target: String?

    func scroll(to rowID: String) {
        target = rowID
    }
}

/// 行为日志。
final class ProbeLog: ObservableObject {
    @Published private(set) var lines: [String] = []

    func append(_ line: String) {
        let stamp = String(format: "%.2f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))
        lines.append("[\(stamp)] \(line)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
}

// MARK: - 行视图

/// 生产的逐行重型修饰器（复刻 `blockPopoverTrigger`）：4 个 @State + 逐行
/// GeometryReader 持续追踪 + 按压定时器 + contextMenu，逐行独立存在。
private struct HeavyRowChrome: ViewModifier {
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var frameInWindow: CGRect?
    @State private var isPressing = false
    @State private var pressStart: Date?
    @State private var longPressFired = false

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frameInWindow = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, frame in frameInWindow = frame }
                }
            )
            .overlay {
                if isPressing {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isPressing)
            .task(id: pressStart) {
                guard pressStart != nil else { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, pressStart != nil, !longPressFired else { return }
                longPressFired = true
                onLongPress()
            }
            .simultaneousGesture(gesture)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = Date()
                    isPressing = true
                    longPressFired = false
                } else if hypot(value.translation.width, value.translation.height) > 10 {
                    pressStart = nil
                    isPressing = false
                }
            }
            .onEnded { value in
                let start = pressStart
                let fired = longPressFired
                pressStart = nil
                isPressing = false
                longPressFired = false
                guard let start else { return }
                let held = Date().timeIntervalSince(start)
                let moved = hypot(value.translation.width, value.translation.height) > 10
                if held < 0.2, !moved, !fired { onTap() }
            }
    }
}

/// 行的视觉层：**纯函数**——只读传入的值，无任何本地状态。
/// 徽标把「置顶/普通」写在脸上，视图显示旧态时肉眼即可分辨。
private struct RowPresentation: View {
    let text: String
    let pinned: Bool
    let isPressed: Bool
    let onPinTap: () -> Void
    let onDeleteTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(displaySection)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(pinned ? Color(red: 0.98, green: 0.78, blue: 0.46) : Color.white.opacity(0.45))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(pinned ? Color(red: 0.39, green: 0.22, blue: 0.02) : Color.white.opacity(0.07))
                )
            Button(action: onPinTap) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(pinned ? Color.white.opacity(0.9) : Color.white.opacity(0.45))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onDeleteTap) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: ProbeMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(isPressed ? 0.28 : 0.09), lineWidth: 1)
        )
    }

    private var displaySection: String { pinned ? "置顶" : "普通" }

    private var fill: Color {
        if isPressed { return Color.white.opacity(0.14) }
        return pinned ? Color.white.opacity(0.10) : Color.white.opacity(0.055)
    }
}

/// 重型行：复刻生产（逐行状态 + 逐行几何 + contextMenu）。
private struct HeavyRow: View {
    let entry: Entry
    let section: SectionKind
    let ledger: PaneLedger
    let onPin: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onLongPressLog: (String) -> Void

    var body: some View {
        RowPresentation(
            text: entry.text,
            pinned: entry.pinned,
            isPressed: false,
            onPinTap: { onPin(entry.id) },
            onDeleteTap: { onDelete(entry.id) }
        )
        .modifier(HeavyRowChrome(
            onTap: {},
            onLongPress: { onLongPressLog(entry.text) }
        ))
        .contextMenu {
            Button(entry.pinned ? "取消置顶" : "置顶") { onPin(entry.id) }
            Button("删除") { onDelete(entry.id) }
        }
        .stampReporting(stamp, ledger: ledger)
    }

    private var stamp: RowStamp {
        RowStamp(rowID: "entry.\(entry.id.uuidString)", pinned: entry.pinned, text: entry.text, section: section.rawValue)
    }
}

/// 无状态行：零本地状态、零逐行几何、零 contextMenu（鼠标右键菜单与行尾按钮功能重复）。
/// 按压态由面板单点持有后作为**值**传入。
private struct LeanRow: View {
    let entry: Entry
    let section: SectionKind
    let isPressed: Bool
    let ledger: PaneLedger
    let onPressBegan: (_ rowID: String) -> Void
    let onPressMovedOut: () -> Void
    let onPressEnded: (_ rowID: String) -> Void
    let onPin: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        RowPresentation(
            text: entry.text,
            pinned: entry.pinned,
            isPressed: isPressed,
            onPinTap: { onPin(entry.id) },
            onDeleteTap: { onDelete(entry.id) }
        )
        .simultaneousGesture(pressGesture)
        .stampReporting(stamp, ledger: ledger)
    }

    private var rowID: String { "entry.\(entry.id.uuidString)" }

    private var stamp: RowStamp {
        RowStamp(rowID: rowID, pinned: entry.pinned, text: entry.text, section: section.rawValue)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if hypot(value.translation.width, value.translation.height) > 10 {
                    onPressMovedOut()
                } else {
                    onPressBegan(rowID)
                }
            }
            .onEnded { _ in onPressEnded(rowID) }
    }
}

/// 行上报：把「本行实际渲染用的值」交给台账（挂载 / 值变化 / 卸载）。
private struct StampReporting: ViewModifier {
    let stamp: RowStamp
    let ledger: PaneLedger

    func body(content: Content) -> some View {
        content
            .onAppear { ledger.rowAppeared(stamp) }
            .onDisappear { ledger.rowDisappeared(stamp.rowID) }
            .onChange(of: stamp) { _, newValue in ledger.rowValueChanged(newValue) }
    }
}

private extension View {
    func stampReporting(_ stamp: RowStamp, ledger: PaneLedger) -> some View {
        modifier(StampReporting(stamp: stamp, ledger: ledger))
    }
}

/// 节标题（扁平结构下也是一个 item，因此占一行位置）。
private struct SectionHeaderRow: View {
    let kind: SectionKind
    let count: Int
    let ledger: PaneLedger

    var body: some View {
        HStack(spacing: 6) {
            Text(kind.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .frame(height: ProbeMetrics.sectionTitleHeight, alignment: .leading)
        .stampReporting(
            RowStamp(
                rowID: "header.\(kind.rawValue)",
                pinned: kind == .pinned,
                text: ProbeStore.headerText(kind),
                section: kind.rawValue
            ),
            ledger: ledger
        )
    }
}

// MARK: - 三种列表结构

private enum PaneLayout: String, CaseIterable, Identifiable {
    case nestedStack
    case nestedLazy
    case flatLazy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nestedStack: return "节嵌套 · 非惰性 VStack"
        case .nestedLazy: return "节嵌套 · 惰性 LazyVStack"
        case .flatLazy: return "扁平单 ForEach · LazyVStack"
        }
    }

    var note: String {
        switch self {
        case .nestedStack: return "等价现状：行随节整体物化"
        case .nestedLazy: return "惰性只作用于「节」，行仍不惰性"
        case .flatLazy: return "行是 LazyVStack 直接子项，只物化视口内"
        }
    }
}

/// 嵌套结构：LazyVStack（或 VStack）→ ForEach(节) → 节的 ForEach(行)。
private struct NestedList: View {
    let sections: [SectionBlock]
    let lazyOuter: Bool
    let heavyRows: Bool
    let ledger: PaneLedger
    let onPin: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onLog: (String) -> Void

    var body: some View {
        Group {
            if lazyOuter {
                LazyVStack(alignment: .leading, spacing: 10) { sectionViews }
            } else {
                VStack(alignment: .leading, spacing: 10) { sectionViews }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var sectionViews: some View {
        ForEach(sections) { block in
            VStack(alignment: .leading, spacing: ProbeMetrics.rowSpacing) {
                SectionHeaderRow(kind: block.kind, count: block.entries.count, ledger: ledger)
                ForEach(block.entries) { entry in
                    if heavyRows {
                        HeavyRow(
                            entry: entry,
                            section: block.kind,
                            ledger: ledger,
                            onPin: onPin,
                            onDelete: onDelete,
                            onLongPressLog: onLog
                        )
                    } else {
                        LeanRow(
                            entry: entry,
                            section: block.kind,
                            isPressed: false,
                            ledger: ledger,
                            onPressBegan: { _ in },
                            onPressMovedOut: {},
                            onPressEnded: { _ in },
                            onPin: onPin,
                            onDelete: onDelete
                        )
                    }
                }
            }
        }
    }
}

/// 目标结构：单一 LazyVStack + 单一 ForEach，节标题也是 item。
private struct FlatList: View {
    let items: [RowItem]
    let pressedRowID: String?
    let heavyRows: Bool
    let ledger: PaneLedger
    let onPressBegan: (String) -> Void
    let onPressMovedOut: () -> Void
    let onPressEnded: (String) -> Void
    let onPin: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onLog: (String) -> Void
    /// 整表唯一一个 GeometryReader 量出的列表原点，配合固定行高推算长按锚点。
    let onListOriginChange: (CGFloat) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: ProbeMetrics.rowSpacing) {
            ForEach(items) { item in
                itemView(item)
            }
        }
        .padding(.vertical, 6)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onListOriginChange(geo.frame(in: .global).minY) }
                    .onChange(of: geo.frame(in: .global).minY) { _, y in onListOriginChange(y) }
            }
        )
    }

    @ViewBuilder
    private func itemView(_ item: RowItem) -> some View {
        switch item {
        case .header(let kind):
            SectionHeaderRow(kind: kind, count: count(of: kind), ledger: ledger)
        case .entry(let entry):
            if heavyRows {
                HeavyRow(
                    entry: entry,
                    section: entry.pinned ? .pinned : .recent,
                    ledger: ledger,
                    onPin: onPin,
                    onDelete: onDelete,
                    onLongPressLog: onLog
                )
            } else {
                LeanRow(
                    entry: entry,
                    section: entry.pinned ? .pinned : .recent,
                    isPressed: pressedRowID == "entry.\(entry.id.uuidString)",
                    ledger: ledger,
                    onPressBegan: onPressBegan,
                    onPressMovedOut: onPressMovedOut,
                    onPressEnded: onPressEnded,
                    onPin: onPin,
                    onDelete: onDelete
                )
            }
        }
    }

    private func count(of kind: SectionKind) -> Int {
        items.reduce(into: 0) { total, item in
            if case .entry(let entry) = item, (entry.pinned ? SectionKind.pinned : .recent) == kind {
                total += 1
            }
        }
    }
}

// MARK: - 面板

private struct PaneHeader: View {
    @ObservedObject var ledger: PaneLedger
    let layout: PaneLayout
    let heavyRows: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(layout.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(heavyRows ? "重型行" : "无状态行")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
                Spacer(minLength: 0)
                verdict
            }
            Text(layout.note)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.45))
            HStack(spacing: 14) {
                metric("已物化行", "\(ledger.liveCount)")
                metric("峰值物化", "\(ledger.peakCount)")
                metric("总行数", "\(ledger.totalRows)")
                metric("首行挂载", ledger.firstMountMillis.map { String(format: "%.0f ms", $0) } ?? "—")
            }
        }
    }

    private var verdict: some View {
        let clean = ledger.mismatches.isEmpty
        return Text(clean ? "✓ 一致" : "✗ \(ledger.mismatches.count) 处冲突")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(clean ? Color(red: 0.37, green: 0.78, blue: 0.55) : Color(red: 0.98, green: 0.45, blue: 0.45))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.4))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.85))
        }
    }
}

private struct ClipboardPane: View {
    @ObservedObject var store: ProbeStore
    @ObservedObject var scroll: ScrollRequest
    let ledger: PaneLedger
    let layout: PaneLayout
    let heavyRows: Bool
    let log: ProbeLog

    /// 目标写法的按压态：整表一份，行只收值。
    @State private var pressedRowID: String?
    @State private var pressStartedAt: Date?
    @State private var listOriginY: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(ledger: ledger, layout: layout, heavyRows: heavyRows)
            Divider().overlay(Color.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    listBody
                }
                .frame(height: ProbeMetrics.paneListHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
                .onChange(of: scroll.target) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .task(id: pressStartedAt) {
            guard let start = pressStartedAt, let rowID = pressedRowID else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, pressStartedAt != nil else { return }
            // 锚点：整表一个 GeometryReader 量出的原点 + 固定行高推算，
            // 不需要逐行几何。生产里这就是 blockPopoverTrigger 的替代路径。
            let index = store.items.firstIndex { $0.id == rowID } ?? 0
            let y = listOriginY + CGFloat(index) * (ProbeMetrics.rowHeight + ProbeMetrics.rowSpacing)
            log.append("长按 \(rowID.prefix(14)) 推算锚点 y=\(Int(y))（起按于 \(Int(start.timeIntervalSince1970)))）")
        }
        .onAppear { refreshLedger() }
        .onChange(of: store.revision) { _, _ in refreshLedger() }
    }

    @ViewBuilder
    private var listBody: some View {
        switch layout {
        case .nestedStack:
            NestedList(
                sections: store.sections,
                lazyOuter: false,
                heavyRows: heavyRows,
                ledger: ledger,
                onPin: { store.togglePin($0) },
                onDelete: { store.delete($0) },
                onLog: { log.append("长按预览：\($0.prefix(16))…") }
            )
        case .nestedLazy:
            NestedList(
                sections: store.sections,
                lazyOuter: true,
                heavyRows: heavyRows,
                ledger: ledger,
                onPin: { store.togglePin($0) },
                onDelete: { store.delete($0) },
                onLog: { log.append("长按预览：\($0.prefix(16))…") }
            )
        case .flatLazy:
            FlatList(
                items: store.items,
                pressedRowID: pressedRowID,
                heavyRows: heavyRows,
                ledger: ledger,
                onPressBegan: { rowID in
                    guard pressedRowID != rowID else { return }
                    pressedRowID = rowID
                    pressStartedAt = Date()
                },
                onPressMovedOut: {
                    // 拖出容忍范围（滚动意图）：只在确有待清状态时写，
                    // 否则逐帧空写会把整表重绘拖成噪声。
                    guard pressedRowID != nil || pressStartedAt != nil else { return }
                    pressedRowID = nil
                    pressStartedAt = nil
                },
                onPressEnded: { rowID in
                    guard let start = pressStartedAt, pressedRowID == rowID else {
                        if pressedRowID != nil || pressStartedAt != nil {
                            pressedRowID = nil
                            pressStartedAt = nil
                        }
                        return
                    }
                    pressedRowID = nil
                    pressStartedAt = nil
                    if Date().timeIntervalSince(start) < 0.2 {
                        log.append("点击写回：\(rowID.prefix(14))（空操作，探针不碰真实剪贴板）")
                    }
                },
                onPin: { store.togglePin($0) },
                onDelete: { store.delete($0) },
                onLog: { log.append("长按预览：\($0.prefix(16))…") },
                onListOriginChange: { listOriginY = $0 }
            )
        }
    }

    private func refreshLedger() {
        ledger.totalRows = store.entryRowCount
        ledger.beginRebuild()
        let expect: (String) -> RowStamp? = { store.expectedStamp(forRowID: $0) }
        // 两拍校验：0.3s 抓快速提交、0.9s 抓迟到提交（复用残留通常是后者）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak ledger] in
            ledger?.verify(expect: expect)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak ledger] in
            ledger?.verify(expect: expect)
        }
    }
}

/// 顶栏汇总：唯一订阅两份台账的视图（避免把订阅扩散到根视图）。
private struct StatusBarView: View {
    @ObservedObject var left: PaneLedger
    @ObservedObject var right: PaneLedger

    var body: some View {
        let conflicts = left.mismatches + right.mismatches
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(conflicts.isEmpty ? "一致性：两侧面板均无冲突" : "一致性：发现 \(conflicts.count) 处冲突")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(conflicts.isEmpty
                        ? Color(red: 0.37, green: 0.78, blue: 0.55)
                        : Color(red: 0.98, green: 0.45, blue: 0.45))
                Text("物化行：左 \(left.liveCount) / 右 \(right.liveCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            ForEach(conflicts.prefix(4), id: \.self) { issue in
                Text("· \(issue)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.45))
            }
        }
    }
}

// MARK: - 根视图

private struct RootView: View {
    @StateObject private var store = ProbeStore()
    @StateObject private var log = ProbeLog()

    /// 台账用 @State 而非 @StateObject：只需要它持久，**不需要** RootView 订阅它——
    /// 行每次挂载都会写 liveCount，订阅会把整个根视图拖进逐行重绘。
    /// 真正订阅它的只有 PaneHeader 与 StatusBarView。
    @State private var leftLedger = PaneLedger()
    @State private var rightLedger = PaneLedger()
    @State private var leftScroll = ScrollRequest()
    @State private var rightScroll = ScrollRequest()

    @State private var leftLayout: PaneLayout = .nestedStack
    @State private var rightHeavyRows = false
    @State private var seedCount = 50
    @State private var stressRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            HStack(alignment: .top, spacing: 12) {
                ClipboardPane(
                    store: store, scroll: leftScroll, ledger: leftLedger,
                    layout: leftLayout, heavyRows: true, log: log
                )
                ClipboardPane(
                    store: store, scroll: rightScroll, ledger: rightLedger,
                    layout: .flatLazy, heavyRows: rightHeavyRows, log: log
                )
            }
            statusBarView
            logView
        }
        .padding(14)
        .frame(minWidth: 1000, minHeight: 780)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .preferredColorScheme(.dark)
        .onAppear {
            store.seed(seedCount)
            log.append("种子 \(seedCount) 条。置顶一条看两侧徽标是否同步跟随。")
        }
    }

    // MARK: 控制条

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("条目数", selection: $seedCount) {
                    ForEach([20, 50, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: seedCount) { _, count in
                    store.seed(count)
                    log.append("重新播种 \(count) 条。")
                }
                button("新增一条") { store.recordRandom() }
                button("置顶最后一条") { store.pinLast() }
                button("解顶首条置顶") { store.unpinFirstPinned() }
                button("随机置顶/解顶") {
                    guard let entry = store.randomEntry() else { return }
                    store.togglePin(entry.id)
                    log.append("随机切换：\(entry.text.prefix(14))…")
                }
                button("清空未置顶") { store.clearUnpinned() }
            }
            HStack(spacing: 10) {
                Text("左面板结构")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                Picker("左面板结构", selection: $leftLayout) {
                    ForEach(PaneLayout.allCases.filter { $0 != .flatLazy }) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 250)
                Toggle("右侧也用重型行（只隔离结构这一个变量）", isOn: $rightHeavyRows)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                button("压测 100 次（自动断言）") { runStress() }
                    .disabled(stressRunning)
                if stressRunning {
                    Text("压测进行中…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.98, green: 0.78, blue: 0.46))
                }
            }
        }
    }

    private var statusBarView: some View {
        StatusBarView(left: leftLedger, right: rightLedger)
    }

    private var logView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(log.lines.indices.reversed(), id: \.self) { index in
                    Text(log.lines[index])
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 120)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11))
    }

    // MARK: 压测：跨分区移动 + 滚动进出视口 + 自动断言

    private func runStress() {
        stressRunning = true
        log.append("压测开始：每条都先滚进视口再置顶/解顶，随后两拍校验。")
        Task { @MainActor in
            var conflicts = 0
            for step in 1...100 {
                guard let entry = store.randomEntry() else { continue }
                let rowID = "entry.\(entry.id.uuidString)"
                leftScroll.scroll(to: rowID)
                rightScroll.scroll(to: rowID)
                try? await Task.sleep(nanoseconds: 120_000_000)

                store.togglePin(entry.id)
                try? await Task.sleep(nanoseconds: 900_000_000)

                let left = leftLedger.mismatches
                let right = rightLedger.mismatches
                if !left.isEmpty || !right.isEmpty {
                    conflicts += left.count + right.count
                    log.append("第 \(step) 步冲突：左 \(left.first ?? "-") / 右 \(right.first ?? "-")")
                    if conflicts > 8 {
                        log.append("冲突过多，提前结束。")
                        break
                    }
                }
                if step % 20 == 0 {
                    log.append("第 \(step) 步，暂无冲突。")
                }
            }
            log.append(conflicts == 0 ? "压测结束：100 步零冲突。" : "压测结束：累计 \(conflicts) 处冲突。")
            stressRunning = false
        }
    }
}

// MARK: - 无窗口自检（PROBE_SELFTEST=1）

private func runSelfTest() -> Bool {
    var failures: [String] = []
    let store = ProbeStore()
    store.maxPinned = 5
    store.capacity = 200
    store.seed(200)

    if store.entries.count != 200 { failures.append("播种数不对：\(store.entries.count)") }

    func assertInvariants(_ tag: String) {
        let pinnedCount = store.entries.filter(\.pinned).count
        if pinnedCount > store.maxPinned { failures.append("\(tag): 置顶超限 \(pinnedCount)") }
        if store.entries.count > store.capacity { failures.append("\(tag): 总量超限 \(store.entries.count)") }
        if Set(store.entries.map(\.id)).count != store.entries.count { failures.append("\(tag): 条目 id 重复") }
        if Set(store.items.map(\.id)).count != store.items.count { failures.append("\(tag): 扁平 item id 重复") }
        let firstPlain = store.entries.firstIndex { !$0.pinned } ?? store.entries.count
        let lastPinned = store.entries.lastIndex { $0.pinned } ?? -1
        if lastPinned >= firstPlain, lastPinned != -1 { failures.append("\(tag): 置顶未全部排在前面") }
        // 行 id 与节 id 分属两个前缀，永不碰撞。
        for item in store.items where item.isEntry {
            if item.id.hasPrefix("header.") { failures.append("\(tag): 行 id 落进节 id 空间") }
        }
        // expectedStamp 与 items 必须一一对得上：这是断言侧的判据本身。
        for item in store.items where item.isEntry {
            if store.expectedStamp(forRowID: item.id) == nil { failures.append("\(tag): \(item.id) 查不到期望值") }
        }
        for row in ["header.pinned", "header.recent"] {
            let exists = store.items.contains { $0.id == row }
            let expected = store.expectedStamp(forRowID: row) != nil
            if exists != expected { failures.append("\(tag): \(row) 存在性与模型不符") }
        }
    }

    assertInvariants("播种后")

    var generator = SystemRandomNumberGenerator()
    var peakEntries = store.entries.count
    for step in 1...2000 {
        switch Int.random(in: 0..<10, using: &generator) {
        case 0...5:
            if let entry = store.randomEntry() { store.togglePin(entry.id) }
        case 6:
            store.pinLast()
        case 7:
            store.unpinFirstPinned()
        case 8:
            store.recordRandom()
        default:
            store.clearUnpinned()
        }
        peakEntries = max(peakEntries, store.entries.count)
        if step % 50 == 0 { assertInvariants("第 \(step) 步") }
    }
    assertInvariants("压测后")

    // 幽灵行判据：删除条目后，其行 id 必须查不到期望值（视图若仍在上报即判冲突）。
    if let victim = store.entries.dropFirst(10).first {
        let rowID = "entry.\(victim.id.uuidString)"
        store.delete(victim.id)
        if store.expectedStamp(forRowID: rowID) != nil { failures.append("删除后仍能查到期望值") }
    }

    // 断言器自身的有效性（防止「0 冲突」其实是断言器坏掉）：
    // 人为把一条「模型已变、视图没跟上」的上报塞进台账，必须被抓到；修正后必须转干净。
    let detectorStore = ProbeStore()
    detectorStore.seed(5)
    if let sample = detectorStore.entries.first {
        let rowID = "entry.\(sample.id.uuidString)"
        let ledger = PaneLedger()
        // ① 过期上报：模型里它还是普通条目，台账里报的却是它置顶之后的旧值形态（此处反过来做：
        //    先让模型置顶，再让行保持旧的「普通」上报）。
        ledger.rowAppeared(
            RowStamp(rowID: rowID, pinned: false, text: sample.text, section: SectionKind.recent.rawValue)
        )
        detectorStore.togglePin(sample.id)
        ledger.verify(expect: { detectorStore.expectedStamp(forRowID: $0) })
        if ledger.mismatches.isEmpty {
            failures.append("断言器无效：模型已置顶、行仍报普通的过期上报未被抓到")
        }
        // ② 行正确重刷 → 必须转干净，否则说明断言器会误报。
        if let updated = detectorStore.entries.first(where: { $0.id == sample.id }) {
            ledger.rowValueChanged(
                RowStamp(
                    rowID: rowID,
                    pinned: updated.pinned,
                    text: updated.text,
                    section: (updated.pinned ? SectionKind.pinned : .recent).rawValue
                )
            )
        }
        ledger.verify(expect: { detectorStore.expectedStamp(forRowID: $0) })
        if !ledger.mismatches.isEmpty {
            failures.append("断言器误报：行已正确重刷仍被判冲突 \(ledger.mismatches[0])")
        }
        // ③ 幽灵行：模型删除后，仍在上报的行必须被判冲突。
        detectorStore.delete(sample.id)
        ledger.verify(expect: { detectorStore.expectedStamp(forRowID: $0) })
        if ledger.mismatches.isEmpty {
            failures.append("断言器无效：模型已删除、行仍在上报的幽灵行未被抓到")
        }
    }

    print("== ClipboardListProbe 自检 ==")
    print("条目数 \(store.entries.count) / 置顶 \(store.entries.filter(\.pinned).count) / 扁平 item \(store.items.count)")
    print("压测峰值条目数 \(peakEntries)（封顶 \(store.capacity)）")
    if failures.isEmpty {
        print("结果：PASS（不变量、id 唯一性、期望值判据、过期/幽灵行检测全部成立）")
    } else {
        print("结果：FAIL")
        for failure in failures.prefix(20) { print("  · \(failure)") }
    }
    return failures.isEmpty
}

// MARK: - 应用入口

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipboardListProbe — 剪贴板列表惰性化验证"
        window.contentView = NSHostingView(rootView: RootView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if ProcessInfo.processInfo.environment["PROBE_SELFTEST"] == "1" {
    exit(runSelfTest() ? 0 : 1)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = ProbeDelegate()
application.delegate = delegate
application.activate(ignoringOtherApps: true)
application.run()
