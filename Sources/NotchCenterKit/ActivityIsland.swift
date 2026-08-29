import SwiftUI

// MARK: - 活动岛（文档 §4.10）

/// 插件「活动状态」的专属展示区：插件进入活动状态（如番茄钟计时中）时向宿主
/// 提交一份活动岛内容，宿主在刘海正下方弹出一个小岛展示插件设计的 UI；
/// 活动结束（或插件被禁用）时按 id 收回。同一时刻可有多个活动岛，宿主按
/// 提交顺序在刘海下方堆叠。
///
/// 岛内容随插件自身状态自由更新（视图观察插件自己的 ObservableObject），
/// 宿主只负责窗口、命中穿透与展示时机（抽屉展开期间活动岛整体让位隐藏）。
@MainActor
public struct ActivityIslandContent: Identifiable {
    /// 活动唯一标识（插件内唯一即可；同 id 重复提交 = 覆盖更新）。
    public let id: String
    /// 岛的最大尺寸（含宿主绘制的底衬，即整岛的最终外观尺寸）。宿主窗口按
    /// 此开窗，岛内容可在其中自行做紧凑/展开变形，命中测试以实际内容为准。
    public let maxSize: CGSize
    /// 岛内容视图。
    public let view: AnyView

    public init(id: String, maxSize: CGSize, view: AnyView) {
        self.id = id
        self.maxSize = maxSize
        self.view = view
    }
}
