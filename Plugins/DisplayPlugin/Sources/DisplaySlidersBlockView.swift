import NotchCenterKit
import SwiftUI

// MARK: - 抽屉块视图（每屏一行：屏名 + 亮度滑杆）

struct DisplaySlidersBlockView: View {
    let context: BlockContext
    @ObservedObject private var controller = BrightnessController.shared

    var body: some View {
        let size = context.layoutInfo.frame.size
        BlockCard(hoverEffect: false) { _ in
            Group {
                if controller.rows.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 12) {
                            ForEach(controller.rows) { model in
                                BrightnessRowView(
                                    model: model,
                                    isPreview: context.layoutInfo.isPreview)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
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
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(0.07)))
            Text(L("drawer.empty.title"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 行内滑杆的版式常量：占位空槽对齐滑杆高度，避免初值落定时行高跳动。
private enum BrightnessRowMetrics {
    /// `.controlSize(.small)` 滑杆的标准高度（实测 16pt）。
    static let sliderHeight: CGFloat = 16
    /// 占位空槽的槽高（贴近小尺寸滑杆的轨道粗细）。
    static let trackHeight: CGFloat = 3
}

private struct BrightnessRowView: View {
    @ObservedObject var model: BrightnessDisplayModel
    let isPreview: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(model.display.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .help(model.display.name)
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
        .opacity(model.state == .ready ? 1 : 0.4)
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
