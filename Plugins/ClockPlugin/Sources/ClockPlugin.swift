import NotchCenterKit
import SwiftUI

// MARK: - ClockPlugin（官方「时钟」插件）

/// 抽屉里的指针表盘：60 刻度 + 1–12 数字 + 时/分针，点击打开时钟.app。
/// 纯展示（无实例状态、无设置界面、无快捷按钮、无活动摘要），版式与探针同源于
/// `ClockFaceMetrics` 的比例表。决策见
/// docs/agent-notes/proposed/2026-09-20-clock-analog-block.md。
@objc(ClockPlugin) @MainActor
public final class ClockPlugin: NSObject, NotchCenterPlugin {
    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe；矩形由 `ClockFaceMetrics.faceRect`
    /// 推导，与块视图同一套比例常量）。
    ///
    /// 只声明一个：表盘是**内切圆**，唯一可能越出内容盒的元素就是它的外接矩形；
    /// 刻度环、数字环与两针按比例表构造上全在该圆内（数字外缘 ≈ 0.405D <
    /// 刻度环内缘 0.4448D < 0.5D，`ClockFaceGeometryTests` 兜住这条不等式）。
    /// 照指南「整面自适应的容器声明一个内容区探针即可」。
    private static func faceLayoutProbes(for size: CGSize) -> [BlockProbe] {
        [BlockProbe(id: "clock.face", rect: ClockFaceMetrics.faceRect(for: size))]
    }

    public static var blocks: [NotchBlock] {
        [
            NotchBlock(
                id: "clock.analog",
                displayName: L("block.analog.name"),
                kind: .drawer,
                // 三档固定 150×120（= 默认格 150×120 下的 1×1）：表盘内切于短边，
                // 宽出的 30pt 是卡片两侧留白。固定档只约束"占多少抽屉"——等比比例表
                // 仍然让用户在改格子尺寸后拿到一张完整的脸（物理尺寸随格漂移）。
                minSize: BlockPixelSize(width: 150, height: 120),
                maxSize: BlockPixelSize(width: 150, height: 120),
                recommendedSize: BlockPixelSize(width: 150, height: 120),
                symbolName: "clock",
                probes: { info in
                    Self.faceLayoutProbes(for: info.frame.size)
                },
                makeView: { context in
                    AnyView(ClockFaceBlockView(context: context))
                }
            )
        ]
    }

    public override init() {
        super.init()
    }
}
