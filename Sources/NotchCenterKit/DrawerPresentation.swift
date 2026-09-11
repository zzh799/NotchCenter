import SwiftUI

// MARK: - 抽屉呈现态（宿主 → 块视图的只读环境信号）

/// 块视图**当前是否真的在屏幕上被用户看到**。
///
/// 宿主对抽屉内容做温存：收起后视图树不立即卸载（见
/// `docs/agent-notes/implemented/2026-09-11-drawer-content-warmth.md`），
/// 因此 SwiftUI 的 `.onAppear` / `.onDisappear` 只表达**挂载 / 卸载**，
/// 不再表达"用户看得到 / 看不到"。
///
/// 契约：需要「用户看不到我就收尾」语义的块**必须**读本环境值，在
/// `.onChange(of: isDrawerPresented)` 里做与 `.onDisappear` **同源的收尾**，
/// 且收尾必须幂等（收起与卸载会先后各触发一次）。典型收尾：停摄像头会话、
/// 停轮询表、注销放置登记、关独立浮窗。纯本地 `@State` 与只读展示不受此约束。
///
/// 默认 `true`：宿主未注入本值的场景（设置页预览、Size Lab、组件目录）
/// 一律按"看得到"处理——它们不是可收起的抽屉内容。
private struct IsDrawerPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// 抽屉是否处于展开态（用户能看到抽屉块内容）。
    var isDrawerPresented: Bool {
        get { self[IsDrawerPresentedKey.self] }
        set { self[IsDrawerPresentedKey.self] = newValue }
    }
}
