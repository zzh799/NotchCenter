import AppKit
import Combine
import Foundation
import NotchCenterKit
import SwiftUI
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
// 读重数据。富媒体落地后这一步是硬要求而非优化——每拍直接读图像数据，等于常年
// 挂着的宿主每秒拷贝数 MB。

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
// 节奏（共识 Q6）：抽屉可见 → activeInterval，收起 → idleInterval；无已放置实例
// 或插件禁用 → 停表。可见性经块视图内嵌的 ClipboardVisibilityProbe 上报
// （SystemMonitorStore.WindowVisibilityProbe 同款 occlusion 机制）。
//
// 另有**不随可见性起伏**的自动清理检查表（60s 一次日期比较，attach → suspend），
// 理由见 `startCleanupTimer`。
//
// 隐私（共识 Q2）：transient 启发式跳过 + 全局暂停 + 暂停期不补记；暂停态持久化，
// 重启后保持暂停（避免重启瞬间把用户不想记的内容记下来）。

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    static let activeInterval: TimeInterval = 1.0
    static let idleInterval: TimeInterval = 2.5
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
    /// 最近一次写回的条目 id（视图短暂高亮 ✓ 用，数秒后自动清除）。
    @Published private(set) var justCopiedID: UUID?
    /// 最近一次**写回被拒**的条目 id（文件条目的原路径已失效；视图据此显示失效态）。
    @Published private(set) var copyFailedID: UUID?

    private let reader: any ClipboardReading
    private var stateStore: StateStore?
    /// 富媒体磁盘存储；初始化失败时为 nil，此时富媒体一律不记录（正文仍照常）。
    private var mediaStore: ClipboardMediaStore?
    private var tickTimer: Timer?
    private var isActive = false
    /// 自动清理检查表（独立于可见性 tick，见 startCleanupTimer）。
    private var cleanupTimer: Timer?
    /// 上次自动清理时刻；nil 表示本次会话尚未起算（attach 会落到"此刻起算"）。
    private var lastAutoCleanupAt: Date?

    /// 上次见到的 changeCount：只在"消费了一次变化"后更新；自循环跳过靠
    /// writeBackSnapshot（写回后记快照，本轮 tick 见到相同 count 直接认领）。
    private var lastSeenChangeCount: Int?
    /// 写回快照：下一轮 tick 见到该 count 时只认领、不记录。
    private var writeBackSnapshot: Int?
    /// 第一段**放行**后待消化的计数：第二段必须对上它才消化。
    ///
    /// 不能拿 `lastSeenChangeCount` 当门票——那个值在第一段无论是否放行都会被更新
    /// （暂停、transient、自循环都要认领计数，否则下一拍会反复读同一次变化），
    /// 所以它证明不了"这一次变化被放行了"。少了这张票，暂停期间或 transient 的载荷
    /// 会在恢复记录后被补记进来，正好违反"暂停期不补记"的既定契约。
    private var pendingRecordChangeCount: Int?
    /// 高亮清除任务。
    private var highlightTask: Task<Void, Never>?

    /// 活跃放置实例（视图 appear 登记 / disappear 注销 / 移除回调强制注销）。
    private var livePlacements: Set<String> = []
    private var probeCounts: [ObjectIdentifier: Int] = [:]
    private var visibleWindows: Set<ObjectIdentifier> = []

    /// 当前节拍；nil = 未在运行。internal 供测试断言。
    private(set) var currentInterval: TimeInterval?

    init(reader: any ClipboardReading = SystemClipboardReader()) {
        self.reader = reader
    }

    var isObserved: Bool { !livePlacements.isEmpty }

    // MARK: 生命周期

    func attach(stateStore: StateStore) {
        self.stateStore = stateStore
        mediaStore = try? ClipboardMediaStore(stateStore: stateStore)
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
        // 启动即认领当前计数：避免把宿主启动前的旧剪贴板当"新复制"记一条，
        // 睡眠 / 锁屏唤醒同理收敛（共识 Q6：唤醒后最多记一条）。
        lastSeenChangeCount = reader.probe().changeCount
        pendingRecordChangeCount = nil
        isActive = true
        recomputeTimer()
        // 清理检查与"用户看不看得到"无关：起表 + 启动补算（进程退出期间跨过到期点
        // 的情况靠这一下收敛）。
        startCleanupTimer()
        runAutoCleanupIfDue()
    }

    func suspend() {
        isActive = false
        stopTicking()
        stopCleanupTimer()
        livePlacements.removeAll()
        probeCounts.removeAll()
        visibleWindows.removeAll()
        highlightTask?.cancel()
        highlightTask = nil
    }

    // MARK: 实例登记与可见性（SystemMonitorStore 同款）

    func viewDidAppear(placementID: String) {
        guard !placementID.isEmpty else { return }
        livePlacements.insert(placementID)
        recomputeTimer()
    }

    func viewDidDisappear(placementID: String) {
        livePlacements.remove(placementID)
        recomputeTimer()
    }

    func placementRemoved(placementID: String) {
        livePlacements.remove(placementID)
        recomputeTimer()
    }

    func probeAttached(windowID: ObjectIdentifier, isVisible: Bool) {
        probeCounts[windowID, default: 0] += 1
        if isVisible { visibleWindows.insert(windowID) }
        recomputeTimer()
    }

    func probeDetached(windowID: ObjectIdentifier) {
        if let count = probeCounts[windowID] {
            if count <= 1 {
                probeCounts.removeValue(forKey: windowID)
                visibleWindows.remove(windowID)
            } else {
                probeCounts[windowID] = count - 1
            }
        }
        recomputeTimer()
    }

    func probeVisibilityChanged(windowID: ObjectIdentifier, isVisible: Bool) {
        guard probeCounts[windowID] != nil else { return }
        if isVisible { visibleWindows.insert(windowID) } else { visibleWindows.remove(windowID) }
        recomputeTimer()
    }

    // MARK: 节拍

    private func recomputeTimer() {
        guard isActive, isObserved else {
            stopTicking()
            return
        }
        let interval = visibleWindows.isEmpty ? Self.idleInterval : Self.activeInterval
        if tickTimer != nil, currentInterval == interval { return }
        stopTicking()
        currentInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        poll()
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        currentInterval = nil
    }

    // MARK: 轮询与记录（两段式，见文件头 ClipboardReading 的说明）

    /// 拉一次剪贴板（ticker 与测试共用入口）。轻探测在后台线程，门在主线程。
    func poll() {
        guard isActive, isObserved else { return }
        let captured = reader
        Task.detached(priority: .utility) { [weak self] in
            let probe = captured.probe()
            await self?.ingest(probe)
        }
    }

    /// 第一段收口：轻探测的门。**这里不读任何载荷字节**（internal 供测试直注）。
    func ingest(_ probe: ClipboardProbe) {
        guard isActive else { return }
        defer { lastSeenChangeCount = probe.changeCount }
        // 自循环跳过：这是我们自己写回的那一次变化。
        if let writeBack = writeBackSnapshot, writeBack == probe.changeCount {
            writeBackSnapshot = nil
            return
        }
        guard probe.changeCount != lastSeenChangeCount else { return }
        guard !isPaused else { return }
        guard !Self.isTransient(typeNames: probe.typeNames) else { return }
        pendingRecordChangeCount = probe.changeCount
        readPayload(changeCount: probe.changeCount)
    }

    /// 第二段：门全过之后才读重数据（图像字节可能数 MB）。
    private func readPayload(changeCount: Int) {
        let captured = reader
        Task.detached(priority: .utility) { [weak self] in
            let payload = captured.readPayload()
            await self?.ingest(payload, changeCount: changeCount)
        }
    }

    /// 第二段收口：载荷回主线程消化（internal 供测试直注）。
    ///
    /// `changeCount` 是**发起读取时**的计数：只有它还等同于第一段放行时留的票，
    /// 这份载荷才算数。用户在读取的这几十毫秒里又复制了别的东西时，票已被新的
    /// 放行覆盖（或仍是旧票而计数已变），这次投递自然落空——不会把旧内容按新顺序
    /// 记进去。
    func ingest(_ payload: ClipboardPayload, changeCount: Int) {
        // 门票在放行后只消费一次：并发 / 重复投递的同一份载荷不会再记一遍。
        guard isActive, changeCount == pendingRecordChangeCount, !isPaused else { return }
        pendingRecordChangeCount = nil
        var capture = ClipboardCapture(
            text: payload.text,
            filePaths: payload.filePaths,
            imageData: payload.imageData,
            imageUTI: payload.imageUTI
        )
        if let data = payload.imageData {
            capture.imageHash = ClipboardMediaStore.contentHash(of: data)
        }
        guard var entry = ClipboardHistoryLogic.makeEntry(from: capture) else { return }
        var writtenMediaName: String?
        if entry.kind == .image, !ClipboardHistoryLogic.contains(entry, in: entries) {
            // 先落盘再入库：反过来会留下指向不存在文件的条目。重复内容不进这一步
            // （`makeEntry` 已给出哈希，命中判定不需要文件）。
            guard let mediaStore, let data = payload.imageData,
                  let name = mediaStore.store(data: data, uti: entry.mediaUTI) else { return }
            entry.storedMediaName = name
            writtenMediaName = name
        }
        let next = ClipboardHistoryLogic.recording(entry, into: entries)
        guard next != entries else {
            // 被去重或预算停收：刚写的文件没有任何条目引用，就地回收，不等下次启动。
            if let writtenMediaName { mediaStore?.remove(storedNames: [writtenMediaName]) }
            return
        }
        commit(next)
    }

    // MARK: 用户操作

    /// 点击写回：按类型把内容放回剪贴板 + 记快照跳过自循环 + 短暂反馈。
    /// 返回 false 表示写回被拒（文件条目的原路径已全部失效）。
    @discardableResult
    func copyBack(_ entry: ClipboardEntry) -> Bool {
        guard let count = writeToPasteboard(entry) else {
            flashCopyFeedback(copied: nil, failed: entry.id)
            return false
        }
        writeBackSnapshot = count
        lastSeenChangeCount = count
        flashCopyFeedback(copied: entry.id, failed: nil)
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
        // 恢复记录时重新认领计数：暂停期间的变化不补记（共识 Q10）。同时**作废**第一
        // 段可能留下的票，否则恢复后那份被暂停挡下的载荷会被补记进来。
        if !paused {
            pendingRecordChangeCount = nil
            lastSeenChangeCount = reader.probe().changeCount
        }
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

    /// 写回反馈：成功打 ✓、被拒打失效态，1.5 秒后自动清除（两种互斥）。
    private func flashCopyFeedback(copied: UUID?, failed: UUID?) {
        justCopiedID = copied
        copyFailedID = failed
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.justCopiedID = nil
                self?.copyFailedID = nil
            }
        }
    }

    private func persist() {
        try? stateStore?.setObject(entries, forKey: Self.historyStoreKey)
    }

    /// 自动清理检查表：挂在 attach → suspend 之间，与 `isObserved` **无关**。
    ///
    /// 刻意不走 `recomputeTimer` 那条可见性驱动的路：清理是全局房间整理，不该等
    /// 用户把抽屉打开；也没有"没有放置实例就不需要清"这一说（历史还在磁盘上）。
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

    /// 写回反馈的两个 id 若已不在列表里就地清空（删除单条与批量清理共用）。
    private func pruneCopyFeedback(keeping next: [ClipboardEntry]) {
        if let id = justCopiedID, !next.contains(where: { $0.id == id }) { justCopiedID = nil }
        if let id = copyFailedID, !next.contains(where: { $0.id == id }) { copyFailedID = nil }
    }

    /// transient 启发式：类型名含 transient / concealed / password / secret 即跳过。
    /// 尽力而为（README 已声明局限）：密码管理器的自动清除型复制通常带此类标记
    /// 或存活极短；后者靠"变化过快"的下一轮覆盖自然收敛——本函数只处理前者。
    static func isTransient(typeNames: [String]) -> Bool {
        let markers = ["transient", "concealed", "password", "secret"]
        return typeNames.contains { name in
            let lower = name.lowercased()
            return markers.contains { lower.contains($0) }
        }
    }
}

// MARK: - 窗口可见性探针（SystemMonitorStore.WindowVisibilityProbe 同款语义）

/// 可见性感知机制同 SystemMonitorStore.WindowVisibilityProbe（见其 MARK 节）；isPreview 副本不插探针。
struct ClipboardVisibilityProbe: NSViewRepresentable {
    let onAttach: (_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void
    let onDetach: (_ windowID: ObjectIdentifier) -> Void
    let onVisibilityChange: (_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void

    func makeNSView(context _: Context) -> ProbeView {
        let view = ProbeView()
        view.onAttach = onAttach
        view.onDetach = onDetach
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_: ProbeView, context _: Context) {}

    final class ProbeView: NSView {
        var onAttach: ((_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void)?
        var onDetach: ((_ windowID: ObjectIdentifier) -> Void)?
        var onVisibilityChange: ((_ windowID: ObjectIdentifier, _ isVisible: Bool) -> Void)?

        private var observedWindowID: ObjectIdentifier?
        private var isObserving = false

        deinit {
            if isObserving {
                NotificationCenter.default.removeObserver(self)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                let windowID = ObjectIdentifier(window)
                guard observedWindowID != windowID else { return }
                stopObserving()
                observedWindowID = windowID
                startObserving(window)
                onAttach?(windowID, window.occlusionState.contains(.visible))
            } else {
                stopObserving()
                if let windowID = observedWindowID {
                    observedWindowID = nil
                    onDetach?(windowID)
                }
            }
        }

        private func startObserving(_ window: NSWindow) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(occlusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            isObserving = true
        }

        private func stopObserving() {
            guard isObserving else { return }
            NotificationCenter.default.removeObserver(self)
            isObserving = false
        }

        @objc private func occlusionDidChange(_: Notification) {
            guard let windowID = observedWindowID, let window else { return }
            onVisibilityChange?(windowID, window.occlusionState.contains(.visible))
        }
    }
}
