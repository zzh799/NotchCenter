import AppKit
import Combine
import Foundation
import NotchCenterKit
import UniformTypeIdentifiers

// MARK: - 文件载荷的取舍（纯函数，可单测；不触碰剪贴板）

/// 复制的是文件时，哪些当图像读、哪些当路径收、哪些直接丢掉。
///
/// 抽出来的理由：`SystemClipboardReader` 会碰真实 `NSPasteboard`（测试红线不许碰），
/// 而下面两条规则只吃路径。规则本身带着取舍，必须能被断言。
enum ClipboardFilePayloadPolicy {
    /// 系统缓存根目录（`~/Library/Caches`）。测试可注入别的根，不依赖真实目录。
    static var systemCachesRoot: String? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
    }

    /// 路径是否落在"程序自建的可丢弃缓存区"里。
    ///
    /// 判据只有一条 `~/Library/Caches/`，不是启发式打分：该目录的系统语义就是"程序自建、
    /// 可随时删除、不是用户资产"，用户不会从那里复制文件——出现在剪贴板上的缓存路径必然
    /// 是某个进程自己回写的中间产物。实测（见决策记录 2026-09-20-clipboard-image-file-and-cache-echo
    /// 与 `Experiments/ClipboardPasteboardProbe/`）：微信输入法把剪贴板里的图缓存到
    /// `~/Library/Caches/WeType/dsclp/<epoch>.png`，约 1.8 秒后把剪贴板改成只指向该缓存，
    /// 于是"一次复制"被记成两条；而它重编码过（连像素指纹都不同），所以内容等价去重救不了，
    /// 只能在来源处拦。
    static func isDisposableCachePath(_ path: String, cachesRoot: String? = systemCachesRoot) -> Bool {
        guard let cachesRoot, !cachesRoot.isEmpty else { return false }
        let root = cachesRoot.hasSuffix("/") ? String(cachesRoot.dropLast()) : cachesRoot
        return path == root || path.hasPrefix(root + "/")
    }

    /// 单个文件且它的类型是图片 → 返回该 UTI（调用方据此去读文件字节）；否则 nil。
    ///
    /// 只看扩展名映射出的 UTType，不做内容嗅探：扩展名就是用户在 Finder 里看到的那个，
    /// 判定与用户认知一致；内容嗅探还得先读文件，等于为"可能不是图片"白付一次 IO。
    static func imageUTIForSingleFile(at path: String) -> String? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              type.conforms(to: .image) else { return nil }
        return type.identifier
    }
}

// MARK: - 剪贴板读取抽象（单测注入假剪贴板，绝不触碰真实 NSPasteboard）
//
// 采集刻意分成两段（决策记录 2026-09-20-clipboard-media-types 的 D3）：
// `probe()` 只读变化计数与类型名表，**不读任何载荷字节**；只有确认这是一次值得
// 记录的复制（计数变了、非自循环、未暂停、非 transient）之后才走 `readPayload()`
// 读重数据。富媒体落地后这一步是硬要求而非优化——每拍直接读图像数据，等于给常驻
// 的宿主每 0.5 秒拷贝数 MB。门控判定见 `ClipboardHistoryLogic.pollDecision`，
// 两段的编排见 `ClipboardPoller`。

/// 轻探测结果：变化计数 + 类型名表（transient / concealed 判定用）。
struct ClipboardProbe: Equatable, Sendable {
    var changeCount: Int
    var typeNames: [String]

    init(changeCount: Int, typeNames: [String] = []) {
        self.changeCount = changeCount
        self.typeNames = typeNames
    }
}

/// 一次变化对应的载荷（按归类优先级最多填一项，见 `ClipboardCapture`）。
struct ClipboardPayload: Equatable, Sendable {
    var text: String?
    var filePaths: [String] = []
    var imageData: Data?
    var imageUTI: String?

    init(
        text: String? = nil,
        filePaths: [String] = [],
        imageData: Data? = nil,
        imageUTI: String? = nil
    ) {
        self.text = text
        self.filePaths = filePaths
        self.imageData = imageData
        self.imageUTI = imageUTI
    }
}

/// 剪贴板读写协议：生产实现走 NSPasteboard.general，测试用假实现。
protocol ClipboardReading: Sendable {
    func probe() -> ClipboardProbe
    func readPayload() -> ClipboardPayload
    /// 写回纯文本。返回写完后的 changeCount（调用方记快照跳过自循环）。
    func writeText(_ text: String) -> Int
    /// 写回文件引用，**一个文件一个 pasteboard item**。
    func writeFiles(_ paths: [String]) -> Int
    /// 写回图像原始字节。
    func writeImage(data: Data, uti: String?) -> Int
}

/// 生产实现：读纯文本 / 文件引用 / 图像原始字节。
///
/// 图像**不做格式收敛**（不转 PNG、不转 TIFF）：写回的契约是把用户当时复制的东西
/// 原样放回，重编码既毁契约又会让 JPEG 来源的图片膨胀。因此读也只取原始字节。
///
/// NSPasteboard 非 Sendable，按 NotesImageStore 同款 `@unchecked Sendable` +
/// NSLock 模式经后台线程访问。
final class SystemClipboardReader: ClipboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let lock = NSLock()

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func probe() -> ClipboardProbe {
        lock.lock()
        defer { lock.unlock() }
        return ClipboardProbe(
            changeCount: pasteboard.changeCount,
            typeNames: pasteboard.types?.map(\.rawValue) ?? []
        )
    }

    func readPayload() -> ClipboardPayload {
        lock.lock()
        defer { lock.unlock() }
        // 顺序即归类优先级：文件（已确认存在且非缓存回写）> 图像 > 文本。
        if let paths = Self.existingFilePaths(on: pasteboard), !paths.isEmpty {
            if let image = Self.imageFilePayload(for: paths) { return image }
            return ClipboardPayload(filePaths: paths)
        }
        if let image = Self.image(on: pasteboard) {
            return ClipboardPayload(imageData: image.data, imageUTI: image.uti)
        }
        return ClipboardPayload(text: pasteboard.string(forType: .string))
    }

    func writeText(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func writeFiles(_ paths: [String]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        // 一个文件一个 item：Finder 只读第一条 item，把多个 URL 塞进同一个 item
        // 会**静默**丢掉后面的文件（不报错，粘出来才发现少了）。
        pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        return pasteboard.changeCount
    }

    func writeImage(data: Data, uti: String?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        for type in Self.imagePasteboardTypes(for: data, uti: uti) {
            pasteboard.setData(data, forType: type)
        }
        return pasteboard.changeCount
    }

    // MARK: 载荷读取

    /// 剪贴板上的文件路径（去重、只保留真实存在的、剔除缓存回写）。
    ///
    /// 不存在的不返回：文件条目是**路径引用**，不复制用户原文件（见
    /// `docs/agents/插件开发约定.md`），所以记下一条写不回去的路径没有意义。
    private static func existingFilePaths(on pasteboard: NSPasteboard) -> [String]? {
        guard pasteboard.availableType(from: [.fileURL]) != nil else { return nil }
        let urls = pasteboard.pasteboardItems?.compactMap { item -> URL? in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else { return nil }
            return url.standardizedFileURL
        } ?? []
        var seen = Set<String>()
        let existing = urls.filter { url in
            guard seen.insert(url.path).inserted else { return false }
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            return !ClipboardFilePayloadPolicy.isDisposableCachePath(url.path)
        }
        return existing.map(\.path)
    }

    /// 单个图片文件 → 读它的字节当图像载荷；其余情况返回 nil（按文件引用收）。
    ///
    /// 读**文件字节**而不是剪贴板上现成的图像数据：Finder 复制图片文件时会附带
    /// `public.tiff`，那可能是文件图标而不是图像本身，文件字节才是权威内容。
    private static func imageFilePayload(for paths: [String]) -> ClipboardPayload? {
        guard paths.count == 1,
              let path = paths.first,
              let uti = ClipboardFilePayloadPolicy.imageUTIForSingleFile(at: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty else { return nil }
        // 超媒体单条上限：退回文件引用而不是整个丢弃——否则用户连"复制过这个文件"都看不到。
        guard data.count <= ClipboardHistoryLogic.maxMediaSingleBytes else { return nil }
        return ClipboardPayload(imageData: data, imageUTI: uti)
    }

    /// 图像原始字节：优先 png / tiff，其次任何声明为 `public.image` 的类型。
    ///
    /// 兜底那一步是为了不让"只挂 jpeg 的 App"变成静默不记录；上限由逻辑层的
    /// `maxMediaSingleBytes` 兜住，这里不做体积判断。
    private static func image(on pasteboard: NSPasteboard) -> (data: Data, uti: String)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            return (data, type.rawValue)
        }
        let fallback = pasteboard.types?.first { type in
            UTType(type.rawValue)?.conforms(to: .image) == true
        }
        guard let fallback,
              let data = pasteboard.data(forType: fallback),
              !data.isEmpty else { return nil }
        return (data, fallback.rawValue)
    }

    /// 写回时挂哪些表示：原始 UTI，外加能由魔数确认的同格式标准类型别名。
    ///
    /// 刻意**不**生成对侧表示（PNG ↔ TIFF）：那需要整图解码，而接收方自行转换
    /// 是系统常态。别名走魔数嗅探，零解码成本。
    private static func imagePasteboardTypes(for data: Data, uti: String?) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = []
        if let uti, !uti.isEmpty, UTType(uti) != nil {
            types.append(NSPasteboard.PasteboardType(rawValue: uti))
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            types.append(.png)
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            types.append(.tiff)
        }
        return types.isEmpty ? [.tiff] : Array(Set(types))
    }
}

// MARK: - 插件级共享历史引擎
//
// 与 SystemMonitor/Pomodoro 同构：插件级**单例** ObservableObject，全部块视图
// 观察同一份历史（剪贴板历史与放置实例无关；多屏多副本零额外轮询）。
//
// 采集**常驻**：随插件启用（attach）到禁用（suspend）之间持续轮询，节拍与线程细节
// 全在 ClipboardPoller（专用后台队列 + 固定 0.5s）。刻意不再按抽屉可见性 / 放置实例
// 分档或停表——2026-09-28 事故：登记绑在块视图挂载上，而抽屉温存只 300s，收起满 300s
// 视图卸载即停表、复制全丢；从未展开抽屉则从不开始。决策见
// `docs/agent-notes/implemented/2026-09-28-clipboard-resident-fast-polling.md`。
//
// 另有**独立于轮询**的自动清理检查表（60s 一次日期比较，attach → suspend），
// 理由见 `startCleanupTimer`。
//
// 隐私（共识 Q2）：transient 启发式跳过 + 全局暂停 + 暂停期不补记；暂停态持久化，
// 重启后保持暂停（避免重启瞬间把用户不想记的内容记下来）。门控在轮询队列上、
// 读载荷之前完成（见 `ClipboardHistoryLogic.pollDecision`）。

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    /// 落盘键（插件级 stateStore，单文件有序数组）。
    static let historyStoreKey = "history.entries.v1"
    static let pausedStoreKey = "history.paused"
    /// 自动清理档位键（存 `ClipboardAutoCleanupPeriod` 的 rawValue）。
    static let autoCleanupPeriodStoreKey = "cleanup.period"
    /// 上次自动清理时刻键。首次启用只落"起算时刻"、不清理（见 attach）。
    static let autoCleanupLastRunStoreKey = "cleanup.lastRunAt"
    /// 自动清理检查节拍：清理粒度是天，60s 一次的日期比较成本可忽略，
    /// 但让"到点"最多晚一分钟生效。
    static let cleanupCheckInterval: TimeInterval = 60

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isPaused = false
    /// 自动清理档位（**全局设置**：历史是插件级共享的，不按放置实例区分）。
    @Published private(set) var autoCleanupPeriod: ClipboardAutoCleanupPeriod = .defaultPeriod
    /// 当前剪贴板内容对应的历史条目 id（持续高亮语义：高亮始终标记"内容等于
    /// 当前剪贴板的那条"，对不上任何条目时为 nil）。由离散事件维护，见
    /// `copyBack` / `handle` / `attach`；不做内容级轮询。
    @Published private(set) var currentClipboardEntryID: UUID?
    /// 最近一次**写回被拒**的条目 id（文件条目的原路径已失效；视图据此显示失效态）。
    @Published private(set) var copyFailedID: UUID?

    private let reader: any ClipboardReading
    /// 与轮询队列共享的采集状态（计数 / 写回快照 / 暂停 / 运行）。
    private let pollState: ClipboardPollState
    /// 轮询引擎（专用后台队列）。
    private let poller: ClipboardPoller
    private var stateStore: StateStore?
    /// 富媒体磁盘存储；初始化失败时为 nil，此时富媒体一律不记录（正文仍照常）。
    private var mediaStore: ClipboardMediaStore?
    private var isActive = false
    /// 自动清理检查表（独立于轮询，见 startCleanupTimer）。
    private var cleanupTimer: Timer?
    /// 上次自动清理时刻；nil 表示本次会话尚未起算（attach 会落到"此刻起算"）。
    private var lastAutoCleanupAt: Date?

    /// 失效闪示（copyFailedID）的清除任务。
    private var highlightTask: Task<Void, Never>?

    init(reader: any ClipboardReading = SystemClipboardReader()) {
        self.reader = reader
        let pollState = ClipboardPollState()
        self.pollState = pollState
        self.poller = ClipboardPoller(reader: reader, state: pollState)
        // 采集结论回主线程的唯一入口（poller 已在主线程上回调）。
        poller.onOutcome = { [weak self] outcome in self?.handle(outcome) }
    }

    /// 采集表是否在跑（internal 供测试断言）。
    var isPolling: Bool { poller.isRunning }

    // MARK: 生命周期

    /// 装载插件数据并（默认）启动常驻轮询。
    ///
    /// `startPolling: false` 仅供测试：状态机用例要确定性，不能被后台表在跑用例期间
    /// 偷偷记录污染。
    func attach(stateStore: StateStore, startPolling: Bool = true) {
        self.stateStore = stateStore
        mediaStore = try? ClipboardMediaStore(stateStore: stateStore)
        // 采集重活（哈希 + 媒体落盘）下沉到轮询队列，主线程只做记账。
        poller.prepareCapture = Self.makeCapturePreparer(mediaStore: mediaStore)
        entries = ClipboardHistoryLogic.sanitized(
            stateStore.object([ClipboardEntry].self, forKey: Self.historyStoreKey) ?? []
        )
        isPaused = stateStore.object(Bool.self, forKey: Self.pausedStoreKey) ?? false
        autoCleanupPeriod = ClipboardAutoCleanupPeriod.sanitize(
            stateStore.object(String.self, forKey: Self.autoCleanupPeriodStoreKey)
        )
        lastAutoCleanupAt = stateStore.object(Date.self, forKey: Self.autoCleanupLastRunStoreKey)
        if lastAutoCleanupAt == nil {
            // 首次启用（新装 / 从无此设置的老版本升上来）**只起算、不清理**：否则
            // 升级当天就会把存量历史清掉，是最坏的意外删除。
            lastAutoCleanupAt = Date()
            persistAutoCleanupLastRun()
        }
        // 孤儿对账必须在 entries 定型之后：净化可能淘汰掉带媒体的条目，那些文件
        // 此刻正好变成无人引用的孤儿。顺序反了会把仍被引用的文件删掉。
        mediaStore?.reconcile(referenced: Set(entries.compactMap(\.storedMediaName)))
        // 轮询引擎与用户状态对齐：暂停态 + 启动即认领当前计数（避免把宿主启动前的
        // 旧剪贴板当"新复制"记一条；睡眠 / 锁屏唤醒同理收敛）。
        pollState.setPaused(isPaused)
        poller.reseed()
        isActive = true
        if startPolling { poller.start() }
        // 启动对齐：把"当前剪贴板内容"对上历史条目（持续高亮语义），见
        // `syncCurrentEntryMatch`。
        syncCurrentEntryMatch()
        // 清理检查与"用户看不看得到"无关：起表 + 启动补算（进程退出期间跨过到期点
        // 的情况靠这一下收敛）。
        startCleanupTimer()
        runAutoCleanupIfDue()
    }

    func suspend() {
        isActive = false
        poller.stop()
        stopCleanupTimer()
        highlightTask?.cancel()
        highlightTask = nil
    }

    // MARK: 轮询与记录（采集在 ClipboardPoller 的专用队列上完成，本层只消化结论）

    /// 消化采集结论（internal 供测试直注）。
    func handle(_ outcome: ClipboardPoller.Outcome) {
        guard isActive else { return }
        switch outcome {
        case .unchanged, .selfLoop:
            // 自循环（我们自己的写回）已在采集层认领，高亮由 copyBack 直接维护，不动。
            break
        case .clearHighlight:
            // 剪贴板变了但这次变化不会被记录（暂停 / transient）：当前内容已不可知、
            // 不再对应任何条目，持续高亮随之消失。
            currentClipboardEntryID = nil
        case .captured(let prepared):
            record(prepared)
        }
    }

    /// 采集重活的底座：算图片哈希 + 把原图与缩略图预落盘。
    ///
    /// 返回的闭包由 `ClipboardPoller` 在轮询专用队列上调用，因此 SHA256、
    /// `CGImageSource` 缩略图解码与磁盘写入都不落主线程。
    private static func makeCapturePreparer(
        mediaStore: ClipboardMediaStore?
    ) -> @Sendable (ClipboardPayload) -> PreparedCapture {
        { payload in
            var prepared = PreparedCapture(payload: payload)
            guard let data = payload.imageData else { return prepared }
            prepared.imageHash = ClipboardMediaStore.contentHash(of: data)
            prepared.storedMediaName = mediaStore?.store(data: data, uti: payload.imageUTI)
            return prepared
        }
    }

    /// 同步跑一拍采集并作用到状态机（**仅供测试直注**；生产由 poller 的计时器驱动）。
    func pollNow() {
        handle(poller.pollOnce())
    }

    /// 消化一次值得记录的载荷（internal 供测试直注）。
    ///
    /// 哈希与媒体落盘已在采集队列上完成（见 `PreparedCapture`），这里只剩主线程记账。
    func record(_ prepared: PreparedCapture) {
        guard isActive, !isPaused else { return }
        let payload = prepared.payload
        var capture = ClipboardCapture(
            text: payload.text,
            filePaths: payload.filePaths,
            imageData: payload.imageData,
            imageUTI: payload.imageUTI
        )
        capture.imageHash = prepared.imageHash
        guard var entry = ClipboardHistoryLogic.makeEntry(from: capture) else {
            // 载荷无可用内容（如剪贴板被清空）：预写的媒体文件无人引用，就地回收。
            if let written = prepared.storedMediaName {
                mediaStore?.remove(storedNames: [written])
            }
            currentClipboardEntryID = nil
            return
        }
        var writtenMediaName: String?
        if entry.kind == .image, !ClipboardHistoryLogic.contains(entry, in: entries) {
            // 媒体已在采集队列上预落盘，这里只认领。落盘失败则与旧行为一致：不入库。
            guard let name = prepared.storedMediaName else { return }
            entry.storedMediaName = name
            writtenMediaName = name
        } else if let speculative = prepared.storedMediaName {
            // 重复内容（图片去重命中）不需要新文件，回收预写的那份。
            mediaStore?.remove(storedNames: [speculative])
        }
        let next = ClipboardHistoryLogic.recording(entry, into: entries)
        guard next != entries else {
            // 被去重或预算停收：刚写的文件没有任何条目引用，就地回收，不等下次启动。
            if let writtenMediaName { mediaStore?.remove(storedNames: [writtenMediaName]) }
            // 去重命中（含"与第一条同身份"的原样返回）：剪贴板内容就在那条上，
            // 高亮命中条；预算停收则匹配不到，置 nil。
            currentClipboardEntryID = currentEntryID(matching: entry, in: next)
            return
        }
        commit(next)
        // 本次记录的内容此刻就在剪贴板上：高亮随之转移到对应条（新条或被顶前的旧条）。
        currentClipboardEntryID = currentEntryID(matching: entry, in: next)
    }

    /// 与给定条目**同内容身份**（`matchKey`）的历史条目 id；对不上返回 nil。
    ///
    /// 匹配身份与去重同源（文本按正文 / 图片按内容哈希 / 文件按路径集合），不另造
    /// 第二套"内容是否相同"的判定——两套判定必然漂移。
    private func currentEntryID(matching entry: ClipboardEntry, in list: [ClipboardEntry]) -> UUID? {
        let key = ClipboardHistoryLogic.matchKey(entry)
        return list.first(where: { ClipboardHistoryLogic.matchKey($0) == key })?.id
    }

    /// attach 时的启动对齐：把当前剪贴板内容匹配到历史条目上。
    ///
    /// 启动时剪贴板里大概率是历史里已有的内容（上次会话复制的），不读一次载荷的
    /// 话，直到下一次复制前都没有高亮，违背"始终高亮当前内容"的语义。只读这一次：
    /// 常规轮询在专用队列上完成门控与读载荷。transient / concealed 内容刻意不读
    /// （隐私红线与轮询同源），直接无高亮。
    private func syncCurrentEntryMatch() {
        let probe = reader.probe()
        guard !ClipboardHistoryLogic.isTransient(typeNames: probe.typeNames) else {
            currentClipboardEntryID = nil
            return
        }
        let captured = reader
        let count = probe.changeCount
        Task.detached(priority: .utility) { [weak self] in
            let payload = captured.readPayload()
            await MainActor.run { [weak self] in
                self?.applyCurrentEntryMatch(from: payload, changeCount: count)
            }
        }
    }

    /// 由载荷对齐"当前剪贴板内容"的高亮条（internal 供测试直注；生产走
    /// `syncCurrentEntryMatch` 的异步壳）。`changeCount` 是发起读取时见到的计数：
    /// 读载荷期间剪贴板又变了的话，这份快照过期，直接丢弃，交给后续轮询收口。
    func applyCurrentEntryMatch(from payload: ClipboardPayload, changeCount: Int) {
        guard pollState.latestChangeCount == changeCount else { return }
        var capture = ClipboardCapture(
            text: payload.text,
            filePaths: payload.filePaths,
            imageData: payload.imageData,
            imageUTI: payload.imageUTI
        )
        if let data = payload.imageData {
            capture.imageHash = ClipboardMediaStore.contentHash(of: data)
        }
        guard let entry = ClipboardHistoryLogic.makeEntry(from: capture) else {
            currentClipboardEntryID = nil
            return
        }
        currentClipboardEntryID = currentEntryID(matching: entry, in: entries)
    }

    // MARK: 用户操作

    /// 点击写回：按类型把内容放回剪贴板 + 请轮询认作自循环 + 高亮该条。
    /// 返回 false 表示写回被拒（文件条目的原路径已全部失效）。
    @discardableResult
    func copyBack(_ entry: ClipboardEntry) -> Bool {
        // 写回期间置互斥标记：免得这一拍把宿主自己的写回当成一次外部复制记下来。
        pollState.beginWrite()
        guard let count = writeToPasteboard(entry) else {
            pollState.cancelWrite()
            flashCopyFailure(entry.id)
            return false
        }
        // 置写回快照 + 前移计数：轮询下一拍凭它认出这次变化是自循环、只认领不记录。
        poller.acknowledgeWriteBack(count)
        copyFailedID = nil
        // 持续高亮：写回成功后该条就是"当前剪贴板内容"，直到内容再变。
        currentClipboardEntryID = entry.id
        return true
    }

    /// 把条目内容放回剪贴板；返回写完后的计数，nil 表示不该写。
    ///
    /// 文件条目**要么整组写回、要么不写**：只写存活的那几个会让用户以为复制了
    /// 3 个、实际只拿到 2 个，正是本决策要消灭的静默丢失。
    private func writeToPasteboard(_ entry: ClipboardEntry) -> Int? {
        switch entry.kind {
        case .file:
            // 文件条目是路径引用，原文件可能在复制之后被移动或删除。项目红线是
            // 不复制、不移动、不删除用户原文件（见 docs/agents/插件开发约定.md），
            // 所以这里只能校验、不能拷贝副本保活。
            guard !entry.fileURLs.isEmpty,
                  entry.fileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                return nil
            }
            return reader.writeFiles(entry.fileURLs)
        case .image:
            guard let name = entry.storedMediaName,
                  let data = mediaStore?.data(forStoredName: name) else { return nil }
            return reader.writeImage(data: data, uti: entry.mediaUTI)
        case .text, .link, .color:
            return reader.writeText(entry.text)
        }
    }

    func togglePin(id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        guard let next = ClipboardHistoryLogic.pinning(id: id, pinned: !entry.pinned, in: entries) else { return }
        commit(next)
    }

    func delete(id: UUID) {
        guard let next = ClipboardHistoryLogic.removing(id: id, from: entries) else { return }
        commit(next)
        pruneCopyFeedback(keeping: next)
    }

    func clearUnpinned() {
        let next = ClipboardHistoryLogic.clearingUnpinned(entries)
        guard next != entries else { return }
        commit(next)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        try? stateStore?.setObject(paused, forKey: Self.pausedStoreKey)
        // 暂停期不补记（共识 Q10）：采集门控读的是这个镜像，暂停期间每一拍都只认领
        // 计数、不读载荷；恢复后从"当前计数"往后记，不会把暂停期间的变化补进来。
        pollState.setPaused(paused)
    }

    // MARK: 自动清理（档位语义见 ClipboardAutoCleanupPeriod）

    /// 改档：落盘并**从此刻重新起算**，不立刻清一次。
    ///
    /// "改完立刻执行"会把这一项变成隐形删除按钮（用户顺手试一下档位就丢历史），
    /// 代价只是新档位的首次执行晚一个周期。
    func setAutoCleanupPeriod(_ period: ClipboardAutoCleanupPeriod) {
        guard autoCleanupPeriod != period else { return }
        autoCleanupPeriod = period
        try? stateStore?.setObject(period.rawValue, forKey: Self.autoCleanupPeriodStoreKey)
        lastAutoCleanupAt = Date()
        persistAutoCleanupLastRun()
    }

    /// 到点则清一次。定时器每个节拍调一次，测试可直注 `now`。
    func runAutoCleanupIfDue(now: Date = Date()) {
        guard ClipboardHistoryLogic.isCleanupDue(
            period: autoCleanupPeriod,
            lastRunAt: lastAutoCleanupAt,
            now: now
        ) else { return }
        performAutoCleanup(now: now)
    }

    /// 执行一次清理：删除全部**未置顶**条目（置顶恒保留）、落盘、记时刻。
    ///
    /// 走 `clearingUnpinned` + `commit`——与手工「清空未置顶」是同一套实现，
    /// 被清图片的文件由 `commit` 连带回收；另写一条删除路径会留下孤儿图片文件。
    /// internal 供测试直调。
    func performAutoCleanup(now: Date = Date()) {
        // 先记时刻再删：两个副作用彼此独立，"这次到期已被消费"必须无条件落盘。
        // 反过来写的话，"没有未置顶可删"的早退会跳过时间戳，于是每个节拍都重判到期。
        lastAutoCleanupAt = now
        persistAutoCleanupLastRun()
        let next = ClipboardHistoryLogic.clearingUnpinned(entries)
        guard next != entries else { return }
        commit(next)
        pruneCopyFeedback(keeping: next)
    }

    // MARK: 视图支撑

    /// 条目缩略图的落盘路径；非图片返回 nil。
    ///
    /// 只做纯路径拼接、**不校验文件是否存在**：这个函数在每次 body 求值时被逐行调用，
    /// 每行一次 `fileExists` 是白送的 syscall。缺失由 `ClipboardThumbnailCache` 在
    /// 读取失败时记为"不存在"来兜（同样的 syscall，但每个 URL 只付一次）。
    func thumbnailURL(for entry: ClipboardEntry) -> URL? {
        guard entry.kind == .image, let name = entry.storedMediaName, let mediaStore else { return nil }
        return mediaStore.thumbnailURL(forStoredName: name)
    }

    /// 条目原图的落盘路径；非图片返回 nil。
    ///
    /// 只给**写回**用：预览一律读缩略图（长边 512px 已覆盖显示尺寸的 2× 需求），
    /// 这样交互路径上一次原图解码都不会发生。与 `thumbnailURL(for:)` 同理，只拼路径
    /// 不校验存在性。
    func originalURL(for entry: ClipboardEntry) -> URL? {
        guard entry.kind == .image, let name = entry.storedMediaName, let mediaStore else { return nil }
        return mediaStore.originalURL(forStoredName: name)
    }

    // MARK: 内部

    /// 条目变更的唯一出口：先算被移除的媒体文件 → 落盘条目 → 删文件。
    ///
    /// 顺序不能反。先删文件再 persist，一旦 persist 失败就会留下指向不存在文件的
    /// 条目——那是"失效态"要表达的语义，不该由我们自己的写序错误制造出来。
    private func commit(_ next: [ClipboardEntry]) {
        let removed = Set(entries.compactMap(\.storedMediaName))
            .subtracting(next.compactMap(\.storedMediaName))
        entries = next
        persist()
        mediaStore?.remove(storedNames: removed)
    }

    /// 写回被拒的失效闪示：1.5 秒后自动清除。仅错误反馈走定时清除——成功侧的
    /// 持续高亮（currentClipboardEntryID）是状态追踪，不参与。
    private func flashCopyFailure(_ failed: UUID) {
        copyFailedID = failed
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.copyFailedID == failed else { return }
                self.copyFailedID = nil
            }
        }
    }

    private func persist() {
        try? stateStore?.setObject(entries, forKey: Self.historyStoreKey)
    }

    /// 自动清理检查表：挂在 attach → suspend 之间，与采集轮询相互独立。
    ///
    /// 刻意不与轮询共用节拍：清理是全局房间整理（粒度是天），60s 一次的日期比较
    /// 成本可忽略；也没有"用户看不看得到"这一说（历史还在磁盘上）。
    private func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        let timer = Timer(timeInterval: Self.cleanupCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runAutoCleanupIfDue()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func stopCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }

    private func persistAutoCleanupLastRun() {
        guard let lastAutoCleanupAt else { return }
        try? stateStore?.setObject(lastAutoCleanupAt, forKey: Self.autoCleanupLastRunStoreKey)
    }

    /// 条目引用型反馈/状态的 id 若已不在列表里就地清空（删除单条与批量清理共用）。
    private func pruneCopyFeedback(keeping next: [ClipboardEntry]) {
        if let id = currentClipboardEntryID, !next.contains(where: { $0.id == id }) {
            // 高亮条目被删：内容虽可能还在剪贴板上，但历史里已无对应条目。
            currentClipboardEntryID = nil
        }
        if let id = copyFailedID, !next.contains(where: { $0.id == id }) { copyFailedID = nil }
    }
}
