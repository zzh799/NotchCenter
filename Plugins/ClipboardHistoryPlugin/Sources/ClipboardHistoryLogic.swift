import Foundation

// MARK: - 剪贴板历史纯逻辑（无 AppKit 依赖，供单测直调）
//
// 数据模型与全部状态变换集中于此：去重 / 置顶 / 淘汰 / 搜索过滤 / 持久化净化。
// 轮询、剪贴板读写、定时器等副作用全部留在 ClipboardHistoryStore；本文件
// 在 Linux 容器测试环境也能编译运行。

/// 条目类型（剪贴板库页的分类维度）。
///
/// 采集口径（2026-09-11）：本期仍只采集**纯文本**，类型由文本内容推断
/// （链接 / 颜色 / 文本三态）。`image` / `file` 是**预留位**——富媒体采集涉及
/// 落盘、去重与缩略图缓存，是独立一期的工作量；枚举先占位，使持久化格式与
/// 筛选 UI 的形状定下来，二期接采集时不需要再动存储结构。
enum ClipboardEntryKind: String, Codable, CaseIterable, Sendable {
    case text
    case link
    case color
    case image
    case file

    /// 筛选栏图标（SF Symbol）。
    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// 筛选栏文案键。
    var localizationKey: String {
        switch self {
        case .text: return "library.kind.text"
        case .link: return "library.kind.link"
        case .color: return "library.kind.color"
        case .image: return "library.kind.image"
        case .file: return "library.kind.file"
        }
    }

    /// 本期实际可出现的类型（富媒体未采集，筛选栏只列这三种）。
    static let collectable: [ClipboardEntryKind] = [.text, .link, .color]
}

/// 单条历史：正文 + 首次记录时间 + 置顶标记。
///
/// **向后兼容契约**：`kind` / `previewData` / `sourceApp` 是 2026-09-11 新增字段，
/// 解码走 `decodeIfPresent` + 默认值——旧 `history.entries.v1` 数组（只有
/// id/text/capturedAt/pinned 四个键）必须能原样读出。因此**不要**把新字段改成
/// 非可选且无默认值的形式，也不要依赖编码器补键。
struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var capturedAt: Date
    var pinned: Bool
    /// 条目类型（旧数据缺失 → 由正文重新推断，见 `init(from:)`）。
    var kind: ClipboardEntryKind
    /// 富媒体缩略图原始数据（本期恒 nil，二期采集用；旧数据缺失 → nil）。
    var previewData: Data?
    /// 来源应用标识（本期恒 nil，二期写入；旧数据缺失 → nil）。
    var sourceApp: String?

    init(
        id: UUID = UUID(),
        text: String,
        capturedAt: Date = Date(),
        pinned: Bool = false,
        kind: ClipboardEntryKind? = nil,
        previewData: Data? = nil,
        sourceApp: String? = nil
    ) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.pinned = pinned
        // 未显式指定类型时按正文推断，保证新建条目与旧条目走同一套判定。
        self.kind = kind ?? ClipboardHistoryLogic.classify(text: text)
        self.previewData = previewData
        self.sourceApp = sourceApp
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case capturedAt
        case pinned
        case kind
        case previewData
        case sourceApp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        self.text = text
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        self.pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        // 旧数据没有 kind：按正文重新推断，而不是一律记成 text——否则存量
        // 链接/颜色条目在新库里全被归错类。
        self.kind = try container.decodeIfPresent(ClipboardEntryKind.self, forKey: .kind)
            ?? ClipboardHistoryLogic.classify(text: text)
        self.previewData = try container.decodeIfPresent(Data.self, forKey: .previewData)
        self.sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
    }
}

/// 历史变换纯函数集（共识 Q4/Q7/Q9）。
enum ClipboardHistoryLogic {
    /// 总容量（含置顶）。
    static let maxEntries = 50
    /// 置顶区上限。
    static let maxPinned = 5
    /// 单条上限：超长文本不记（base64 / 报错堆栈是体积爆炸主因）。
    static let maxSingleBytes = 100 * 1024
    /// 允许的每实例显示条数档位（共识 Q10）。
    static let allowedDisplayCounts = [20, 50]

    /// 诊断：把展示行数压到 N（`NOTCHCENTER_CLIPBOARD_ROW_CAP`，宿主 `NOTCHCENTER_*`
    /// 探针同族，默认 nil 不干预）。
    ///
    /// 为什么需要它：本块的展开耗时随**行数**而非块面积增长（非惰性 `VStack`
    /// 物化全部条目行，见 `ClipboardHistoryViews` 的 `historyList` 注释）。只有能
    /// 从二进制外部改行数、其余变量全不动，才能把"行数 → 首渲染耗时"单独量出来；
    /// 后续"限量 / 惰性物化"的改动也用同一口径复量。
    ///
    /// 刻意不进实例配置：它是量测口径，不是用户偏好——写进配置就没法在同一份
    /// 二进制里被外部改掉了。
    static var diagnosticRowCap: Int? {
        ProcessInfo.processInfo.environment["NOTCHCENTER_CLIPBOARD_ROW_CAP"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
    }

    /// 实例显示条数与诊断压帽取小（纯函数，压帽施加点单点收敛、可单测）。
    static func effectiveDisplayCount(_ configured: Int, cap: Int? = diagnosticRowCap) -> Int {
        min(configured, cap ?? Int.max)
    }

    /// 诊断压帽的数组形态：`cap` 为 nil 原样返回，否则取前 `cap` 条。
    /// 只改物化多少行，不动排序 / 分区语义。
    static func applyingRowCap(
        _ entries: [ClipboardEntry],
        cap: Int? = diagnosticRowCap
    ) -> [ClipboardEntry] {
        guard let cap else { return entries }
        return Array(entries.prefix(cap))
    }

    /// 诊断模式：把剪贴板块的成本拆成可外部逐一切换的候选分量（`NOTCHCENTER_CLIPBOARD_DIAG`）。
    ///
    /// 为什么需要它：压帽只能回答"行数与正文体积**合起来**占多少"，而这两者在本机
    /// 历史里是绑死的——5 条 4–12k 字的 HTML 占了 4 万字中的 3.9 万，且恰好都落在
    /// 第 10 条之后，于是 `ROW_CAP=10` 会同时把行数和正文一起砍掉，分不清谁重。
    /// 探针 / 列表内容 / 正文体积三个分量彼此正交、又都发生在视图体内，从外部
    /// 无法分辨，只能逐个摘掉再用同一份基准复量。
    ///
    /// 实测结论（见 `docs/agent-notes/implemented/2026-09-11-drawer-content-warmth.md`）：
    /// 可见性探针 ±0、正文体积 −6%、行数 −75%、列表内容全摘 −87% —— 成本几乎全在
    /// **逐行视图本身**（每行一个手势 + `contextMenu` + a11y 标签），与正文长短无关。
    ///
    /// 与压帽同族：只读环境变量、不进实例配置、默认 nil 时生产路径逐字节不变。
    enum DiagnosticMode: String {
        /// 不装可见性探针（`ClipboardVisibilityProbe`，每块一个 NSViewRepresentable
        /// + 一次 `probeAttached` → 轮询表重算 → 剪贴板读取）。
        case probeOff = "probe-off"
        /// 不渲染列表内容（一律空态）：摘掉行物化、逐行 `blockPopoverTrigger` /
        /// `contextMenu` / a11y 标签，但保留块壳（BlockCard、搜索行、筛选行）。
        case contentOff = "content-off"
        /// 行照常物化，但正文换成固定短串：把"行数"与"正文体积"这两个自变量
        /// 分开——压帽实验同时动了二者（本机历史里 5 条 HTML 正文占了 4 万字中的
        /// 3.9 万，且恰好都落在第 10 条之后），单靠压帽分不清谁重。
        case textOff = "text-off"
    }

    /// 当前诊断模式；未设置或取值非法 → nil（生产行为）。
    static var diagnosticMode: DiagnosticMode? {
        ProcessInfo.processInfo.environment["NOTCHCENTER_CLIPBOARD_DIAG"]
            .flatMap(DiagnosticMode.init(rawValue:))
    }

    /// 诊断：`textOff` 时把正文换成定长短串，其余模式原样返回。
    static func diagnosticText(_ text: String) -> String {
        diagnosticMode == .textOff ? "文本" : text
    }

    /// 启动时把生效的剪贴板诊断开关打一行，供基准日志自证"环境变量确实进了进程"
    /// ——没有这行，量测为"无差异"时无法区分"分量不贵"与"开关根本没生效"。
    /// 开关全默认时保持静默，不给生产启动留噪音。
    static func announceDiagnostics() {
        guard diagnosticRowCap != nil || diagnosticMode != nil else { return }
        print("[clipboard-diag] rowCap=\(diagnosticRowCap.map(String.init) ?? "off") "
            + "mode=\(diagnosticMode?.rawValue ?? "off")")
    }

    /// 文本能否入历史：去首尾空白后非空、字节数不超限。
    static func isRecordable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.utf8.count <= maxSingleBytes
    }

    /// 记录一条新文本：返回新数组。
    /// - 连续重复去重：与当前第一条正文相同 → 不新增（只是时间不变）。
    /// - 命中旧条（含置顶）：移到最前面并保持置顶标记，刷新时间。
    /// - 新条置顶位不变、插在置顶区之后、普通区之前。
    /// - 置顶溢出（> maxPinned）：最早置顶的一条自动解顶（保留在列表）。
    /// - 总量溢出：从末尾淘汰未置顶条；全置顶的极端情况淘汰最末置顶条。
    static func recording(_ text: String, into entries: [ClipboardEntry], now: Date = Date()) -> [ClipboardEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecordable(trimmed) else { return entries }
        if entries.first?.text == trimmed { return entries }
        var next = entries
        if let index = next.firstIndex(where: { $0.text == trimmed }) {
            var hit = next.remove(at: index)
            hit.capturedAt = now
            next.insert(hit, at: insertionIndex(forPinned: hit.pinned, in: next))
        } else {
            let entry = ClipboardEntry(text: trimmed, capturedAt: now)
            next.insert(entry, at: insertionIndex(forPinned: false, in: next))
        }
        return sanitized(next)
    }

    /// 置顶 / 解顶：置顶插到置顶区末尾；解顶落到普通区首位。返回 nil 表示条目不存在。
    static func pinning(id: UUID, pinned: Bool, in entries: [ClipboardEntry]) -> [ClipboardEntry]? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var next = entries
        var entry = next.remove(at: index)
        entry.pinned = pinned
        next.insert(entry, at: insertionIndex(forPinned: pinned, in: next))
        return sanitized(next)
    }

    /// 删除单条；id 不存在返回 nil。
    static func removing(id: UUID, from entries: [ClipboardEntry]) -> [ClipboardEntry]? {
        guard entries.contains(where: { $0.id == id }) else { return nil }
        return entries.filter { $0.id != id }
    }

    /// 清空未置顶：只删 pinned == false，置顶保留原序。
    static func clearingUnpinned(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter(\.pinned)
    }

    /// 搜索过滤：大小写不敏感 substring，范围含置顶；空查询返回全部。
    static func filtered(_ entries: [ClipboardEntry], query: String) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: 类型推断（剪贴板库页的分类维度）

    /// 允许判定为链接的 scheme（白名单，避免把 `foo:bar` 之类的伪协议当链接）。
    static let linkSchemes: Set<String> = ["http", "https", "ftp", "ftps", "mailto", "file", "ssh"]

    /// 由正文推断条目类型（纯函数）。
    ///
    /// 判定顺序：颜色 → 链接 → 文本。颜色优先是因为 `#RRGGBB` 也可能被
    /// `URL(string:)` 接受成相对引用，先判颜色可避免把色值归成链接。
    /// 链接判定要求**去掉首尾空白后整串就是一个 URL 且 scheme 在白名单内**
    /// ——含空白的整段文字不算链接（用户复制的是一段话，不是地址）。
    static func classify(text: String) -> ClipboardEntryKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }
        if isColor(trimmed) { return .color }
        if isLink(trimmed) { return .link }
        return .text
    }

    /// 是否是一个链接：整串可解析、scheme 在白名单内、且不含空白。
    static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        guard linkSchemes.contains(scheme) else { return false }
        // `http://` 这类只有 scheme 没有 host 的串不算链接。
        if scheme == "mailto" || scheme == "file" { return url.absoluteString.count > scheme.count + 3 }
        return !(url.host ?? "").isEmpty
    }

    /// 是否是一个颜色字面量：`#RGB` / `#RRGGBB` / `#RRGGBBAA` / `rgb(...)` / `rgba(...)` / `hsl(...)`。
    static func isColor(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("#") {
            let digits = lower.dropFirst()
            guard digits.allSatisfy(\.isHexDigit) else { return false }
            return digits.count == 3 || digits.count == 6 || digits.count == 8
        }
        for prefix in ["rgb(", "rgba(", "hsl(", "hsla("] where lower.hasPrefix(prefix) {
            return lower.hasSuffix(")")
        }
        return false
    }

    /// 库页的筛选+搜索：类型筛选（空集 = 全部）与关键词是**与**关系。
    ///
    /// 与 `filtered` 的区别：那个是抽屉块的"只有搜索"，这个是库页的
    /// "类型 + 搜索"双条件。保留两个入口，是为了不动抽屉块已验证的行为。
    static func libraryFiltered(
        _ entries: [ClipboardEntry],
        query: String,
        kinds: Set<ClipboardEntryKind>
    ) -> [ClipboardEntry] {
        let byKind = kinds.isEmpty ? entries : entries.filter { kinds.contains($0.kind) }
        return filtered(byKind, query: query)
    }

    /// 库页展示分组：置顶看板在前、最近列表在后（各自保持原相对顺序）。
    static func librarySections(
        _ entries: [ClipboardEntry]
    ) -> (pinned: [ClipboardEntry], recent: [ClipboardEntry]) {
        (entries.filter(\.pinned), entries.filter { !$0.pinned })
    }

    /// 显示条数档位净化：非法值回最近档。
    static func sanitizeDisplayCount(_ count: Int) -> Int {
        allowedDisplayCounts.min(by: { abs($0 - count) < abs($1 - count) }) ?? maxEntries
    }

    /// 持久化净化：超长截断（防损坏文件撑爆内存）、总量与置顶双重封顶。
    /// 置顶区保持原序、普通区保持原序后拼接，保证解码后仍满足不变量。
    static func sanitized(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        var pinned = entries.filter(\.pinned)
        var plain = entries.filter { !$0.pinned }
        if pinned.count > maxPinned {
            let overflow = pinned[maxPinned...]
            pinned = Array(pinned.prefix(maxPinned))
            // 自动解顶的条目落回普通区首位（保持相对顺序）。
            plain = Array(overflow.map { var e = $0; e.pinned = false; return e }) + plain
        }
        var combined = pinned + plain
        if combined.count > maxEntries {
            // 从末尾淘汰未置顶；全置顶时淘汰最末一条。
            var kept: [ClipboardEntry] = []
            var dropped = 0
            let overflow = combined.count - maxEntries
            for entry in combined.reversed() {
                if dropped < overflow, !entry.pinned {
                    dropped += 1
                    continue
                }
                kept.append(entry)
            }
            // 全置顶极端情况：上面的循环一件没删（dropped == 0 但仍超长），直接截断末尾。
            combined = Array(kept.reversed())
            if combined.count > maxEntries {
                combined = Array(combined.prefix(maxEntries))
            }
        }
        return combined
    }

    /// 新条 / 重排条的插入位：置顶落置顶区末尾，普通落置顶区之后（普通区首位）。
    private static func insertionIndex(forPinned _: Bool, in entries: [ClipboardEntry]) -> Int {
        entries.prefix(while: \.pinned).count
    }
}

// MARK: - 颜色字面量解析（库页色板用；纯逻辑，不依赖 AppKit）
//
// 只负责把文本解成 RGB 分量；`Color`/`NSColor` 桥接留在视图层——这样解析
// 规则可单测，且本文件在无 AppKit 的环境也能编译。

enum ClipboardColorParsing {
    /// 解析结果（0…1 分量 + 不透明度）。
    struct Components: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    /// 从文本解出颜色分量；不是可识别的颜色字面量时返回 nil。
    /// 支持 `#RGB` / `#RRGGBB` / `#RRGGBBAA` / `rgb(r,g,b)` / `rgba(r,g,b,a)`。
    static func components(from text: String) -> Components? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            return hexComponents(String(trimmed.dropFirst()))
        }
        if trimmed.hasPrefix("rgb(") || trimmed.hasPrefix("rgba(") {
            return functionComponents(trimmed)
        }
        return nil
    }

    private static func hexComponents(_ digits: String) -> Components? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        func value(_ substring: Substring) -> Double {
            Double(UInt8(substring, radix: 16) ?? 0) / 255
        }
        switch digits.count {
        case 3:
            // #RGB：每位重复一次展开成 #RRGGBB。
            let chars = Array(digits)
            func expand(_ character: Character) -> Double {
                let doubled = String([character, character])
                return Double(UInt8(doubled, radix: 16) ?? 0) / 255
            }
            return Components(red: expand(chars[0]), green: expand(chars[1]), blue: expand(chars[2]), alpha: 1)
        case 6:
            return Components(
                red: value(digits.prefix(2)),
                green: value(digits.dropFirst(2).prefix(2)),
                blue: value(digits.dropFirst(4).prefix(2)),
                alpha: 1
            )
        case 8:
            return Components(
                red: value(digits.prefix(2)),
                green: value(digits.dropFirst(2).prefix(2)),
                blue: value(digits.dropFirst(4).prefix(2)),
                alpha: value(digits.dropFirst(6).prefix(2))
            )
        default:
            return nil
        }
    }

    /// `rgb(r, g, b)` / `rgba(r, g, b, a)`：分量取 0…255 整数，alpha 取 0…1 小数。
    private static func functionComponents(_ text: String) -> Components? {
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "(") else { return nil }
        let body = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let parts = body
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let red = Double(parts[0]), let green = Double(parts[1]), let blue = Double(parts[2]) else {
            return nil
        }
        let alpha = parts.count == 4 ? (Double(parts[3]) ?? 1) : 1
        return Components(
            red: clamp(red / 255),
            green: clamp(green / 255),
            blue: clamp(blue / 255),
            alpha: clamp(alpha)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
