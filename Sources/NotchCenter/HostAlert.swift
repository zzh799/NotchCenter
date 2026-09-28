import AppKit
import NotchCenterKit

// MARK: - 模态确认弹窗的收口

/// `NSAlert` 的呈现收口：把弹窗抬到锚点域之上再 `runModal()`。
///
/// **只在锚点所在窗口不会随鼠标离开而收起时使用**（设置窗 / 权限引导窗内）。
/// 抽屉内触发的确认与提示一律走 Kit 的内联浮窗——模态循环阻塞主线程，抽屉的
/// 收起动画与悬停判定都推进不了，弹窗会悬在一个已经/即将收起的抽屉上方。
///
/// 为什么不能「先设层级、再 `runModal()`」：`NSAlert.runModal()` 会把窗口层级
/// **强制覆盖**成 `NSModalPanelWindowLevel`（8），事先设什么都无效（实测
/// `NSApp.runModal(for:)` 同样覆盖）。而 8 低于设置窗（`HostWindowLevel.utility`，
/// 101），重叠处弹窗被设置窗整个压住。可用的姿势是**等模态循环起来之后再设**——
/// 实测此时设置生效且不再被重置，所以这里先 `layout()` 把窗口实例化出来，
/// 再排一个主队列任务去抬层级（模态循环会照常排空主队列）。
@MainActor
enum HostAlert {
    /// 弹一个模态确认，返回用户的选择。
    ///
    /// - Parameter anchor: 弹窗锚点所在的界面域，决定它被抬到哪一档层级。
    @discardableResult
    static func runModal(
        _ alert: NSAlert,
        anchor: HostWindowLevel.Anchor = .utility
    ) -> NSApplication.ModalResponse {
        let level = HostWindowLevel.auxiliary(above: anchor)
        // `layout()` 是 `NSAlert.runModal()` 内部的第一步，这里提前触发以拿到 window。
        alert.layout()
        DispatchQueue.main.async { alert.window.level = level }
        return alert.runModal()
    }
}
