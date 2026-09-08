import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图
//
// 版式由块跨度决定：宿主在抽屉与目录预览路径都下发 widthColumns/heightRows
//（layoutInfo.size = 当前真实跨度，与 width/height 同值）；nil 仅出现在无
// 落位上下文的防御路径，按推荐 2×1 的 rows 形态兜底——形态在视图创建期即
// 确定（宿主块缓存键含跨度，跨度变化重走 makeView）。
//
// 两形态共用同一「随条目适应」容器：条目总高 ≤ 块高 → 整组垂直居中（不滚），
// 超高（条目多，放不下） → 块内滚动。差异只在行的摆法：
// - 1×1（compact）：每台屏「屏名一行 + 亮度滑杆一行」上下堆叠。
// - 其余跨度（rows）：每台屏一行横向「屏名 + 滑杆」（历史版式）。

/// 亮度滑杆块的版式形态：跨度 → 布局（纯逻辑，视图与测试共用）。
enum BrightnessSliderArrangement: Equatable {
    /// 1×1：每台屏「屏名 + 滑杆」两行紧凑堆叠。
    case compact
    /// ≥2 列或 ≥2 行：每台屏一行横向「屏名 + 滑杆」。
    case rows

    static func forSpan(
        widthColumns: Int?,
        heightRows: Int?
    ) -> BrightnessSliderArrangement {
        if let columns = widthColumns, let rows = heightRows {
            return columns == 1 && rows == 1 ? .compact : .rows
        }
        return .rows
    }
}

struct DisplaySlidersBlockView: View {
    let context: BlockContext
    @ObservedObject private var controller = BrightnessController.shared

    private var arrangement: BrightnessSliderArrangement {
        BrightnessSliderArrangement.forSpan(
            widthColumns: context.layoutInfo.widthColumns,
            heightRows: context.layoutInfo.heightRows
        )
    }

    var body: some View {
        let size = context.layoutInfo.frame.size
        BlockCard(hoverEffect: false) { _ in
            Group {
                if controller.rows.isEmpty {
                    emptyState
                } else {
                    switch arrangement {
                    case .compact: compactLayout
                    case .rows: rowsLayout
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .task {
            // isPreview 契约：预览副本不认领枚举 / 回读副作用。
            guard !context.layoutInfo.isPreview else { return }
            await controller.startIfNeeded()
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(NotchTokens.Text.system( 22, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(0.07)))
            Text(L("drawer.empty.title"))
                .font(NotchTokens.Text.system( 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 版式布局

    private var compactLayout: some View {
        adaptiveStack(insets: CompactBrightnessMetrics.insets) {
            compactRows
        }
    }

    /// 1×1 紧凑行：每台屏「屏名 + 滑杆」两行，屏间 `rowSpacing` 分隔。
    private var compactRows: some View {
        VStack(spacing: CompactBrightnessMetrics.rowSpacing) {
            ForEach(controller.rows) { model in
                CompactBrightnessRowView(
                    model: model,
                    isPreview: context.layoutInfo.isPreview)
            }
        }
    }

    /// 行式（历史版式，多屏每屏一行横向滑杆）。
    private var rowsLayout: some View {
        adaptiveStack(insets: RowsBrightnessMetrics.insets) {
            rowViews
        }
    }

    private var rowViews: some View {
        VStack(spacing: RowsBrightnessMetrics.rowSpacing) {
            ForEach(controller.rows) { model in
                BrightnessRowView(
                    model: model,
                    isPreview: context.layoutInfo.isPreview)
            }
        }
    }

    /// 随条目适应的共用容器：`ViewThatFits` 沿竖直方向做二选一，免去手工预算
    /// 行高带来的边界抖动——候选 1 整组垂直居中（条目总高 ≤ 块高时命中，单屏
    /// 或少量屏即整组居中），候选 2 ScrollView 兜底（条目多、超高时块内滚动）。
    /// 1×1 与其余尺寸共用同一容器，行为一致。
    private func adaptiveStack<Content: View>(
        insets: EdgeInsets,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .vertical) {
            content()
                .padding(insets)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                content()
                    .padding(insets)
            }
        }
    }
}

// MARK: - 版式常量

/// 行式滑杆的版式常量：占位空槽对齐滑杆高度，避免初值落定时行高跳动。
private enum BrightnessRowMetrics {
    /// `.controlSize(.small)` 滑杆的标准高度（实测 16pt）。
    static let sliderHeight: CGFloat = 16
    /// 占位空槽的槽高（贴近小尺寸滑杆的轨道粗细）。
    static let trackHeight: CGFloat = 3
}

/// 1×1 紧凑两行式的版式常量。
private enum CompactBrightnessMetrics {
    /// 块内容四周留白（比行式的 14/12 收一点，1×1 宽高都紧张）。
    static let insets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    /// 屏与屏之间的间距。
    static let rowSpacing: CGFloat = 8
    /// 同一屏内「屏名」与「滑杆」之间的间距。
    static let rowInnerSpacing: CGFloat = 3
}

/// 行式（≥2 列或 ≥2 行）的版式常量。
private enum RowsBrightnessMetrics {
    /// 块内容四周留白。
    static let insets = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    /// 屏与屏之间的间距。
    static let rowSpacing: CGFloat = 12
}

// MARK: - 滑杆（两形态共用的唯一实现）

/// 单台屏的亮度滑杆或其回读占位槽。两套版式共用这一份交互与样式，
/// 拖动 → DDC 写入、回读中占位、跨实例同步等语义集中在此。
private struct BrightnessSliderControl: View {
    @ObservedObject var model: BrightnessDisplayModel
    let isPreview: Bool

    var body: some View {
        // 只在初值回读完成后才渲染滑杆：滑杆若以 0 出生，之后赋上真值的那
        // 次变化只要落在任一 `.animation(_:value:)` 事务里就会被插值成
        // 「从 0 涨到当前亮度」的假动画——进入设置「组件」页时抽屉切编辑
        // 态的过渡恰好盖住这段窗口（块视图随编辑态重建，DDC 回读几十毫秒
        // 内落定）。改为占位空槽，滑杆首次出现时已是真值，无中间态可插值。
        if model.state == .ready {
            slider
        } else {
            pendingTrack
        }
    }

    /// 回读中的占位空槽（静态，不动画）：与滑杆等高，保留行的呼吸感。
    private var pendingTrack: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.14))
            .frame(height: BrightnessRowMetrics.trackHeight)
            .frame(maxWidth: .infinity)
            .frame(height: BrightnessRowMetrics.sliderHeight)
    }

    private var slider: some View {
        Slider(
            value: Binding(
                get: { model.percent },
                set: { newValue in
                    // 拖动才落 DDC；其余（跨实例同步等程序回写）只更新本地显示。
                    guard model.isDragging, !isPreview else {
                        model.percent = newValue
                        return
                    }
                    BrightnessController.shared.requestWrite(model, percent: newValue)
                }
            ),
            in: 0...100,
            onEditingChanged: { editing in
                model.isDragging = editing
                // 松手补一次终值写入（合并通道保证最终一致）。
                if !editing, !isPreview {
                    BrightnessController.shared.requestWrite(model, percent: model.percent)
                }
            }
        )
        .controlSize(.small)
        .focusable(false)
        .focusEffectDisabled(true)
        // 滑杆不继承任何祖先动画：macOS 的 Slider 是 AppKit 滑杆包装，值变化
        // 一旦落在带动画的事务里就会被 NSSlider 的 animator 插值成「从旧值爬
        // 到新值」（实测 0 → 70 会逐帧爬升）；宿主设置页目录卡片与抽屉容器都
        // 挂着 `.animation(_:value:)`，其触发值只要与本次赋值同帧变化就会命中。
        // 这里在子树上把事务动画清成 nil（`.transaction` 覆盖其下全部内容），
        // 无论赋值来自回读落定还是跨实例同步都不会再被插值。
        .transaction { $0.animation = nil }
        .accessibilityLabel(Text(LF("a11y.slider.label", model.display.name)))
        .accessibilityValue(Text("\(Int(model.percent.rounded()))%"))
    }
}

// MARK: - 行式行（≥2 列或 ≥2 行）

private struct BrightnessRowView: View {
    @ObservedObject var model: BrightnessDisplayModel
    let isPreview: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(NotchTokens.Text.system( 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(model.display.name)
                .font(NotchTokens.Text.system( 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .help(model.display.name)
            BrightnessSliderControl(model: model, isPreview: isPreview)
        }
        .opacity(model.state == .ready ? 1 : 0.4)
    }
}

// MARK: - 1×1 紧凑行（单台屏：屏名一行 + 滑杆一行）

private struct CompactBrightnessRowView: View {
    @ObservedObject var model: BrightnessDisplayModel
    let isPreview: Bool

    var body: some View {
        VStack(spacing: CompactBrightnessMetrics.rowInnerSpacing) {
            // 屏名一行：图标 + 名称整体居中（1×1 是块内唯一可读标签）。
            HStack(spacing: 5) {
                Image(systemName: "sun.max")
                    .font(NotchTokens.Text.system( 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text(model.display.name)
                    .font(NotchTokens.Text.system( 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .help(model.display.name)
            }
            .frame(maxWidth: .infinity)
            BrightnessSliderControl(model: model, isPreview: isPreview)
        }
        .opacity(model.state == .ready ? 1 : 0.4)
    }
}
