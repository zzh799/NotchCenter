import Foundation

// MARK: - 紧凑带活动摘要（文档 §4.10 修订）

/// 插件「活动状态」的紧凑摘要：插件进入活动状态（如番茄钟计时中、媒体播放中）
/// 时向宿主提交一份结构化摘要，宿主在刘海紧凑带内渲染一行「简介 + 迷你进度」，
/// 不新建窗口、不遮挡屏幕内容区。活动结束（或插件被禁用）时按 id 收回。
///
/// 摘要随插件自身状态自由更新：**同 id 重复提交 = 原位覆盖更新**（不改变
/// 在摘要序列中的新旧次序）；宿主按提交次序维护序列，同一时刻每侧各展示一条，
/// 最新优先、收回时回退到次新（决策见 Agent Note 2026-09-03-compact-area-activity-summary）。
///
/// 宿主只负责窗口内容内的渲染与过渡动画（出现/更新/移除均在既有窗口内容内完成，
/// 窗口 frame 不参与动画）。纯数据、可跨模块传递；视图渲染所需的截断/降级策略由宿主决定。
public struct ActivitySummary: Identifiable, Sendable, Equatable {
    /// 活动唯一标识（插件内唯一即可；同 id 重复提交 = 覆盖更新）。
    public let id: String
    /// 主文案（活动简介，如「番茄钟进行中」「正在播放」）。
    public let title: String
    /// 副文案（如「12:34 剩余」「Artist — Track」），可为空。
    public let subtitle: String?
    /// 引导图标（SF Symbol 名称），可为空。
    public let symbolName: String?
    /// 迷你进度（0…1，沿刘海方向的进度条）。无进度概念的摘要可不传。
    public let progress: Double?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbolName: String? = nil,
        progress: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.progress = progress
    }
}
