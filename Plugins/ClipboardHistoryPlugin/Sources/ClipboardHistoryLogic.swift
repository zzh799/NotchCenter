import Foundation

// MARK: - 剪贴板历史纯逻辑（无 AppKit 依赖，供单测直调）
//
// 数据模型与全部状态变换集中于此：去重 / 置顶 / 淘汰 / 搜索过滤 / 持久化净化。
// 轮询、剪贴板读写、定时器等副作用全部留在 ClipboardHistoryStore；本文件
// 在 Linux 容器测试环境也能编译运行。

/// 单条历史：正文 + 首次记录时间 + 置顶标记。
struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var capturedAt: Date
    var pinned: Bool

    init(id: UUID = UUID(), text: String, capturedAt: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.pinned = pinned
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
