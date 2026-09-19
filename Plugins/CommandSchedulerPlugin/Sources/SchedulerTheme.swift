import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 插件本地样式收敛点
//
// `docs/agents/插件开发约定.md`：颜色/字体/间距/动效**推荐**引用 `NotchTokens`；
// token 未覆盖或插件需要自有视觉时，可在插件自身代码中声明命名常量，并收敛到
// 单一样式/调色板文件（不推荐在调用处散写内联字面量）。
//
// **豁免理由**：状态色属于该约定明确豁免的「数据可视化语义色」——执行成功/失败/
// 超时/中止是数据语义，不是 UI 主题语义，`NotchTokens.Semantic` 也覆盖不了失败
// 红 / 超时橙 / 中性灰这三档。取值一律经 `NSColor` 系统语义色桥接（与 Kit 自己的
// `NotchTokens.Semantic.link = Color(NSColor.systemBlue)` 同一条路），既不自造
// 裸 RGB 字面量，也随系统外观解析。全部集中在本文件，调用处只引用
// `SchedulerPalette.*`。
enum SchedulerPalette {
    /// 成功（复用 Kit 的强调绿，保持与既有"健康"语义一致）。
    static let success = NotchTokens.Semantic.accentGreen
    /// 失败（退出码非 0 / 起不来）。
    static let failure = Color(NSColor.systemRed)
    /// 超时（守卫超时被杀）。
    static let timeout = Color(NSColor.systemOrange)
    /// 中止 / 中断（宿主退出、崩溃遗留）——不是失败，用中性灰。
    static let neutral = Color(NSColor.systemGray)
    /// 任务被禁用。
    static let disabled = NotchTokens.Foreground.disabled

    /// 状态点颜色。
    static func color(for status: TaskRun.Status) -> Color {
        switch status {
        case .succeeded: return success
        case .failed: return failure
        case .timedOut: return timeout
        case .running: return NotchTokens.Semantic.link
        case .aborted, .interrupted: return neutral
        }
    }
}

/// 块内布局常量（与块视图同源；打包期 `probes` 必须用这里的同一套数字推导，
/// 否则探针会与真实布局漂移）。
enum SchedulerMetrics {
    /// 块内边距。
    static let padding: CGFloat = NotchTokens.Space.cardPadding
    /// 块内唯一控件（右上角悬浮「+」）相对块边缘的内缩：与宿主编辑角标同一环
    /// （`padding(6)`），同 ClipboardHistory / CameraPlugin 的块内角标。
    static let controlInset: CGFloat = 6
    /// 任务行高度。
    static let rowHeight: CGFloat = 52
    /// 任务行间距。
    static let rowSpacing: CGFloat = 6
    /// 任务列表在最小尺寸下必须完整可见的行数（探针据此声明）。
    ///
    /// 4 是 300pt 高（`minSize`）的几何上限：内容盒 300 − `padding`×2 = 280，
    /// 4 行 = 4×52 + 3×6 = 226 装得下，5 行 = 290 越界。
    static let visibleRowsAtMinimum = 4
    /// 空态占位高度。
    static let emptyStateHeight: CGFloat = 64

    /// 最小尺寸下任务列表区所需高度。
    static var listMinimumHeight: CGFloat {
        CGFloat(visibleRowsAtMinimum) * rowHeight
            + CGFloat(visibleRowsAtMinimum - 1) * rowSpacing
    }
}

/// 浮窗卡片尺寸（决策 9 的「卡片 ⊆ 块」不变量）。
///
/// 卡片尺寸必须夹在块渲染尺寸 − `BlockPopover.cardInset` 之内，理由见
/// `BlockPopover.cardInset` 的文档（停留区只看抽屉可见矩形）。收进本枚举是为了
/// 让「三张卡在 `minSize` 下都装得进块」这条不变量能被单测直接验（不需要起视图）。
///
/// `@MainActor` 是 `BlockPopover.cardInset` 的执行者要求（Kit 的 `BlockPopover`
/// 整体主执行者隔离）——不为了让本枚举"看起来纯"而把 48 抄成插件内字面量，
/// 那正是「同一事实两处写」的违例。
@MainActor
enum SchedulerPopoverMetrics {
    /// 历史卡理想尺寸（上限；实际取块尺寸与它的较小者）。
    static let historyIdeal = CGSize(width: 860, height: 660)
    /// 编辑表单卡理想尺寸：够放"命令多行 + cwd + env + 调度 + 超时"一屏不滚。
    static let formIdeal = CGSize(width: 460, height: 560)
    /// 插件设置卡理想尺寸（块内不再有齿轮入口，仅用于宿主齿轮路径与不变量校验）。
    static let settingsIdeal = CGSize(width: 340, height: 260)

    /// 卡片兜底下限——**必须 ≤ minSize − cardInset**（300 − 48 = 252），否则
    /// 下限会在最小块上生效，把卡片撑出块矩形，鼠标再也够不到浮窗边缘。
    /// 只兜极端退化尺寸（块被拖到比 minSize 还小的一帧）。
    static let floor = CGSize(width: 200, height: 160)
    /// 历史卡两栏 → 单栏（列表在上、输出在下）切换阈值。
    static let twoColumnMinWidth: CGFloat = 420

    /// 卡片尺寸：理想尺寸与可用空间取小，下限兜底但绝不越出可用空间。
    static func cardSize(ideal: CGSize, blockSize: CGSize) -> CGSize {
        let available = CGSize(
            width: blockSize.width - BlockPopover.cardInset,
            height: blockSize.height - BlockPopover.cardInset
        )
        return CGSize(
            width: axis(ideal.width, available: available.width, floor: floor.width),
            height: axis(ideal.height, available: available.height, floor: floor.height)
        )
    }

    private static func axis(_ ideal: CGFloat, available: CGFloat, floor: CGFloat) -> CGFloat {
        min(max(ideal, floor), max(available, 0))
    }
}
