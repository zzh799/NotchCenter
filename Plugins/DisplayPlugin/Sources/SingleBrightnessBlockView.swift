import NotchCenterKit
import SwiftUI

// MARK: - 单屏亮度条
//
// 一实例绑定一台屏（绑定逻辑见 SingleDisplayInstanceConfig），整块按当前形态
// 三选一（`SingleBrightnessPresentation` 纯逻辑，视图与测试共用）：
// - launcher（1×1）：图标块，点击或长按弹浮窗调光（按住不放可连拖，松手即关）；
// - compactFill（小单元）：整块当进度条，高亮填充表达百分比（首轮需求）；
// - detailed（大单元任一轴 >100）：标题 + 药丸滑杆 + thumb（截图风格）。
//
// 写入语义三形态共用：拖动中才落 DDC（`model.isDragging` 为真），其余程序回写
// 只更新本地显示；松手补一次终值写入。回读占位与事务动画规避沿用
// DisplaySlidersBlockView 的结论（先占位后出真值）。

/// 单屏条的版式形态：跨度 + 推导单元 → 布局（纯逻辑，视图与测试共用）。
enum SingleBrightnessPresentation: Equatable {
    /// 1×1：图标启动器（点按/长按弹浮窗）。
    case launcher
    /// 小单元：整块 fill（vertical 为真自底铺满，否则自左铺满）。
    case compactFill(vertical: Bool)
    /// 大单元：标题 + 药丸滑杆（vertical 为真纵向，否则横向）。
    case detailed(vertical: Bool)

    /// 大 UI 的单元阈值（pt）：单元宽或高任一轴超过即切截图风格。
    static let largeCellThreshold: CGFloat = 100
    /// 按住连拖走满 100% 所需的位移（pt，横竖同值）。
    static let fullRangeDragDistance: CGFloat = 150

    static func resolve(
        columns: Int?,
        rows: Int?,
        cellWidth: CGFloat?,
        cellHeight: CGFloat?
    ) -> SingleBrightnessPresentation {
        // 目录预览等无 span 上下文：按推荐尺寸（150×240 竖条）的形态兜底。
        guard let columns, let rows else { return .detailed(vertical: true) }
        if columns == 1 && rows == 1 { return .launcher }
        let vertical = columns < rows
        if let cellWidth, let cellHeight,
           cellWidth > largeCellThreshold || cellHeight > largeCellThreshold
        {
            return .detailed(vertical: vertical)
        }
        return .compactFill(vertical: vertical)
    }

    /// 由块 frame 与跨度反推单元尺寸。frame 含格间间距，推导值比真实单元略大，
    /// 阈值边界附近可能提前切大 UI；两套 UI 功能对等（都可直接调光），误判只
    /// 影响样式，不断功能，故此处不引入宿主单例做精确换算。
    static func cellSize(frame: CGSize, columns: Int, rows: Int) -> (width: CGFloat, height: CGFloat) {
        (frame.width / CGFloat(max(columns, 1)), frame.height / CGFloat(max(rows, 1)))
    }
}

/// DDC 写入的统一入口（三形态共用）：拖动中落盘，其余只更新本地显示。
/// 与 BrightnessSliderControl 的 Binding(set:) 同一语义，避免三份手势各写一遍。
@MainActor
func scrubSingleBrightness(_ model: BrightnessDisplayModel, to percent: Double, isPreview: Bool) {
    let clamped = min(max(percent, 0), 100)
    guard model.isDragging, !isPreview else {
        model.percent = clamped
        return
    }
    BrightnessController.shared.requestWrite(model, percent: clamped)
}

struct SingleBrightnessBlockView: View {
    let context: BlockContext
    @ObservedObject private var controller = BrightnessController.shared
    @ObservedObject private var instance: SingleDisplayInstanceModel

    init(context: BlockContext) {
        self.context = context
        _instance = ObservedObject(wrappedValue: SingleDisplayInstanceRegistry.model(
            placementID: context.placementID, stateStore: context.stateStore))
    }

    /// 本实例绑定的屏：存量 id 命中即用，缺失/消失回退第一台（不改写存储，
    /// 见 SingleDisplayInstanceConfig）；判定不可调节的屏不显示。
    private var model: BrightnessDisplayModel? {
        let rows = controller.rows
        guard !rows.isEmpty else { return nil }
        if let boundID = instance.config.displayID,
           let bound = controller.models[boundID], bound.state != .failed
        {
            return bound
        }
        return rows.first
    }

    private var presentation: SingleBrightnessPresentation {
        let info = context.layoutInfo
        let cell: (width: CGFloat, height: CGFloat)?
        if let columns = info.widthColumns, let rows = info.heightRows {
            cell = SingleBrightnessPresentation.cellSize(
                frame: info.frame.size, columns: columns, rows: rows)
        } else {
            cell = nil
        }
        return SingleBrightnessPresentation.resolve(
            columns: info.widthColumns, rows: info.heightRows,
            cellWidth: cell?.width, cellHeight: cell?.height)
    }

    var body: some View {
        let size = context.layoutInfo.frame.size
        BlockCard(hoverEffect: presentation == .launcher) { _ in
            Group {
                if let model {
                    switch presentation {
                    case .launcher:
                        SingleLauncherContent(
                            model: model,
                            isPreview: context.layoutInfo.isPreview)
                    case .compactFill(let vertical):
                        SingleFillContent(
                            model: model, vertical: vertical,
                            isPreview: context.layoutInfo.isPreview)
                    case .detailed(let vertical):
                        SingleDetailedContent(
                            model: model, vertical: vertical,
                            isPreview: context.layoutInfo.isPreview)
                    }
                } else {
                    SingleEmptyContent()
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
}

// MARK: - 空态

private struct SingleEmptyContent: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(NotchTokens.Text.system(22, weight: .light))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(0.07)))
            Text(L("drawer.empty.title"))
                .font(NotchTokens.Text.system(12, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 启动器（1×1）：图标 + 点按/长按浮窗

private struct SingleLauncherContent: View {
    @ObservedObject var model: BrightnessDisplayModel
    let isPreview: Bool

    /// 块在宿主窗口坐标系中的 frame（浮窗锚点，追踪布局变化）。
    @State private var anchorFrame: CGRect = .zero
    /// 本次按压起点（nil = 未按压；同时是长按定时 `.task(id:)` 的身份）。
    @State private var pressStart: Date?
    /// 长按已弹过浮窗（抑制其后的松手误判为点按）。
    @State private var popoverShown = false
    /// 弹浮窗瞬间的亮度（按住连拖的换算起点）。
    @State private var scrubStartPercent: Double = 0
    /// 弹浮窗后是否拖出过容忍距离（决定松手关还是留）。
    @State private var scrubbed = false

    var body: some View {
        Image(systemName: "sun.max")
            .font(NotchTokens.Text.system(20, weight: .medium))
            .foregroundStyle(model.state == .ready ? NotchTokens.Foreground.hover : NotchTokens.Foreground.unavailable)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { anchorFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            anchorFrame = newFrame
                        }
                }
            }
            .accessibilityLabel(Text(LF("a11y.slider.label", model.display.name)))
            .accessibilityValue(Text("\(Int(model.percent.rounded()))%"))
            .accessibilityAdjustableAction { direction in
                guard !isPreview, model.state == .ready else { return }
                model.isDragging = true
                scrubSingleBrightness(
                    model, to: model.percent + (direction == .increment ? 5 : -5),
                    isPreview: isPreview)
                model.isDragging = false
            }
            // 预览副本不挂手势：目录里的图标只读展示。
            .simultaneousGesture(isPreview ? nil : pressGesture)
            .task(id: pressStart) {
                // 长按定时器：按下满 0.2s（阈值与 BlockTapClassifier 同源）仍在
                // 同一按压中 → 弹浮窗。松手/拖走把 pressStart 置 nil 即取消。
                guard pressStart != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(BlockTapClassifier.longPressDuration))
                } catch {
                    return
                }
                guard pressStart != nil, !popoverShown, !isPreview else { return }
                beginScrubbing()
                SingleBrightnessPopover.present(model: model, anchoredTo: anchorFrame)
                popoverShown = true
            }
    }

    private var pressGesture: some Gesture {
        // 与 BlockPopoverTrigger 同一管线（minimumDistance 0 的 DragGesture，
        // .global 空间度量位移）：点按与长按同源，容忍距离内才算点击。
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pressStart == nil {
                    // 新按压起点：顺手把过期标记清掉。浮窗若已被点外部关闭，
                    // 本视图收不到通知，只能在下次按下时复位，否则误以为还开着。
                    pressStart = Date()
                    popoverShown = false
                    scrubbed = false
                }
                guard popoverShown else {
                    // 浮窗出现前的位移是滚动意图：取消待触发的浮窗。
                    if hypot(value.translation.width, value.translation.height)
                        > BlockTapClassifier.movementTolerance
                    {
                        pressStart = nil
                    }
                    return
                }
                // 浮窗已开且手没松：水平位移直接换算亮度（浮窗内是横向滑杆）。
                if hypot(value.translation.width, value.translation.height)
                    > BlockTapClassifier.movementTolerance
                {
                    scrubbed = true
                }
                scrubSingleBrightness(
                    model,
                    to: scrubStartPercent + value.translation.width
                        * (100 / SingleBrightnessPresentation.fullRangeDragDistance),
                    isPreview: isPreview)
            }
            .onEnded { value in
                let held = pressStart.map { Date().timeIntervalSince($0) } ?? 0
                let moved = hypot(value.translation.width, value.translation.height)
                    > BlockTapClassifier.movementTolerance
                if popoverShown {
                    model.isDragging = false
                    if !isPreview {
                        BrightnessController.shared.requestWrite(model, percent: model.percent)
                    }
                    // 拍板 A：按住连拖过的松手即关；纯长按未拖则留开（标准服务
                    // 浮窗行为，否则长按不拖会闪现即关）。
                    if scrubbed {
                        SingleBrightnessPopover.dismiss()
                        popoverShown = false
                    }
                } else if held < BlockTapClassifier.longPressDuration, !moved, !isPreview {
                    // 快速点按：弹开留置，点外部 / 抽屉收起时由浮窗自行关闭。
                    SingleBrightnessPopover.present(model: model, anchoredTo: anchorFrame)
                    popoverShown = true
                }
                pressStart = nil
                scrubbed = false
            }
    }

    private func beginScrubbing() {
        scrubStartPercent = model.percent
        model.isDragging = true
    }
}

// MARK: - 小 UI：整块 fill

private struct SingleFillContent: View {
    @ObservedObject var model: BrightnessDisplayModel
    let vertical: Bool
    let isPreview: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.15)
                if model.state == .ready {
                    Color.white.opacity(0.9)
                        .frame(
                            width: vertical ? nil : geo.size.width * model.percent / 100,
                            height: vertical ? geo.size.height * model.percent / 100 : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .bottom : .leading)
                }
                Image(systemName: "sun.max")
                    .font(NotchTokens.Text.system(18, weight: .medium))
                    // 填充区亮、非填充区暗：图标恒压一层阴影保证两区可读。
                    .foregroundStyle(NotchTokens.Foreground.selected)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .opacity(model.state == .ready ? 1 : 0.35)
            }
            .clipShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous))
            .contentShape(Rectangle())
            .gesture(fillGesture(size: geo.size))
            .accessibilityLabel(Text(LF("a11y.slider.label", model.display.name)))
            .accessibilityValue(Text("\(Int(model.percent.rounded()))%"))
        }
    }

    private func fillGesture(size: CGSize) -> some Gesture {
        // minimumDistance 0：点按即跳到该点，拖拽连续跟随；松手补终值写入。
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isPreview, model.state == .ready else { return }
                model.isDragging = true
                scrubSingleBrightness(model, to: percent(at: value.location, in: size), isPreview: isPreview)
            }
            .onEnded { _ in
                guard !isPreview else { return }
                model.isDragging = false
                BrightnessController.shared.requestWrite(model, percent: model.percent)
            }
    }

    private func percent(at location: CGPoint, in size: CGSize) -> Double {
        if vertical {
            guard size.height > 0 else { return model.percent }
            return (1 - location.y / size.height) * 100
        } else {
            guard size.width > 0 else { return model.percent }
            return location.x / size.width * 100
        }
    }
}

// MARK: - 大 UI：标题 + 药丸滑杆

private struct SingleDetailedContent: View {
    @ObservedObject var model: BrightnessDisplayModel
    let vertical: Bool
    let isPreview: Bool

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 10) {
                    titleRow
                    BrightnessPillSlider(model: model, vertical: true, isPreview: isPreview)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                // 横排固定度量按常规大单元（块高 ≥100）排布：扁宽极限格下可能顶满，
                // 滑杆仍全功能可调（只影响留白，不断功能）。
                VStack(alignment: .leading, spacing: 6) {
                    titleRow
                    BrightnessPillSlider(model: model, vertical: false, isPreview: isPreview)
                        .frame(height: SinglePillMetrics.thickness)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opacity(model.state == .ready ? 1 : 0.4)
    }

    private var titleRow: some View {
        HStack {
            Text(model.display.name)
                .font(NotchTokens.Text.system(12, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.body)
                .lineLimit(1)
                .help(model.display.name)
            Spacer(minLength: 4)
            Text("\(Int(model.percent.rounded()))%")
                .font(NotchTokens.Text.system(12, weight: .medium, design: .monospaced))
                .foregroundStyle(NotchTokens.Foreground.muted)
        }
    }
}

private enum SinglePillMetrics {
    /// 药丸轨道粗细（= thumb 直径，截图比例）。
    static let thickness: CGFloat = 30
    /// 图标字号（落在药丸内）。
    static let iconSize: CGFloat = 13
}

/// 大 UI 的药丸滑杆（横/竖同源）：拖 thumb、点轨道跳转、沿轨拖拽都走同一写入。
private struct BrightnessPillSlider: View {
    @ObservedObject var model: BrightnessDisplayModel
    let vertical: Bool
    let isPreview: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.22))
                if model.state == .ready {
                    fill(in: geo.size)
                } else {
                    // 回读占位：静态空槽，不渲染 0 值（同滑杆块的假动画规避）。
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.14))
                }
                if model.state == .ready {
                    thumb(in: geo.size)
                    Image(systemName: "sun.max")
                        .font(NotchTokens.Text.system(SinglePillMetrics.iconSize, weight: .medium))
                        // 图标压在药丸端头：填充盖过时用深色，否则用浅色。
                        .foregroundStyle(iconOnFill(in: geo.size)
                            ? Color.black.opacity(0.7) : NotchTokens.Foreground.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .bottom : .leading)
                        .padding(vertical ? .bottom : .leading, 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(pillGesture(size: geo.size))
            .accessibilityLabel(Text(LF("a11y.slider.label", model.display.name)))
            .accessibilityValue(Text("\(Int(model.percent.rounded()))%"))
        }
        // 滑杆值变化不继承祖先动画（AppKit 桥接插值规避见 BrightnessSliderControl）。
        .transaction { $0.animation = nil }
    }

    private func fill(in size: CGSize) -> some View {
        Group {
            if vertical {
                VStack {
                    Spacer(minLength: 0)
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .frame(height: max(size.height * model.percent / 100, 0))
                }
            } else {
                HStack {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: max(size.width * model.percent / 100, 0))
                    Spacer(minLength: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func thumb(in size: CGSize) -> some View {
        let diameter = SinglePillMetrics.thickness
        return Circle()
            .fill(Color.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .bottom : .leading)
            // 圆心落在填充末端：偏移半个 thumb 半径的线性映射。
            .offset(
                x: vertical ? 0 : thumbOffset(length: size.width, diameter: diameter),
                y: vertical ? -thumbOffset(length: size.height, diameter: diameter) : 0)
            .allowsHitTesting(false)
    }

    private func thumbOffset(length: CGFloat, diameter: CGFloat) -> CGFloat {
        // 圆在轨道两端时圆心距端点半个直径：行程 = 全长 - 直径，偏移与百分比成正比。
        let travel = max(length - diameter, 0)
        return travel * model.percent / 100
    }

    /// 图标是否落在填充区上（决定深浅色）：填充末端盖过图标位置即算。
    private func iconOnFill(in size: CGSize) -> Bool {
        let iconExtent: CGFloat = 8 + SinglePillMetrics.iconSize
        if vertical {
            return size.height * model.percent / 100 > iconExtent
        } else {
            return size.width * model.percent / 100 > iconExtent
        }
    }

    private func pillGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isPreview, model.state == .ready else { return }
                model.isDragging = true
                scrubSingleBrightness(model, to: percent(at: value.location, in: size), isPreview: isPreview)
            }
            .onEnded { _ in
                guard !isPreview else { return }
                model.isDragging = false
                BrightnessController.shared.requestWrite(model, percent: model.percent)
            }
    }

    private func percent(at location: CGPoint, in size: CGSize) -> Double {
        if vertical {
            guard size.height > 0 else { return model.percent }
            return (1 - location.y / size.height) * 100
        } else {
            guard size.width > 0 else { return model.percent }
            return location.x / size.width * 100
        }
    }
}

// MARK: - 浮窗（1×1 启动器的展开态：横向大 UI，拍板 B 带百分比）

@MainActor
enum SingleBrightnessPopover {
    static let cardSize = CGSize(width: 248, height: 96)

    static func present(model: BrightnessDisplayModel, anchoredTo frameInWindow: CGRect) {
        BlockPopover.shared.present(anchoredTo: frameInWindow, cardSize: cardSize) {
            SingleBrightnessPopoverContent(model: model)
        }
    }

    static func dismiss() {
        BlockPopover.shared.dismiss()
    }
}

private struct SingleBrightnessPopoverContent: View {
    @ObservedObject var model: BrightnessDisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.display.name)
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(model.percent.rounded()))%")
                    .font(NotchTokens.Text.system(12, weight: .medium, design: .monospaced))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
            BrightnessPillSlider(model: model, vertical: false, isPreview: false)
                .frame(height: SinglePillMetrics.thickness)
        }
        .padding(14)
        .frame(
            width: SingleBrightnessPopover.cardSize.width,
            height: SingleBrightnessPopover.cardSize.height)
        .transaction { $0.animation = nil }
    }
}

// MARK: - 实例设置（编辑模式齿轮：选屏 / 跟随第一台）

struct SingleDisplaySettingsView: View {
    @ObservedObject var instance: SingleDisplayInstanceModel
    @ObservedObject private var controller = BrightnessController.shared

    var body: some View {
        HStack {
            Text(L("single.display.section"))
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Spacer()
            Picker(
                L("single.display.section"),
                selection: Binding(
                    get: { instance.config.displayID },
                    set: { instance.update(SingleDisplayInstanceConfig(displayID: $0)) })
            ) {
                Text(L("single.followFirst")).tag(nil as UInt32?)
                ForEach(controller.rows) { model in
                    Text(model.display.name).tag(model.display.id as UInt32?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .task {
            await controller.startIfNeeded()
        }
    }
}
