import CoreGraphics

// MARK: - 网格容量（文档 §5.3 / §7.2）

/// 由「屏幕可用宽 / 高 + 当前 `GridMetrics` 快照」推导的网格容量。
///
/// 容量 = 屏幕尺寸能摆下的整行 / 整列数（向下取整），是**纯推导**量，也是
/// 行列数可选档位与生效上限的共同来源：
///
/// - **列容量**与 `LayoutEngine.screenColumnCapacity()` 原公式逐位等价
///   （`width(n) + padding × 2 ≤ availableWidth` 的最大 n）。抽屉窗口的固定
///   满宽按它取，改口径会连带改窗口 frame——勿动。
/// - **行容量**扣掉顶栏与底部内容内边距（高度预算 = `topBar + height(rows) + padding`，
///   与 `LayoutEngine.drawerWindowSize` 同源）。抽屉可见高度另有屏幕上限封顶，
///   所以行容量只决定「能摆几行」，不改变被裁时走 ScrollView 的既有行为。
///
/// 抽成独立纯类型是为了脱离引擎与进程级单例测试（同 `DrawerLayoutMetricsResolver` 惯例）。
enum GridCapacity {
    /// 屏幕可用宽度能容纳的列数。恒 ≥ 1：宽度小到放不下一格也不退化为 0 或负。
    static func columns(availableWidth: CGFloat, metrics: GridMetrics) -> Int {
        guard metrics.stepWidth > 0 else { return 1 }
        let usable = availableWidth - metrics.contentPadding * 2 + metrics.spacing
        return max(1, Int(usable / metrics.stepWidth))
    }

    /// 屏幕可用高度（已扣顶部留白与紧凑带）能容纳的整行数。恒 ≥ 1。
    static func rows(availableHeight: CGFloat, metrics: GridMetrics) -> Int {
        guard metrics.stepHeight > 0 else { return 1 }
        let usable = availableHeight - metrics.topBarHeight - metrics.contentPadding + metrics.spacing
        return max(1, Int(usable / metrics.stepHeight))
    }

    /// 多屏可用尺寸合并：宽、高**各自**取最小值（文档 §7.1 / §7.2）。
    ///
    /// 布局是所有屏幕共享的一份，容量必须按最"憋屈"的那块屏算，否则抽屉搬到
    /// 小屏就放不下。取分量最小而不是"先按某块屏算容量再比大小"：容量对可用
    /// 尺寸单调不减，两者等价，但分量最小是那个「在每块屏上都放得下」的矩形
    /// 下界，语义更直白。空序列返回 nil（无参考屏，调用方决定兜底）。
    static func minimumAvailability(_ sizes: [CGSize]) -> CGSize? {
        var merged: CGSize?
        for size in sizes {
            guard let current = merged else {
                merged = size
                continue
            }
            merged = CGSize(
                width: min(current.width, size.width),
                height: min(current.height, size.height)
            )
        }
        return merged
    }
}
