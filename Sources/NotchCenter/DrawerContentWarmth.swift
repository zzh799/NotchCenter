import Foundation

// MARK: - 抽屉内容温存状态机

/// 抽屉内容的温存状态：收起后内容不立即卸载，而是在窗口内继续常驻。
///
/// 收益、代价，以及为什么必须与 `\.isDrawerPresented` 配套使用，见决策记录
/// `docs/agent-notes/implemented/2026-09-11-drawer-content-warmth.md`。
/// 本文件只管状态本身——注入 `now`、不碰时钟，因此可被单测逐字段钉住。
struct DrawerContentWarmth: Equatable {
    /// 温存窗口：收起后内容继续常驻的时长。覆盖"收起后又很快打开"的常见节奏
    /// （看一眼别的窗口、复制一段再回来）；再长就是白占内存与插件状态。
    static let window: TimeInterval = 300

    /// 实际生效的窗口。诊断可经 `NOTCHCENTER_DRAWER_WARM_SECONDS` 覆盖
    /// （`0` = 收起即卸载，等价于没有温存），用来在**同一份二进制**里做
    /// "温存开 / 关"的 A/B 复量——跨二进制比会混进进程预热差异。
    static var effectiveWindow: TimeInterval {
        ProcessInfo.processInfo.environment["NOTCHCENTER_DRAWER_WARM_SECONDS"]
            .flatMap(TimeInterval.init) ?? window
    }

    private enum Phase: Equatable {
        /// 从未展开，或温存已到期回收。
        case cold
        /// 内容应保持挂载；`deadline` 非空表示已收起、正在温存倒数。
        case warm(expanded: Bool, deadline: Date?)
    }

    private var phase: Phase = .cold

    /// 内容当前是否应留在视图树里。
    var keepsContentMounted: Bool {
        if case .warm = phase { return true }
        return false
    }

    /// 展开：内容常驻，且没有回收期限。
    mutating func expanded() {
        phase = .warm(expanded: true, deadline: nil)
    }

    /// 收起：起算温存期限。从未展开时保持冷——不要凭空挂载一份内容。
    mutating func collapsed(now: Date, window: TimeInterval = Self.window) {
        guard case .warm = phase else { return }
        phase = .warm(expanded: false, deadline: now.addingTimeInterval(window))
    }

    /// 收回过期温存：已到期返回 `true` 并转冷（调用方据此卸载内容）；
    /// 展开中或尚未到期返回 `false`。
    mutating func prune(now: Date) -> Bool {
        guard case let .warm(expanded: false, deadline?) = phase, now >= deadline else {
            return false
        }
        phase = .cold
        return true
    }
}
