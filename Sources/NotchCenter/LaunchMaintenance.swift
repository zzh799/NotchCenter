import Foundation

/// 启动期维护：宿主起来后对布局文件做的一次性修复（见 Agent Note
/// 2026-09-25-plugin-in-use-placement-criterion）。
///
/// 抽成独立类型而不是内联进 `NotchPanelController.init()`，是为了让"按构建配置
/// 决定是否清理"这条策略**可注入、可测**：`#if DEBUG` 是编译期常量，内联会让
/// release 那条分支永远落在测试盲区，而它一旦失灵就是用户布局文件被误改（或
/// 永远清不掉失效组件）。
///
/// 调用时机（由 `NotchPanelController.init()` 保证）：**必须晚于
/// `restoreEnabledState(...)`**——否则插件实例未加载、`quickActionStore` 还是
/// 空的，合法的快捷动作槽位会被判成失效删掉；**早于
/// `refreshCompactGeometry()`**——清完紧接着就是常规几何刷新与内容重建，画面
/// 自然对齐，不需要额外的刷新调用。
enum LaunchMaintenance {
    /// 启动时是否自动清理失效摆放。
    ///
    /// release 清：用户不该看见"组件已失效"的残骸。debug 不清，留给
    /// 「设置 → 调试 → 删除无效组件」手动触发——开发期需要看着残骸复现问题，
    /// 而且自动清掉会让失效摆放的复现成本变高。
    static var purgesInvalidPlacements: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// 按策略清理失效摆放（口径同 `LayoutEngine.purgeInvalidPlacements()`，
    /// **不含"插件被停用"**——停用可逆，见 `LayoutEngine.placementLiveness`），
    /// 返回清理数量。
    ///
    /// 静默：清理对象在界面上本来就是「组件已失效」占位，删掉是修复而非损失，
    /// 不值得打断启动。数量 > 0 时留一条日志供排查。
    @MainActor
    @discardableResult
    static func run(layoutEngine: LayoutEngine, purgeInvalidPlacements: Bool) -> Int {
        guard purgeInvalidPlacements else { return 0 }
        let removed = layoutEngine.purgeInvalidPlacements()
        if removed > 0 {
            NSLog("LaunchMaintenance: purged \(removed) invalid placement(s) on launch")
        }
        return removed
    }
}
