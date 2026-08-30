import SwiftUI

// MARK: - 抽屉动画参数

/// 抽屉一切位移动画（块推挤、面板形变、落位飞行）的唯一参数源。
///
/// 为什么必须共用常量：**落位动画的正确性依赖它**。松手时两条 spring
/// 在同一个 runloop tick 内起播——
///   1. `DrawerBlockContainer` 的 `dragOffset → .zero`（`@State`）
///   2. `rebuildContent(animated:)` 的 `drawerElements` 新 placements（`@Published`）
/// 两者视觉位置相加：`position(t) + dragOffset(t)`。`t=0` 是光标位置、
/// `t=1` 是落点，中间是否为**单条平滑曲线**取决于两条动画的参数是否
/// 严格一致；一旦漂移（例如一处手改成 0.28），合成曲线会折一下，
/// 表现为落位过程中块"拐个弯"。
enum DrawerAnimation {
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
}
