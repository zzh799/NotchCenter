import SwiftUI

// MARK: - 双游标列数滑条（设置 → 布局「列数」区）

/// 双游标列数滑条的纯数学：值 ↔ 轨道分数、量化、游标选择与标签排布。
/// 与视图解耦以便单测（同 `DrawerPagePillLayout` 惯例）。
struct ColumnRangeSliderMath {
    /// 整条轨道代表的列数区间（`LayoutModel.maxColumnsRange`）。
    let valueRange: ClosedRange<Int>
    /// 左游标（最小列数）自身的下限（`LayoutModel.minColumnsRange.lowerBound`）。
    let minThumbFloor: Int

    init(
        valueRange: ClosedRange<Int> = LayoutModel.maxColumnsRange,
        minThumbFloor: Int = LayoutModel.minColumnsRange.lowerBound
    ) {
        self.valueRange = valueRange
        self.minThumbFloor = minThumbFloor
    }

    enum Thumb { case min, max }

    /// 值 → 轨道分数（0...1）。
    func fraction(for value: Int) -> CGFloat {
        let span = CGFloat(valueRange.upperBound - valueRange.lowerBound)
        guard span > 0 else { return 0 }
        return min(max(CGFloat(value - valueRange.lowerBound) / span, 0), 1)
    }

    /// 轨道分数 → 最近整数档，再夹进 clamped（调用方保证非空，见 `minThumbRange`）。
    func value(atFraction fraction: CGFloat, in clamped: ClosedRange<Int>) -> Int {
        let span = CGFloat(valueRange.upperBound - valueRange.lowerBound)
        let raw = CGFloat(valueRange.lowerBound) + (fraction * span).rounded()
        return min(max(Int(raw), clamped.lowerBound), clamped.upperBound)
    }

    /// 右游标（最大列数）候选值域：整条轨道，恒非空。
    var maxThumbRange: ClosedRange<Int> { valueRange }

    /// 左游标（最小列数）候选值域：floor...maxColumns；maxColumns 低于 floor 时退化成
    /// maxColumns...maxColumns（恒非空、游标钉死），与 `LayoutEngine.setUserMinColumns`
    /// 的"忽略写入"契约一致。绝不能构造空 ClosedRange（运行时 trap）。
    func minThumbRange(maxValue: Int) -> ClosedRange<Int> {
        let upper = min(maxValue, valueRange.upperBound)
        return min(minThumbFloor, upper)...upper
    }

    /// 左游标显示值：存储值按最大列数夹取（max 调小后 min 跟随显示，存储值原样
    /// 保留——"不回改存量值"契约，max 调回后原设置恢复）。
    func displayedMin(storedMin: Int, maxValue: Int) -> Int {
        min(max(storedMin, valueRange.lowerBound), maxValue)
    }

    /// 选择活动游标：取更近者。等距（两游标重合，或按在两颗正中）且尚无方向位移时
    /// 返回 nil 悬置——由首次位移方向分工：向左交给 min（向下扩范围）、向右交给
    /// max（向上扩），未越过死区前不认领也不提交。
    func thumb(
        atFraction fraction: CGFloat,
        minThumbFraction: CGFloat,
        maxThumbFraction: CGFloat,
        movement: CGFloat?
    ) -> Thumb? {
        let toMin = abs(fraction - minThumbFraction)
        let toMax = abs(fraction - maxThumbFraction)
        if toMin < toMax { return .min }
        if toMax < toMin { return .max }
        guard let movement, abs(movement) >= 2 else { return nil }
        return movement < 0 ? .min : .max
    }

    /// 标签排布：各标签中心锚在对应游标上、整体夹进轨道内；将重叠时对称推开。
    /// 返回两枚标签的左缘 x。
    func labelOrigins(
        minThumbCenter: CGFloat,
        minLabelWidth: CGFloat,
        maxThumbCenter: CGFloat,
        maxLabelWidth: CGFloat,
        trackWidth: CGFloat,
        minimumGap: CGFloat = 6
    ) -> (min: CGFloat, max: CGFloat) {
        var minOrigin = max(0, min(minThumbCenter - minLabelWidth / 2, trackWidth - minLabelWidth))
        var maxOrigin = max(0, min(maxThumbCenter - maxLabelWidth / 2, trackWidth - maxLabelWidth))
        let overlap = minOrigin + minLabelWidth + minimumGap - maxOrigin
        if overlap > 0 {
            minOrigin = max(0, minOrigin - overlap / 2)
            maxOrigin = min(trackWidth - maxLabelWidth, maxOrigin + overlap / 2)
        }
        return (minOrigin, maxOrigin)
    }
}

/// 设置 → 布局「列数」：最小列数 / 最大列数共用的一根双游标滑条。
/// 手势遵守胶囊行同款实测结论：整条滑条单条 `DragGesture(minimumDistance: 0)` 接管，
/// 不用 Button / TapGesture（AppKit 会接管按下、吞掉拖动的中间事件）。
/// 量化档位变化即回调（值未变的移动不回调），调用方经引擎 setter +
/// `refreshAfterLayoutChange` 让抽屉逐档立即重建。
struct ColumnRangeSlider: View {
    /// 左游标显示值（已按最大列数夹取）。
    let minValue: Int
    /// 右游标值。
    let maxValue: Int
    let onMinChange: (Int) -> Void
    let onMaxChange: (Int) -> Void

    private let math = ColumnRangeSliderMath()
    private let thumbDiameter: CGFloat = 16

    @State private var activeThumb: ColumnRangeSliderMath.Thumb?
    @State private var minLabelWidth: CGFloat = 0
    @State private var maxLabelWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 7) {
            slider
            labels
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        LF("settings.layout.columnRangeHelp", minValue, maxValue)
    }

    private var slider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let minX = math.fraction(for: minValue) * width
            let maxX = math.fraction(for: maxValue) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(width: width, height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, maxX - minX), height: 4)
                    .offset(x: minX)
                thumb(pinned: maxValue < LayoutModel.minColumnsRange.lowerBound)
                    .scaleEffect(activeThumb == .min ? 1.08 : 1)
                    .offset(x: minX - thumbDiameter / 2)
                thumb(pinned: false)
                    .scaleEffect(activeThumb == .max ? 1.08 : 1)
                    .offset(x: maxX - thumbDiameter / 2)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
        }
        .frame(height: 20)
    }

    private func thumb(pinned: Bool) -> some View {
        Circle()
            .fill(.white.opacity(pinned ? 0.5 : 0.98))
            .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
            .frame(width: thumbDiameter, height: thumbDiameter)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 1 else { return }
                let fraction = min(max(value.location.x / width, 0), 1)
                let thumb = activeThumb ?? math.thumb(
                    atFraction: fraction,
                    minThumbFraction: math.fraction(for: minValue),
                    maxThumbFraction: math.fraction(for: maxValue),
                    movement: value.location.x - value.startLocation.x
                )
                guard let thumb else { return }
                activeThumb = thumb
                commit(thumb, fraction: fraction)
            }
            .onEnded { _ in activeThumb = nil }
    }

    private func commit(_ thumb: ColumnRangeSliderMath.Thumb, fraction: CGFloat) {
        switch thumb {
        case .min:
            let candidate = math.value(atFraction: fraction, in: math.minThumbRange(maxValue: maxValue))
            if candidate != minValue { onMinChange(candidate) }
        case .max:
            let candidate = math.value(atFraction: fraction, in: math.maxThumbRange)
            if candidate != maxValue { onMaxChange(candidate) }
        }
    }

    private var labels: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let minLabel = LF("settings.layout.columnMin", minValue)
            let maxLabel = LF("settings.layout.columnMax", maxValue)
            let origins = math.labelOrigins(
                minThumbCenter: math.fraction(for: minValue) * width,
                minLabelWidth: minLabelWidth,
                maxThumbCenter: math.fraction(for: maxValue) * width,
                maxLabelWidth: maxLabelWidth,
                trackWidth: width
            )
            ZStack(alignment: .topLeading) {
                Color.clear
                measurementLabel(minLabel, tag: "min")
                    .offset(x: origins.min)
                measurementLabel(maxLabel, tag: "max")
                    .offset(x: origins.max)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .onPreferenceChange(ColumnRangeLabelWidthKey.self) { widths in
                if let width = widths["min"], minLabelWidth != width { minLabelWidth = width }
                if let width = widths["max"], maxLabelWidth != width { maxLabelWidth = width }
            }
        }
        .frame(height: 14)
    }

    private func measurementLabel(_ text: String, tag: String) -> some View {
        Text(text)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ColumnRangeLabelWidthKey.self,
                        value: [tag: geo.size.width]
                    )
                }
            )
    }
}

/// 双游标下方数值标签的实测宽度（按文本 tag 区分），供防撞排布。
private struct ColumnRangeLabelWidthKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
