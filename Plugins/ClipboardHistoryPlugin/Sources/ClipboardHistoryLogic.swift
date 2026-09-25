import Foundation

// MARK: - 剪贴板历史纯逻辑（无 AppKit 依赖，供单测直调）
//
// 数据模型与全部状态变换集中于此：去重 / 置顶 / 淘汰 / 搜索过滤 / 持久化净化。
// 轮询、剪贴板读写、定时器等副作用全部留在 ClipboardHistoryStore；本文件
// 在 Linux 容器测试环境也能编译运行。

/// 条目类型（剪贴板库页的分类维度）。
///
/// 采集口径（2026-09-20 落地富媒体，决策记录 `2026-09-20-clipboard-media-types`）：
/// 五类全部可采集。文本三态（链接 / 颜色 / 文本）仍由**正文推断**；`image` / `file`
/// 由**剪贴板载荷**判定，不猜。归类优先级与"一次复制的多重表示归成哪一类"见
/// `ClipboardCapture` 的文档注释。
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

    /// 本期实际可出现的类型：五类全部可采集，筛选栏照此列举。
    static let collectable: [ClipboardEntryKind] = [.text, .link, .color, .image, .file]

    /// 载荷是否落在磁盘上（而非只在正文里）。
    ///
    /// 媒体字节预算**只对落盘类型**计账。文件条目正文里存路径串、本身不占磁盘，
    /// 所以口径按"是否落盘"划而非按"是否富媒体"划——后者会把文件路径也算进
    /// 字节账，白白挤掉真实图片的额度。
    var usesDiskStorage: Bool { self == .image }
}

/// 单条历史：正文 + 首次记录时间 + 置顶标记 + 类型相关载荷。
///
/// **向后兼容契约**：`kind` / `previewData` / `sourceApp` 是 2026-09-11 新增字段，
/// 富媒体四项（`fileURLs` / `contentHash` / `storedMediaName` / `mediaByteSize` /
/// `mediaUTI`）是 2026-09-20 新增字段，解码一律走 `decodeIfPresent` + 默认值——
/// 旧 `history.entries.v1` 数组（只有 id/text/capturedAt/pinned 四个键）必须能
/// 原样读出。因此**不要**把新字段改成非可选且无默认值的形式，也不要依赖编码器
/// 补键。
///
/// 键名沿用 `v1` 不升版：换键要写迁移与回滚处理，收益为零（决策记录
/// `2026-09-20-clipboard-media-types` 的 D10）。
struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 正文。文本三态是真正的可搜索内容；文件条目存路径串（换行连接）；
    /// 图片条目恒为空串——没有可搜的文本就是没有，不硬造描述串。
    var text: String
    var capturedAt: Date
    var pinned: Bool
    /// 条目类型（旧数据缺失 → 由正文重新推断，见 `init(from:)`）。
    var kind: ClipboardEntryKind
    /// 历史遗留的内嵌缩略图字段：新数据不再写入（图片缩略图改为落盘，见
    /// `ClipboardMediaStore`），保留解码只为旧数据兼容。
    var previewData: Data?
    /// 来源应用标识（本期仍恒 nil；1 秒轮询拿不到可靠的写入方）。
    var sourceApp: String?
    /// 文件条目的路径集合。**只持有引用**——不复制、不移动用户原文件，
    /// 因此原路径失效时条目会变成"失效态"而不是自动重定位。
    var fileURLs: [String]
    /// 图片条目的身份：原始字节的 SHA256 十六进制串。图片去重靠它，
    /// 因为正文为空串、路径也不存在。
    var contentHash: String?
    /// 图片条目在 `Media/` 目录下的落盘文件名；非图片恒 nil。
    var storedMediaName: String?
    /// 图片条目原始字节数；媒体预算的唯一计账口径。
    var mediaByteSize: Int?
    /// 图片条目原始字节的 UTI，写回时按它挂表示。
    var mediaUTI: String?

    init(
        id: UUID = UUID(),
        text: String,
        capturedAt: Date = Date(),
        pinned: Bool = false,
        kind: ClipboardEntryKind? = nil,
        previewData: Data? = nil,
        sourceApp: String? = nil,
        fileURLs: [String] = [],
        contentHash: String? = nil,
        storedMediaName: String? = nil,
        mediaByteSize: Int? = nil,
        mediaUTI: String? = nil
    ) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.pinned = pinned
        // 未显式指定类型时按正文推断，保证新建条目与旧条目走同一套判定。
        self.kind = kind ?? ClipboardHistoryLogic.classify(text: text)
        self.previewData = previewData
        self.sourceApp = sourceApp
        self.fileURLs = fileURLs
        self.contentHash = contentHash
        self.storedMediaName = storedMediaName
        self.mediaByteSize = mediaByteSize
        self.mediaUTI = mediaUTI
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case capturedAt
        case pinned
        case kind
        case previewData
        case sourceApp
        case fileURLs
        case contentHash
        case storedMediaName
        case mediaByteSize
        case mediaUTI
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
        self.fileURLs = try container.decodeIfPresent([String].self, forKey: .fileURLs) ?? []
        self.contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        self.storedMediaName = try container.decodeIfPresent(String.self, forKey: .storedMediaName)
        self.mediaByteSize = try container.decodeIfPresent(Int.self, forKey: .mediaByteSize)
        self.mediaUTI = try container.decodeIfPresent(String.self, forKey: .mediaUTI)
    }
}

/// 列表分区。视觉上不用文字标题（抽屉块走组界发丝线），只承载分组语义。
enum ClipboardSectionKind: String, Hashable, Sendable {
    case pinned
    case recent

    /// 分组文案键（抽屉块的行无障碍标签与库页的可见小节标题各自取用）。
    var titleKey: String {
        self == .pinned ? "drawer.section.pinned" : "drawer.section.recent"
    }
}

/// 列表的**扁平**元素：行与组界同属一个序列。
///
/// 为什么必须扁平：`LazyVStack` 只对**直接子项**延迟物化，而 `ForEach` 对容器透明。
/// 旧写法「`LazyVStack` → `ForEach`(节) → 节容器 → `ForEach`(行)」里 `LazyVStack` 的
/// 直接子项只有两个节，行藏在节容器内部、从未进入惰性作用范围（物化行数恒等于总行数）；
/// 同时置顶/解顶会让同一 id 在两个 `ForEach` 容器之间"搬家"，视图身份含混——旧注释
/// 记的"复用但不重刷"正是这个嵌套结构自己造的。扁平成一个序列后，行与组界共享唯一
/// 容器，身份稳定、惰性也真正落到行级。
///
/// 隔离验证见 `Experiments/ClipboardListProbe/`（A/B 台账逐字段断言跨分区移动零冲突）。
enum ClipboardListItem: Equatable, Identifiable, Sendable {
    /// 两组之间的发丝线：纯装饰（`accessibilityHidden`）。只在两节之间出现。
    case sectionBreak(ClipboardSectionKind)
    case entry(ClipboardEntry, section: ClipboardSectionKind)

    /// 全局唯一的行身份：组界走 `break.` 前缀、条目走 `entry.` 前缀。
    /// **条目 id 不含分区**——这是"跨分区移动不换身份"的前提，两个 id 空间也不得混用。
    var id: String {
        switch self {
        case .sectionBreak(let kind): return "break.\(kind.rawValue)"
        case .entry(let entry, _): return "entry.\(entry.id.uuidString)"
        }
    }

    /// 条目项解出的条目；组界为 nil。
    var entry: ClipboardEntry? {
        if case .entry(let entry, _) = self { return entry }
        return nil
    }
}

/// 一次采集读到的载荷（纯值类型，无 AppKit 依赖）。
///
/// **归类优先级**：图像数据 > 文件路径（调用方已确认文件真实存在、且非缓存回写）> 颜色 >
/// 链接 > 纯文本。
///
/// 这里看不到"图片文件"这种中间态：单个图片文件在**读端**就被 `SystemClipboardReader`
/// 直接读成图像载荷了（它持有 UTI 判定与磁盘读取）。反过来把文件路径排在图像之前的写法
/// 在 2026-09-20 被用户实测否决——复制一张 PNG 会得到一个文件名条目，既没有预览也认不出
/// 是什么；当时的理由是"用户意图是那个文件"，但实际使用里意图就是那张图。
struct ClipboardCapture: Equatable, Sendable {
    /// 纯文本表示（`.string`）。
    var text: String?
    /// 已确认存在于磁盘的文件路径（调用方负责过滤）。
    var filePaths: [String] = []
    /// 图像原始字节（未重编码）。
    var imageData: Data?
    /// 图像原始字节的 UTI。
    var imageUTI: String?
    /// 图像内容哈希（调用方计算，本文件不依赖平台哈希库）。
    var imageHash: String?

    init(
        text: String? = nil,
        filePaths: [String] = [],
        imageData: Data? = nil,
        imageUTI: String? = nil,
        imageHash: String? = nil
    ) {
        self.text = text
        self.filePaths = filePaths
        self.imageData = imageData
        self.imageUTI = imageUTI
        self.imageHash = imageHash
    }

    /// 只带文本的采集（单测与旧调用点的最常用形态）。
    init(text: String) {
        self.init(text: Optional(text))
    }
}

/// 历史变换纯函数集（共识 Q4/Q7/Q9；富媒体见 2026-09-20 决策记录）。
enum ClipboardHistoryLogic {
    /// 总容量（含置顶）。
    static let maxEntries = 50
    /// 置顶区上限。
    static let maxPinned = 5
    /// 单条上限：超长文本不记（base64 / 报错堆栈是体积爆炸主因）。
    static let maxSingleBytes = 100 * 1024
    /// 媒体总字节预算。条数上限对文本够用、对图片完全失效（50 条 × 单条上限
    /// 最坏到 GB 级），磁盘占用必须有独立上界。
    static let maxMediaBytes = 200 * 1024 * 1024
    /// 单条媒体上限：拦住"误复制了整个视频文件"。
    static let maxMediaSingleBytes = 16 * 1024 * 1024
    /// 一次复制的文件数上限：在 Finder 里选中整目录复制不该把历史撑爆。
    static let maxFileCount = 20
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

    // MARK: 采集载荷 → 条目（富媒体）

    /// 由采集载荷判定类型；载荷里没有任何可用内容时返回 nil。
    static func classify(_ capture: ClipboardCapture) -> ClipboardEntryKind? {
        // 顺序与 `ClipboardCapture` 的文档注释一致：图像排在文件之前。
        if capture.imageData?.isEmpty == false { return .image }
        if !capture.filePaths.isEmpty { return .file }
        guard let text = capture.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return classify(text: text)
    }

    /// 由采集载荷构造条目；nil 表示这份载荷不可入历史。
    ///
    /// `storedMediaName` **不在这里赋值**——它要等落盘成功才知道，由 store 回填；
    /// 图片在此已带上内容哈希与字节数，两者都来自原始字节、与落盘无关。
    static func makeEntry(from capture: ClipboardCapture, now: Date = Date()) -> ClipboardEntry? {
        guard let kind = classify(capture) else { return nil }
        switch kind {
        case .file:
            let paths = Array(capture.filePaths.prefix(maxFileCount))
            guard !paths.isEmpty else { return nil }
            // 正文存路径串（换行连接）：搜索能命中任一路径，多文件也是一条。
            return ClipboardEntry(
                text: paths.joined(separator: "\n"),
                capturedAt: now,
                kind: .file,
                fileURLs: paths
            )
        case .image:
            guard let data = capture.imageData, !data.isEmpty else { return nil }
            // 超限整份丢弃，不截断——截断过的图片没有意义，写回还会变成坏数据。
            guard data.count <= maxMediaSingleBytes else { return nil }
            // 内容哈希由调用方给出：本文件刻意不依赖平台哈希库，以保证纯逻辑层
            // 能在无 CryptoKit 的环境里编译与单测。缺哈希即视为不可记录，不退化
            // 成"按正文去重"——图片正文恒为空串，那会让所有图片合成一条。
            guard let hash = capture.imageHash, !hash.isEmpty else { return nil }
            return ClipboardEntry(
                text: "",
                capturedAt: now,
                kind: .image,
                contentHash: hash,
                mediaByteSize: data.count,
                mediaUTI: capture.imageUTI
            )
        case .text, .link, .color:
            guard let text = capture.text, isRecordable(text) else { return nil }
            return ClipboardEntry(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                capturedAt: now
            )
        }
    }

    /// 去重身份：决定两份载荷"是不是同一条"。
    ///
    /// 正文可比的类型按正文；图片必须走内容哈希（正文恒空，靠正文会把所有图片
    /// 合成一条）；文件按路径集合（同一个文件再复制一次应当顶到最前而非新增）。
    static func matchKey(_ entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image: return "image:\(entry.contentHash ?? "")"
        case .file: return "file:\(entry.fileURLs.joined(separator: "\n"))"
        case .text, .link, .color: return "text:\(entry.text)"
        }
    }

    /// 该条目是否已在历史里（同身份）。
    ///
    /// 与 `recording(_:into:now:)` 里的同款判断分开存在，是因为调用方需要在
    /// **落盘之前**知道答案：命中已有图片时不该为它白写一份文件。
    static func contains(_ entry: ClipboardEntry, in entries: [ClipboardEntry]) -> Bool {
        let key = matchKey(entry)
        return entries.contains { matchKey($0) == key }
    }

    /// 单条的磁盘占用。只有落盘类型计入；文件条目的路径串不计（它不占磁盘）。
    static func mediaByteSize(of entry: ClipboardEntry) -> Int {
        guard entry.kind.usesDiskStorage else { return 0 }
        return entry.mediaByteSize ?? 0
    }

    /// 媒体预算准入：**只有"置顶自身就已超预算"这一种情况会拒收**。
    ///
    /// 未超预算时新条必定活下来：它插在未置顶区首位，而 `sanitized` 的预算淘汰
    /// 从末尾（最老）开始，先被淘汰的永远轮不到它。所以这里不需要试算整轮淘汰。
    static func admitsMedia(_ entry: ClipboardEntry, into entries: [ClipboardEntry]) -> Bool {
        guard entry.kind.usesDiskStorage else { return true }
        let pinnedBytes = entries.reduce(0) { total, item in
            item.pinned ? total + mediaByteSize(of: item) : total
        }
        return pinnedBytes <= maxMediaBytes
    }

    /// 记录一次复制（只带文本的旧入口，等价于文本形态的采集）。
    static func recording(_ text: String, into entries: [ClipboardEntry], now: Date = Date()) -> [ClipboardEntry] {
        recording(ClipboardCapture(text: text), into: entries, now: now)
    }

    /// 记录一次采集：载荷先过 `makeEntry`，再走条目入口。nil 载荷不记录。
    static func recording(
        _ capture: ClipboardCapture,
        into entries: [ClipboardEntry],
        now: Date = Date()
    ) -> [ClipboardEntry] {
        guard let entry = makeEntry(from: capture, now: now) else { return entries }
        return recording(entry, into: entries, now: now)
    }

    /// 记录一条**已构造好**的条目：返回新数组。
    ///
    /// 独立入口的存在理由是 `storedMediaName`：它要等磁盘写成功才知道，只能在
    /// 条目构造之后由 store 回填，所以 store 拿到的是"条目"而不是"载荷"。
    /// - 连续重复去重：与当前第一条**同身份** → 不新增（只是时间不变）。
    /// - 命中旧条（含置顶）：移到最前面并保持置顶标记，刷新时间。
    /// - 新条置顶位不变、插在置顶区之后、普通区之前。
    /// - 置顶溢出（> maxPinned）：最早置顶的一条自动解顶（保留在列表）。
    /// - 总量溢出：从末尾淘汰未置顶条；全置顶的极端情况淘汰最末置顶条。
    /// - 媒体预算溢出：见 `sanitized`；仅置顶就已超预算时由 `admitsMedia` 停收。
    static func recording(
        _ entry: ClipboardEntry,
        into entries: [ClipboardEntry],
        now: Date = Date()
    ) -> [ClipboardEntry] {
        let key = matchKey(entry)
        if let first = entries.first, matchKey(first) == key { return entries }
        var next = entries
        if let index = next.firstIndex(where: { matchKey($0) == key }) {
            // 命中旧条：不新增字节，预算无需再过一遍（否则重新复制一条置顶图片
            // 会因"置顶已超预算"被拒，而它其实什么都没多占）。
            var hit = next.remove(at: index)
            hit.capturedAt = now
            next.insert(hit, at: insertionIndex(forPinned: hit.pinned, in: next))
        } else {
            guard admitsMedia(entry, into: entries) else { return entries }
            var inserted = entry
            inserted.capturedAt = now
            next.insert(inserted, at: insertionIndex(forPinned: false, in: next))
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

    // MARK: 自动清理

    /// 自动清理是否已到点。
    ///
    /// `lastRunAt` 为 nil（首次启用 / 从无此设置的老版本升上来）时**从此刻起算**：
    /// 判定必然为"未到点"，因此首装与升级都不会立刻清掉存量历史；时间戳由 store
    /// 在同一个判定点落盘（决策记录 `2026-09-25-clipboard-auto-cleanup` 的 D4）。
    static func isCleanupDue(
        period: ClipboardAutoCleanupPeriod,
        lastRunAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let due = period.nextDue(from: lastRunAt ?? now, calendar: calendar) else { return false }
        return now >= due
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

    // MARK: 列表项模型（两个列表共用的扁平化契约）

    /// 把分区后的条目拍成扁平列表：置顶段在前、最近段在后，组界只在两段之间。
    /// 某一区为空时不产生组界（与旧视图 `showsTopDivider: index > 0` 的呈现一致）。
    static func listItems(
        pinned: [ClipboardEntry],
        recent: [ClipboardEntry]
    ) -> [ClipboardListItem] {
        var items = pinned.map { ClipboardListItem.entry($0, section: .pinned) }
        if !pinned.isEmpty, !recent.isEmpty {
            items.append(.sectionBreak(.recent))
        }
        items.append(contentsOf: recent.map { ClipboardListItem.entry($0, section: .recent) })
        return items
    }

    /// 显示条数档位净化：非法值回最近档。
    static func sanitizeDisplayCount(_ count: Int) -> Int {
        allowedDisplayCounts.min(by: { abs($0 - count) < abs($1 - count) }) ?? maxEntries
    }

    /// 持久化净化：总量与置顶双重封顶、媒体字节预算兜底。
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
        return applyingMediaBudget(combined)
    }

    /// 媒体预算淘汰：从**最老**的未置顶落盘条目开始删，直到总字节回到预算内。
    ///
    /// 置顶条目永不因预算被淘汰——那等于让预算拥有"静默解顶"的权力，而置顶是
    /// 用户的显式意图。所以仅置顶就已超预算时，本函数原样返回（超预算状态由
    /// `admitsMedia` 在入口挡住新条目，不会再恶化）。淘汰顺序与条数淘汰同为
    /// "从末尾、只动未置顶"，两条不变量方向一致。
    private static func applyingMediaBudget(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        var remaining = entries.reduce(0) { $0 + mediaByteSize(of: $1) }
        guard remaining > maxMediaBytes else { return entries }
        var kept: [ClipboardEntry] = []
        for entry in entries.reversed() {
            let size = mediaByteSize(of: entry)
            if remaining > maxMediaBytes, size > 0, !entry.pinned {
                remaining -= size
                continue
            }
            kept.append(entry)
        }
        return Array(kept.reversed())
    }

    /// 新条 / 重排条的插入位：置顶落置顶区末尾，普通落置顶区之后（普通区首位）。
    private static func insertionIndex(forPinned _: Bool, in entries: [ClipboardEntry]) -> Int {
        entries.prefix(while: \.pinned).count
    }
}

// MARK: - 自动清理档位（纯逻辑，可单测）
//
// 档位语义见决策记录 2026-09-25-clipboard-auto-cleanup：周期是**清理频率**而不是
// 保留时长（每周 = 每周清一次，清掉当时全部未置顶），判定用日历加法，「关闭」档
// 让不想被自动删数据的人有出口。

enum ClipboardAutoCleanupPeriod: String, Codable, CaseIterable, Sendable {
    case off
    case daily
    case weekly
    case monthly

    /// 未设置过（新装 / 从无此设置的老版本升上来）时的档位。
    static let defaultPeriod: ClipboardAutoCleanupPeriod = .weekly

    /// 设置界面的档位顺序：先给"不想要"的人一个出口，再按周期由短到长。
    static let selectable: [ClipboardAutoCleanupPeriod] = [.off, .daily, .weekly, .monthly]

    /// 档位文案键。
    var localizationKey: String { "settings.autoCleanup.\(rawValue)" }

    /// 周期长度（**日历单位**，不是固定秒数）；关闭档为 nil。
    private var components: DateComponents? {
        switch self {
        case .off: return nil
        case .daily: return DateComponents(day: 1)
        case .weekly: return DateComponents(day: 7)
        case .monthly: return DateComponents(month: 1)
        }
    }

    /// 日历加法返回 nil 时的回落秒数（正常路径不走到，纯兜底）。
    private var fallbackInterval: TimeInterval {
        switch self {
        case .off: return 0
        case .daily: return 86_400
        case .weekly: return 604_800
        case .monthly: return 2_592_000
        }
    }

    /// 从 `date` 起算一个周期后的到期时刻；关闭档返回 nil（永不到期）。
    ///
    /// 用日历加法：「每月」按日历月走，跨 2 月、跨夏令时才不会漂。
    func nextDue(from date: Date, calendar: Calendar = .current) -> Date? {
        guard let components else { return nil }
        return calendar.date(byAdding: components, to: date) ?? date.addingTimeInterval(fallbackInterval)
    }

    /// 持久化字符串 → 档位。缺失或非法一律回**默认档**：既不是"静默变关闭"
    /// （那会让自动清理神秘失灵），也不是"抛错让 store 崩"。
    static func sanitize(_ rawValue: String?) -> ClipboardAutoCleanupPeriod {
        rawValue.flatMap(ClipboardAutoCleanupPeriod.init(rawValue:)) ?? defaultPeriod
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
