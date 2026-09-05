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
            Text(L("drawer.empty.hint"))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
            Slider(
                value: Binding(
                    get: { model.percent },
                    set: { newValue in
                        // 拖动才落 DDC；程序回写（初值探针）只更新本地显示。
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
            .disabled(model.state != .ready)
            .focusable(false)
            .focusEffectDisabled(true)
            .accessibilityLabel(Text(LF("a11y.slider.label", model.display.name)))
            .accessibilityValue(Text("\(Int(model.percent.rounded()))%"))
        }
        .opacity(model.state == .ready ? 1 : 0.4)
    }
}
