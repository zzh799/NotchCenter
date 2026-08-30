import AppKit

// MARK: - 落位飞行（跟手浮窗 → 抽屉里的落点）

/// 拖拽松手后，把跟手浮窗 spring 飞向占位框位置，再交接给真实块。
///
/// 时序（前三步必须在**同一帧**完成，跨帧就会闪；由 `BlockDragCoordinator
/// .commit()` 保证）：
///   1. 浮窗起播 SwiftUI spring（窗口撑成「起点 ∪ 终点」，内容偏移飞行）
///   2. 提交布局，并把新块置为 `uiState.landingPlacementID`（隐形）
///   3. 启动收敛计时器
///   4. 收敛后 `handoff`：同一次更新里让真实块显形 + 收掉浮窗
///      ——两者 1:1 同位置，交接既无重影也无空帧
///
/// 浮窗的生命周期从 `BlockDragCoordinator` **移交**到这里：拖拽会话可以在
/// 浮窗还在飞的时候就开始下一次（设置面板窗口锁、事件监听都已先行释放）。
///
/// 为什么要有这个类型而不是在 `commit()` 里直接 `asyncAfter`：**任何异常
/// 路径都必须执行 handoff**，否则 `landingPlacementID` 残留会让块永久隐形。
/// 把它收敛成单点（本类型的 `cancel`）后，抽屉收起 / 退出编辑 / App 隐藏 /
/// 下一次拖拽起手都只要调一次 `cancel()`。
@MainActor
final class DragPreviewLanding {
    static let shared = DragPreviewLanding()

    /// `spring(response: 0.3, dampingFraction: 0.86)` 的视觉收敛上限
    /// （response × 1.5，留余量）。这是个**硬超时兜底**：即使动画被系统
    /// 打断或提前结束，到点也一定收尾。
    private static let flightDuration: TimeInterval = 0.45

    private var panel: DragPreviewPanel?
    private var work: DispatchWorkItem?
    private var handoff: (@MainActor () -> Void)?

    private init() {}

    var isFlying: Bool { panel != nil }

    /// 起播落位飞行。`handoff` **保证被调用一次**（正常收敛或被 `cancel`
    /// 打断），调用方可以放心在里面恢复被隐藏的块。
    func fly(
        _ panel: DragPreviewPanel,
        from: CGRect,
        to: CGRect,
        handoff: @escaping @MainActor () -> Void
    ) {
        // 上一次未完成的落位强制收尾：否则它的 handoff 永不被调用，
        // 上一个块会永久隐形。
        cancel()

        self.panel = panel
        self.handoff = handoff
        panel.beginLanding(from: from, to: to)

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flightDuration, execute: work)
    }

    /// 强制收尾（新一次拖拽起手 / 抽屉收起 / 退出编辑 / App 隐藏 / 拖拽取消）。
    ///
    /// 与 `finish()` 的区别只在于是否取消计时器——**两者都会执行 handoff**，
    /// 这是不留隐形块的关键。
    func cancel() {
        work?.cancel()
        work = nil
        finish()
    }

    private func finish() {
        work = nil
        let pending = handoff
        handoff = nil
        panel?.orderOut(nil)
        panel = nil
        pending?()
    }
}
