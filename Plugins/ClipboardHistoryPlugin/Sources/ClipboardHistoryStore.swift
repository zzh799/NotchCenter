import AppKit
import Combine
import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 剪贴板读取抽象（单测注入假剪贴板，绝不触碰真实 NSPasteboard）

/// 剪贴板快照：变化计数 + 候选纯文本（nil = 当前无文本内容）。
struct ClipboardSnapshot: Equatable, Sendable {
    var changeCount: Int
    var text: String?
    /// 类型名表（如 ["public.utf8-plain-text"]），用于 transient 启发式判定。
    var typeNames: [String]
}

/// 剪贴板读写协议：生产实现走 NSPasteboard.general，测试用假实现。
protocol ClipboardReading: Sendable {
    func snapshot() -> ClipboardSnapshot
    /// 写回全文；返回写完后的 changeCount（调用方记快照跳过自循环）。
    func writeBack(_ text: String) -> Int
}

/// 生产实现：只读写纯文本，不碰富文本 / 图片 / 文件。
/// NSPasteboard 非 Sendable，按 NotesImageStore 同款 `@unchecked Sendable` +
/// NSLock 模式经后台线程访问（读 changeCount + 取串都是轻量调用）。
final class SystemClipboardReader: ClipboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let lock = NSLock()

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func snapshot() -> ClipboardSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let count = pasteboard.changeCount
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let text = pasteboard.string(forType: .string)
        return ClipboardSnapshot(changeCount: count, text: text, typeNames: types)
    }

    func writeBack(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
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

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isPaused = false
    /// 最近一次写回的条目 id（视图短暂高亮 ✓ 用，数秒后自动清除）。
    @Published private(set) var justCopiedID: UUID?

    private let reader: any ClipboardReading
    private var stateStore: StateStore?
    private var tickTimer: Timer?
    private var isActive = false

    /// 上次见到的 changeCount：只在"消费了一次变化"后更新；自循环跳过靠
    /// writeBackSnapshot（写回后记快照，本轮 tick 见到相同 count 直接认领）。
    private var lastSeenChangeCount: Int?
    /// 写回快照：下一轮 tick 见到该 count 时只认领、不记录。
    private var writeBackSnapshot: Int?
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
        entries = ClipboardHistoryLogic.sanitized(
            stateStore.object([ClipboardEntry].self, forKey: Self.historyStoreKey) ?? []
        )
        isPaused = stateStore.object(Bool.self, forKey: Self.pausedStoreKey) ?? false
        // 启动即认领当前计数：避免把宿主启动前的旧剪贴板当"新复制"记一条，
        // 睡眠 / 锁屏唤醒同理收敛（共识 Q6：唤醒后最多记一条）。
        lastSeenChangeCount = reader.snapshot().changeCount
        isActive = true
        recomputeTimer()
    }

    func suspend() {
        isActive = false
        stopTicking()
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

    // MARK: 轮询与记录

    /// 拉一次剪贴板（ticker 与测试共用入口）。读在后台线程，结果回主线程消化。
    func poll() {
        guard isActive, isObserved else { return }
        let captured = reader
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = captured.snapshot()
            await self?.ingest(snapshot)
        }
    }

    /// 主线程消化（internal 供测试直注）。
    func ingest(_ snapshot: ClipboardSnapshot) {
        guard isActive else { return }
        defer { lastSeenChangeCount = snapshot.changeCount }
        // 自循环跳过：这是我们自己写回的那一次变化。
        if let writeBack = writeBackSnapshot, writeBack == snapshot.changeCount {
            writeBackSnapshot = nil
            return
        }
        guard snapshot.changeCount != lastSeenChangeCount else { return }
        guard !isPaused else { return }
        guard !Self.isTransient(typeNames: snapshot.typeNames) else { return }
        guard let text = snapshot.text else { return }
        let next = ClipboardHistoryLogic.recording(text, into: entries)
        guard next != entries else { return }
        entries = next
        persist()
    }

    // MARK: 用户操作

    /// 点击写回：全文写回剪贴板 + 记快照跳过自循环 + 短暂高亮。
    func copyBack(_ entry: ClipboardEntry) {
        let count = reader.writeBack(entry.text)
        writeBackSnapshot = count
        lastSeenChangeCount = count
        justCopiedID = entry.id
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.justCopiedID = nil
            }
        }
    }

    func togglePin(id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        guard let next = ClipboardHistoryLogic.pinning(id: id, pinned: !entry.pinned, in: entries) else { return }
        entries = next
        persist()
    }

    func delete(id: UUID) {
        guard let next = ClipboardHistoryLogic.removing(id: id, from: entries) else { return }
        entries = next
        if justCopiedID == id { justCopiedID = nil }
        persist()
    }

    func clearUnpinned() {
        let next = ClipboardHistoryLogic.clearingUnpinned(entries)
        guard next != entries else { return }
        entries = next
        persist()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        try? stateStore?.setObject(paused, forKey: Self.pausedStoreKey)
        // 恢复记录时重新认领计数：暂停期间的变化不补记（共识 Q10）。
        if !paused {
            lastSeenChangeCount = reader.snapshot().changeCount
        }
    }

    // MARK: 内部

    private func persist() {
        try? stateStore?.setObject(entries, forKey: Self.historyStoreKey)
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
