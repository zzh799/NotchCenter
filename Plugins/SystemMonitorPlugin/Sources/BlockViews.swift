import NotchCenterKit
import SwiftUI

// MARK: - 指标块视图（单指标块与 All-in-one 共用一套 cell 原语）
//
// 布局策略（共识 Q5/Q6/Q11）：
// - 单指标块 1×1：指标名 + 当前值 + 迷你负载条；2×1：左值右 sparkline。
// - All-in-one 按跨度定方向：1×1 横向小条竖排（名称+聚合值）；1×2 竖排 / 2×1 横排
//   迷你 cell（名称+值+迷你条）；2×2/4×4 两列网格、4×2/4×3 横向一排；网格与横排内
//   画 sparkline 还是 MiniBar 看块实际像素（像素不够自动降级，方向不变）。
// - 阈值变色（共识 Q7-C）：CPU/磁盘/网络按实例阈值映射 白/黄/红，内存直接映射
//   内核压力等级（normal 绿）。方向色（读/写、下/上）只用于箭头与曲线。
//
// 视图不做跨重建的独占状态：数据全部来自共享 store 的 @Published 历史，
// 每实例差异（历史窗/阈值/单位/排除表/指标开关）来自注册表的实例模型。
// 宿主按 BlockViewCacheKey 复用视图，跨度变化会重走 makeView——单块视图
// 在创建时就拿到尺寸档，无需在视图内自建跨重建状态。

// MARK: - 展示原语（颜色与负载占比）

enum MetricPresentation {
    /// 方向色：读/下行蓝、写/上行橙。
    /// （数据可视化语义色,经审计豁免于"白+alpha"规范,唯一定义处,勿散抄。）
    static func directionColor(inbound: Bool) -> Color {
        inbound ? Color(red: 0.42, green: 0.75, blue: 1.0) : Color(red: 1.0, green: 0.62, blue: 0.30)
    }

    /// 等级色：high 红 / elevated 黄 / normal 白（内存 normal 为绿，共识 Q2-C）。
    static func levelColor(for kind: MetricKind, level: LoadLevel) -> Color {
        switch level {
        case .high:
            return Color(red: 1.0, green: 0.42, blue: 0.38)   // 等级色豁免:数据可视化
        case .elevated:
            return Color(red: 1.0, green: 0.78, blue: 0.35)   // 等级色豁免:数据可视化
        case .normal:
            return kind == .memory
                ? NotchTokens.Semantic.accentGreen
                : NotchTokens.Foreground.body
        }
    }

    /// 迷你负载条的填充占比：占比类用值本身，吞吐类对红阈值归一。
    static func loadFraction(
        kind: MetricKind,
        sample: MetricSample,
        thresholds: MetricThresholds,
        netExclusions: [String]
    ) -> Double {
        switch kind {
        case .cpu: return min(max(sample.cpuUsage, 0), 1)
        case .memory: return min(max(sample.memoryUsage, 0), 1)
        case .disk:
            let total = sample.diskReadRate + sample.diskWriteRate
            return thresholds.red > 0 ? min(max(total / thresholds.red, 0), 1) : 0
        case .network:
            let net = SystemMetricsLogic.aggregateNet(sample.netInterfaceRates, exclusions: netExclusions)
            return thresholds.red > 0 ? min(max((net.down + net.up) / thresholds.red, 0), 1) : 0
        }
    }

    /// 当前等级（内存走压力等级，其余走阈值）。
    static func level(
        for kind: MetricKind,
        sample: MetricSample,
        thresholds: MetricThresholds,
        netExclusions: [String]
    ) -> LoadLevel {
        switch kind {
        case .memory:
            return SystemMetricsLogic.level(of: sample.memoryPressure)
        case .cpu:
            return SystemMetricsLogic.level(sample.cpuUsage, thresholds: thresholds)
        case .disk:
            return SystemMetricsLogic.level(sample.diskReadRate + sample.diskWriteRate, thresholds: thresholds)
        case .network:
            let net = SystemMetricsLogic.aggregateNet(sample.netInterfaceRates, exclusions: netExclusions)
            return SystemMetricsLogic.level(net.down + net.up, thresholds: thresholds)
        }
    }
}

// MARK: - 序列推导（cell 与宽幅块共用）

struct MetricSeriesProvider {
    let kind: MetricKind
    let history: [MetricSample]
    let windowSeconds: Int
    let netExclusions: [String]

    private var now: Date { history.last?.timestamp ?? Date() }

    private func slice(_ field: (MetricSample) -> Double) -> [Double] {
        SystemMetricsLogic.windowSeries(history, windowSeconds: Double(windowSeconds), now: now, field: field)
    }

    func sparklineSeries() -> [(values: [Double], color: Color)] {
        switch kind {
        case .cpu:
            return [(SystemMetricsLogic.normalized(slice({ $0.cpuUsage }), fixedRange: true), Color.white.opacity(0.5))]
        case .memory:
            return [(SystemMetricsLogic.normalized(slice({ $0.memoryUsage }), fixedRange: true), Color.white.opacity(0.5))]
        case .disk:
            return [
                (SystemMetricsLogic.normalized(slice({ $0.diskReadRate }), fixedRange: false), MetricPresentation.directionColor(inbound: true)),
                (SystemMetricsLogic.normalized(slice({ $0.diskWriteRate }), fixedRange: false), MetricPresentation.directionColor(inbound: false)),
            ]
        case .network:
            return [
                (SystemMetricsLogic.normalized(slice({ netRate($0).down }), fixedRange: false), MetricPresentation.directionColor(inbound: true)),
                (SystemMetricsLogic.normalized(slice({ netRate($0).up }), fixedRange: false), MetricPresentation.directionColor(inbound: false)),
            ]
        }
    }

    /// 总量序列（归一化后），供宽幅单序列曲线。
    func totalSeries() -> [Double] {
        switch kind {
        case .cpu: return SystemMetricsLogic.normalized(slice({ $0.cpuUsage }), fixedRange: true)
        case .memory: return SystemMetricsLogic.normalized(slice({ $0.memoryUsage }), fixedRange: true)
        case .disk:
            return SystemMetricsLogic.normalized(slice({ $0.diskReadRate + $0.diskWriteRate }), fixedRange: false)
        case .network:
            return SystemMetricsLogic.normalized(slice({ netRate($0).down + netRate($0).up }), fixedRange: false)
        }
    }

    private func netRate(_ sample: MetricSample) -> NetRate {
        SystemMetricsLogic.aggregateNet(sample.netInterfaceRates, exclusions: netExclusions)
    }
}

// MARK: - sparkline

/// 归一化到 0…1 的多序列迷你曲线（调用方负责归一化）。
struct SparklineView: View {
    let series: [(values: [Double], color: Color)]

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 1.5
            let drawingHeight = size.height - inset * 2
            for item in series {
                let values = item.values
                guard !values.isEmpty else { continue }
                var path = Path()
                if values.count == 1 {
                    // 单点：底部基线小段，避免空图。
                    path.move(to: CGPoint(x: 0, y: size.height - inset))
                    path.addLine(to: CGPoint(x: size.width, y: size.height - inset))
                } else {
                    for (index, value) in values.enumerated() {
                        let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let y = size.height - inset - CGFloat(value) * drawingHeight
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                let traced = path.strokedPath(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                context.stroke(traced, with: .color(item.color), lineWidth: 1.2)
                // 单序列时垫一层渐变填充增强量感；多序列叠加时只描线防糊。
                if series.count == 1, values.count > 1 {
                    var fill = path
                    fill.addLine(to: CGPoint(x: size.width, y: size.height))
                    fill.addLine(to: CGPoint(x: 0, y: size.height))
                    fill.closeSubpath()
                    context.fill(fill, with: .color(item.color.opacity(0.16)))
                }
            }
        }
    }
}

/// 迷你负载条（1×1 档的退化形态）。
struct MiniBarView: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchTokens.Surface.track)
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: max(2, geo.size.width * CGFloat(fraction)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - 指标 cell（单指标块与总览格共用）

struct MetricCell: View {
    let kind: MetricKind
    let history: [MetricSample]
    let windowSeconds: Int
    let thresholds: MetricThresholds
    let rateUnit: RateUnitPreference
    let netExclusions: [String]
    /// false = 窄档：值 + 迷你负载条；true = 总览格 / 宽幅左列：值 + sparkline。
    let showsSparkline: Bool

    private var latest: MetricSample? { history.last }

    private var provider: MetricSeriesProvider {
        MetricSeriesProvider(
            kind: kind,
            history: history,
            windowSeconds: windowSeconds,
            netExclusions: netExclusions
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            valueArea
            Spacer(minLength: 0)
            trendArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbolName)
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.muted)
            Text(L(kind.displayNameKey))
                .font(NotchTokens.Text.system(9, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var valueArea: some View {
        switch kind {
        case .cpu, .memory:
            singleValue
        case .disk, .network:
            dualValue
        }
    }

    @ViewBuilder
    private var singleValue: some View {
        if let sample = latest {
            Text(percentText(sample))
                .font(NotchTokens.Text.system(17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(levelColor(sample))
        } else {
            waiting
        }
    }

    @ViewBuilder
    private var dualValue: some View {
        if let sample = latest, kind == .disk, !sample.diskAvailable {
            Text(L("state.unavailable"))
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.disabled)
        } else if let sample = latest {
            VStack(alignment: .leading, spacing: 2) {
                rateRow(sample: sample, inbound: true)
                rateRow(sample: sample, inbound: false)
            }
        } else {
            waiting
        }
    }

    private func rateRow(sample: MetricSample, inbound: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: inbound ? "arrow.down" : "arrow.up")
                .font(NotchTokens.Text.system(8, weight: .bold))
                .foregroundStyle(MetricPresentation.directionColor(inbound: inbound))
            Text(rateText(sample, inbound: inbound))
                .font(NotchTokens.Text.system(12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(levelColor(sample))
        }
    }

    private var waiting: some View {
        Text(L("state.sampling"))
            .font(NotchTokens.Text.system(11, weight: .medium))
            .foregroundStyle(NotchTokens.Foreground.disabled)
    }

    @ViewBuilder
    private var trendArea: some View {
        if showsSparkline {
            SparklineView(series: sparklineSeries)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        } else if let sample = latest {
            MiniBarView(
                fraction: MetricPresentation.loadFraction(
                    kind: kind, sample: sample, thresholds: thresholds, netExclusions: netExclusions
                ),
                color: levelColor(sample)
            )
        } else {
            MiniBarView(fraction: 0, color: Color.white.opacity(0.2))
        }
    }

    // MARK: 数据推导

    private var sparklineSeries: [(values: [Double], color: Color)] {
        var series = provider.sparklineSeries()
        // 占比类曲线跟随当前等级色（磁盘/网络保持方向色区分读写下/上下行）。
        if kind == .cpu || kind == .memory, let sample = latest {
            series[0].color = levelColor(sample)
        }
        return series
    }

    // MARK: 文案

    private func percentText(_ sample: MetricSample) -> String {
        switch kind {
        case .cpu: return SystemMetricsLogic.percentString(sample.cpuUsage)
        case .memory: return SystemMetricsLogic.percentString(sample.memoryUsage)
        case .disk, .network: return ""
        }
    }

    private func rateText(_ sample: MetricSample, inbound: Bool) -> String {
        let rate: Double
        switch kind {
        case .disk:
            rate = inbound ? sample.diskReadRate : sample.diskWriteRate
        case .network:
            let net = SystemMetricsLogic.aggregateNet(sample.netInterfaceRates, exclusions: netExclusions)
            rate = inbound ? net.down : net.up
        case .cpu, .memory:
            rate = 0
        }
        return SystemMetricsLogic.rateString(rate, unit: rateUnit)
    }

    private func levelColor(_ sample: MetricSample) -> Color {
        MetricPresentation.levelColor(
            for: kind,
            level: MetricPresentation.level(
                for: kind, sample: sample, thresholds: thresholds, netExclusions: netExclusions
            )
        )
    }

    private var accessibilitySummary: String {
        guard let sample = latest else { return L("state.sampling") }
        let name = L(kind.displayNameKey)
        switch kind {
        case .cpu, .memory:
            let extra = kind == .memory ? ", \(L(pressureKey(sample.memoryPressure)))" : ""
            return "\(name) \(percentText(sample))\(extra)"
        case .disk, .network:
            return "\(name) \(rateText(sample, inbound: true)), \(rateText(sample, inbound: false))"
        }
    }

    private func pressureKey(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: return "pressure.normal"
        case .warning: return "pressure.warning"
        case .critical: return "pressure.critical"
        }
    }
}

// MARK: - 生命周期挂件（登记 + 探针；isPreview 副本一律不参与）

struct BlockLifecycleHooks: ViewModifier {
    let placementID: String
    let isPreview: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if !isPreview {
                    WindowVisibilityProbe(
                        onAttach: { windowID, isVisible in
                            SystemMonitorStore.shared.probeAttached(windowID: windowID, isVisible: isVisible)
                        },
                        onDetach: { windowID in
                            SystemMonitorStore.shared.probeDetached(windowID: windowID)
                        },
                        onVisibilityChange: { windowID, isVisible in
                            SystemMonitorStore.shared.probeVisibilityChanged(windowID: windowID, isVisible: isVisible)
                        }
                    )
                }
            }
            .onAppear {
                guard !isPreview else { return }
                SystemMonitorStore.shared.viewDidAppear(placementID: placementID)
            }
            .onDisappear {
                guard !isPreview else { return }
                SystemMonitorStore.shared.viewDidDisappear(placementID: placementID)
            }
    }
}

// MARK: - 单指标块

struct MetricBlockView: View {
    let kind: MetricKind
    @ObservedObject var instance: SystemMonitorInstanceModel
    let placementID: String
    let isPreview: Bool
    /// 2×1 档：true 时值列右侧展开 sparkline（1×1 为迷你负载条）。
    let showsSparkline: Bool
    /// 宿主下发的块实际像素（layoutInfo.frame.size）；像素不够时宽幅曲线自动降级为 mini（MiniBar 保留）。
    var contentSize: CGSize = .zero

    @ObservedObject private var store = SystemMonitorStore.shared

    private var thresholds: MetricThresholds {
        InstanceConfigLogic.effectiveThresholds(kind: kind, config: instance.single)
    }

    private var netExclusions: [String] {
        InstanceConfigLogic.effectiveNetExclusions(instance.single)
    }

    /// 格数要曲线且像素放得下时才真画宽幅曲线。
    private var effectiveShowsSparkline: Bool {
        showsSparkline && MetricCellForm.showsWideSparkline(contentSize: contentSize)
    }

    var body: some View {
        BlockCard { _ in
            if effectiveShowsSparkline {
                HStack(alignment: .center, spacing: 12) {
                    MetricCell(
                        kind: kind,
                        history: store.history,
                        windowSeconds: instance.single.windowSeconds,
                        thresholds: thresholds,
                        rateUnit: instance.single.rateUnit,
                        netExclusions: netExclusions,
                        showsSparkline: false
                    )
                    .frame(width: 92)
                    SparklineView(series: wideSeries)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .padding(10)
            } else {
                MetricCell(
                    kind: kind,
                    history: store.history,
                    windowSeconds: instance.single.windowSeconds,
                    thresholds: thresholds,
                    rateUnit: instance.single.rateUnit,
                    netExclusions: netExclusions,
                    showsSparkline: false
                )
                .padding(10)
            }
        }
        .modifier(BlockLifecycleHooks(placementID: placementID, isPreview: isPreview))
    }

    private var wideSeries: [(values: [Double], color: Color)] {
        var series = MetricSeriesProvider(
            kind: kind,
            history: store.history,
            windowSeconds: instance.single.windowSeconds,
            netExclusions: netExclusions
        ).sparklineSeries()
        if kind == .cpu || kind == .memory, let sample = store.history.last {
            series[0].color = MetricPresentation.levelColor(
                for: kind,
                level: MetricPresentation.level(
                    for: kind, sample: sample, thresholds: thresholds, netExclusions: netExclusions
                )
            )
        }
        return series
    }
}

// MARK: - All-in-one（系统总览）块

struct OverviewBlockView: View {
    @ObservedObject var instance: SystemMonitorInstanceModel
    let placementID: String
    let isPreview: Bool
    /// 抽屉与目录预览路径宿主恒填跨度；nil 仅出现在无落位上下文的防御路径
    ///（OverviewArrangement 按推荐 2×2 的网格形态兜底）。
    let widthColumns: Int?
    let heightRows: Int?
    /// 宿主下发的块实际像素（layoutInfo.frame.size）；曲线形态像素不够时自动降级为同布局的 MiniBar cell。
    var contentSize: CGSize = .zero

    @ObservedObject private var store = SystemMonitorStore.shared

    private var arrangement: OverviewArrangement {
        OverviewArrangement.forSpan(widthColumns: widthColumns, heightRows: heightRows)
    }

    /// 有曲线形态在当前像素下是否真画 sparkline；false 时同布局改走 MiniBar cell（方向不变）。
    private var sparklineAllowed: Bool {
        OverviewArrangement.showsSparkline(
            arrangement: arrangement,
            contentSize: contentSize,
            enabledCount: enabledKinds.count
        )
    }

    private var enabledKinds: [MetricKind] {
        MetricKind.allCases.filter { instance.overview.enabled.contains($0) }
    }

    var body: some View {
        BlockCard { _ in
            Group {
                if store.history.isEmpty {
                    waitingPlaceholder
                } else {
                    switch arrangement {
                    case .compactStrips:
                        VStack(spacing: 4) {
                            ForEach(enabledKinds, id: \.self) { kind in
                                CompactMetricStrip(
                                    kind: kind,
                                    history: store.history,
                                    netExclusions: SystemMetricsLogic.defaultNetExclusions
                                )
                            }
                        }
                    case .stackedMiniCells:
                        VStack(spacing: 6) {
                            ForEach(enabledKinds, id: \.self) { kind in
                                cell(kind, showsSparkline: false)
                            }
                        }
                    case .miniCellRow:
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(enabledKinds, id: \.self) { kind in
                                cell(kind, showsSparkline: false)
                            }
                        }
                    case .sparklineGrid:
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(enabledKinds, id: \.self) { kind in
                                cell(kind, showsSparkline: sparklineAllowed)
                            }
                        }
                    case .sparklineRow:
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(enabledKinds, id: \.self) { kind in
                                cell(kind, showsSparkline: sparklineAllowed)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .modifier(BlockLifecycleHooks(placementID: placementID, isPreview: isPreview))
    }

    private func cell(_ kind: MetricKind, showsSparkline: Bool) -> some View {
        MetricCell(
            kind: kind,
            history: store.history,
            windowSeconds: instance.overview.windowSeconds,
            thresholds: SystemMetricsLogic.defaultThresholds(for: kind),
            rateUnit: .auto,
            netExclusions: SystemMetricsLogic.defaultNetExclusions,
            showsSparkline: showsSparkline
        )
    }

    private var waitingPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge")
                .font(NotchTokens.Text.system(10, weight: .medium))
            Text(L("state.sampling"))
                .font(NotchTokens.Text.system(10, weight: .medium))
        }
        .foregroundStyle(NotchTokens.Foreground.disabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 1×1 总览档的横向小条：名称 + 聚合当前值（吞吐类读+写 / 下+上合并——
/// 单行放不下双值，且 cellWidth 可缩到 90pt）。
struct CompactMetricStrip: View {
    let kind: MetricKind
    let history: [MetricSample]
    let netExclusions: [String]

    private var latest: MetricSample? { history.last }

    var body: some View {
        HStack(spacing: 6) {
            Text(L(kind.displayNameKey))
                .font(NotchTokens.Text.system(9, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            valueText
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var valueText: some View {
        if let sample = latest, kind == .disk, !sample.diskAvailable {
            Text(L("state.unavailable"))
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.disabled)
        } else if let sample = latest {
            Text(valueString(sample))
                .font(NotchTokens.Text.system(12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(levelColor(sample))
                .lineLimit(1)
        } else {
            Text(L("state.sampling"))
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.disabled)
        }
    }

    private func valueString(_ sample: MetricSample) -> String {
        switch kind {
        case .cpu: return SystemMetricsLogic.percentString(sample.cpuUsage)
        case .memory: return SystemMetricsLogic.percentString(sample.memoryUsage)
        case .disk:
            return SystemMetricsLogic.rateString(sample.diskReadRate + sample.diskWriteRate, unit: .auto)
        case .network:
            let net = SystemMetricsLogic.aggregateNet(sample.netInterfaceRates, exclusions: netExclusions)
            return SystemMetricsLogic.rateString(net.down + net.up, unit: .auto)
        }
    }

    private func levelColor(_ sample: MetricSample) -> Color {
        MetricPresentation.levelColor(
            for: kind,
            level: MetricPresentation.level(
                for: kind,
                sample: sample,
                thresholds: SystemMetricsLogic.defaultThresholds(for: kind),
                netExclusions: netExclusions
            )
        )
    }

    private var accessibilitySummary: String {
        guard let sample = latest else { return L("state.sampling") }
        return "\(L(kind.displayNameKey)) \(valueString(sample))"
    }
}
