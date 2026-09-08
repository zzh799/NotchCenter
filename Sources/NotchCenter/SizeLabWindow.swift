#if DEBUG
import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 块尺寸对照实验室（仅 DEBUG 构建）

/// 把同一块组件按抽屉网格的全部跨度组合（1×1、1×2、2×1、2×2 …… 上限可调）
/// 批量并排渲染，用于评估组件在各档尺寸下的观感，以及不同最小单元格
/// 取值对布局的影响。入口：
/// - 设置 → 调试 页的「打开 Size Lab」按钮（仅 DEBUG 构建显示）；
/// - 显式环境变量 `NOTCHCENTER_SIZE_LAB=1`（启动直开，自动化诊断用）。
///
/// 渲染管线与抽屉一致：块视图经 `makeView(BlockContext)` 创建（真实
/// StateStore / HostController），外层按跨度尺寸定 frame + 连续圆角裁切
/// （复刻 `DrawerBlockContainer` 的内容包装）。同一块类型的所有跨度单元格
/// 共享一个合成 placementID（`sizelab.<blockID>`）——与生产环境"同一放置
/// 实例的多屏视图副本"语义相同，插件按 placementID 注册的共享视图模型
/// 不会被逐格复制。
@MainActor
final class SizeLabWindowController {
    static let shared = SizeLabWindowController()

    private var window: NSWindow?

    func show(pluginManager: PluginManager, hostController: any HostController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Size Lab — 块尺寸对照"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: SizeLabView(pluginManager: pluginManager, hostController: hostController)
        )
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 自动化诊断（与其他探针同惯例）：NOTCHCENTER_SIZE_LAB_CAPTURE=<path>
        // 数秒后把实验室窗口渲染为 PNG 并退出。cacheDisplay 只出布局终态，
        // 本页无动画，足够；且自拍本进程窗口免屏幕录制权限。
        let capturePath = ProcessInfo.processInfo.environment["NOTCHCENTER_SIZE_LAB_CAPTURE"]
        if let capturePath, !capturePath.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                Self.captureWindow(window, to: capturePath)
                NSApp.terminate(nil)
            }
        }
    }

    private static func captureWindow(_ window: NSWindow, to path: String) {
        guard let contentView = window.contentView else { return }
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        contentView.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            NSLog("size-lab: captured \(Int(bounds.width))x\(Int(bounds.height)) -> \(path)")
        }
    }
}

// MARK: - 可调网格指标

/// 最小单元格定义。实验室初始值默认 **20×20**（评估远小于线上单元格的
/// 基础单元），间距沿用线上值；线上 `NotchGridMetrics` 常量见 `production`
/// （"恢复线上默认"按钮回到这里）。尺寸公式与线上一致：
/// 跨度尺寸 = n × 单元 + (n−1) × 间距。
private struct LabGridMetrics: Equatable {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var spacing: CGFloat

    init() {
        self.init(cellWidth: 20, cellHeight: 20, spacing: NotchGridMetrics.spacing)
    }

    /// 线上抽屉网格的固定常量。
    static var production: LabGridMetrics {
        LabGridMetrics(
            cellWidth: NotchGridMetrics.cellWidth,
            cellHeight: NotchGridMetrics.cellHeight,
            spacing: NotchGridMetrics.spacing
        )
    }

    init(cellWidth: CGFloat, cellHeight: CGFloat, spacing: CGFloat) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.spacing = spacing
    }

    func width(columns: Int) -> CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * spacing
    }

    func height(rows: Int) -> CGFloat {
        CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * spacing
    }

    /// 第 index 个跨度档（0-based，对应跨度 index+1）的内容原点。
    /// 累计推进：起点 = 前面所有更小档的**实际尺寸**之和 + index 个间距。
    /// 不能按固定格距推进——卡片宽度随跨度增长，格距原点会让大卡互相重叠。
    func origin(alongWidthAxis: Bool, atIndex index: Int) -> CGFloat {
        var offset: CGFloat = 0
        for preceding in 0..<index {
            offset += alongWidthAxis ? width(columns: preceding + 1) : height(rows: preceding + 1)
        }
        return offset + CGFloat(index) * spacing
    }

    /// 画布内容总尺寸：最后一档的原点 + 最后一档的实际尺寸。
    func extent(columns maxColumns: Int, rows maxRows: Int) -> CGSize {
        CGSize(
            width: origin(alongWidthAxis: true, atIndex: maxColumns - 1) + width(columns: maxColumns),
            height: origin(alongWidthAxis: false, atIndex: maxRows - 1) + height(rows: maxRows)
        )
    }
}

// MARK: - 对照组件

/// 一个可切换的对照组件：真实插件抽屉块，或内置占位卡。
private struct SizeLabComponent: Identifiable {
    let pluginID: String
    let blockID: String
    let title: String
    let stateStore: StateStore
    let makeView: @MainActor (BlockContext) -> AnyView

    var id: String { "\(pluginID).\(blockID)" }

    /// 合成放置实例：同一块类型的全部跨度单元格共享一份（多屏同实例语义）。
    var placementID: String { "sizelab.\(blockID)" }
}

// MARK: - 主视图

private struct SizeLabView: View {
    let pluginManager: PluginManager
    let hostController: any HostController

    // 最小单元格与对比范围（"定义最小单元格"的可调侧）。
    @State private var metrics = LabGridMetrics()
    @State private var maxColumns = 4
    @State private var maxRows = 3
    @State private var showsGrid = true

    @State private var selectedID: String?
    @State private var cells: [SizeLabCell] = []

    private let contentPadding: CGFloat = NotchGridMetrics.contentPadding
    private let cardCornerRadius: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().overlay(Color.white.opacity(0.06))
            canvas
            Divider().overlay(Color.white.opacity(0.06))
            footer
        }
        .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            if selectedID == nil {
                selectedID = components.first?.id
            }
            rebuildCells()
        }
        .onChange(of: selectedID) { _, _ in rebuildCells() }
        .onChange(of: maxColumns) { _, _ in rebuildCells() }
        .onChange(of: maxRows) { _, _ in rebuildCells() }
        // 单元格尺寸变化必须重摆画布：cell 的 origin/size 是构建时的快照。
        .onChange(of: metrics) { _, _ in rebuildCells() }
    }

    // MARK: 控制条

    private var controls: some View {
        HStack(spacing: 18) {
            Picker("组件", selection: $selectedID) {
                ForEach(components) { component in
                    Text(component.title).tag(Optional(component.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 300)

            GroupBox {
                HStack(spacing: 10) {
                    labStepper("单元宽", value: $metrics.cellWidth, in: 20...280, step: 2)
                    labStepper("单元高", value: $metrics.cellHeight, in: 20...220, step: 2)
                    labStepper("间距", value: $metrics.spacing, in: 4...24, step: 1)
                }
                .padding(2)
            } label: {
                Text("最小单元格")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            GroupBox {
                HStack(spacing: 10) {
                    labStepper("列至", value: $maxColumns, in: 1...6, step: 1)
                    labStepper("行至", value: $maxRows, in: 1...4, step: 1)
                }
                .padding(2)
            } label: {
                Text("对比范围")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Toggle("网格底衬", isOn: $showsGrid)
                .font(.system(size: 11))

            Spacer()

            Button {
                metrics = .production
                maxColumns = 4
                maxRows = 3
            } label: {
                Text("恢复线上默认")
            }
            .font(.system(size: 11))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func labStepper(
        _ title: String,
        value: Binding<CGFloat>,
        in range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            numberField(value, range: range)
            arrowStepper(value: value, range: range, step: step)
        }
    }

    private func labStepper(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            numberField(value, range: range)
            arrowStepper(value: value, range: range, step: step)
        }
    }

    /// 数值输入框：可直接键入（回车/失焦提交），越界钳制到合法区间。
    /// CGFloat 不在 TextField 格式化直连的范畴内，经 Double 中转。
    private func numberField(_ value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        TextField(
            "",
            value: Binding<Double>(
                get: { Double(value.wrappedValue) },
                set: {
                    let clamped = min(max($0, Double(range.lowerBound)), Double(range.upperBound))
                    value.wrappedValue = CGFloat(clamped)
                }
            ),
            format: .number.precision(.fractionLength(0))
        )
        .multilineTextAlignment(.trailing)
        .frame(width: 40)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11).monospacedDigit())
    }

    private func numberField(_ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        TextField("", value: clamped(value, range: range), format: .number)
            .multilineTextAlignment(.trailing)
            .frame(width: 40)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11).monospacedDigit())
    }

    /// 步进箭头（无标签，紧贴输入框）；步进与键入写同一个钳制绑定。
    private func arrowStepper<V: Strideable>(
        value: Binding<V>,
        range: ClosedRange<V>,
        step: V.Stride
    ) -> some View {
        Stepper {
            EmptyView()
        } onIncrement: {
            value.wrappedValue = min(range.upperBound, value.wrappedValue.advanced(by: step))
        } onDecrement: {
            value.wrappedValue = max(range.lowerBound, value.wrappedValue.advanced(by: -step))
        }
        .labelsHidden()
    }

    private func clamped(_ value: Binding<Int>, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    // MARK: 画布

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                if showsGrid {
                    unitGrid
                }
                ForEach(cells) { cell in
                    cell.view
                        .frame(width: cell.size.width, height: cell.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                        .overlay(alignment: .topLeading) { spanBadge(cell) }
                        .offset(x: cell.origin.x, y: cell.origin.y)
                }
            }
            .frame(
                width: canvasSize.width + contentPadding * 2,
                height: canvasSize.height + contentPadding * 2,
                alignment: .topLeading
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 单元格点阵底衬：让卡片"占了几格"一眼可读。
    private var unitGrid: some View {
        Path { path in
            for row in 0..<maxRows {
                for column in 0..<maxColumns {
                    path.addRect(CGRect(
                        x: contentPadding + CGFloat(column) * (metrics.cellWidth + metrics.spacing),
                        y: contentPadding + CGFloat(row) * (metrics.cellHeight + metrics.spacing),
                        width: metrics.cellWidth,
                        height: metrics.cellHeight
                    ))
                }
            }
        }
        .fill(Color.white.opacity(0.028))
    }

    private func spanBadge(_ cell: SizeLabCell) -> some View {
        Text("\(cell.columns)×\(cell.rows)  \(Int(cell.size.width))×\(Int(cell.size.height))")
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(5)
            .allowsHitTesting(false)
    }

    private var canvasSize: CGSize {
        metrics.extent(columns: maxColumns, rows: maxRows)
    }

    // MARK: 底部信息行

    private var footer: some View {
        HStack(spacing: 12) {
            Text("单元 \(Int(metrics.cellWidth))×\(Int(metrics.cellHeight)) · 间距 \(Int(metrics.spacing)) · 每档原点按累计实际尺寸推进")
            Text("跨度 \(cells.count) 个（列 1–\(maxColumns) × 行 1–\(maxRows)）")
            if metrics.cellWidth == NotchGridMetrics.cellWidth,
               metrics.cellHeight == NotchGridMetrics.cellHeight,
               metrics.spacing == NotchGridMetrics.spacing {
                Text("与线上 NotchGridMetrics 一致")
                    .foregroundStyle(.green.opacity(0.7))
            } else {
                Text("线上：\(Int(NotchGridMetrics.cellWidth))×\(Int(NotchGridMetrics.cellHeight)) / 间距 \(Int(NotchGridMetrics.spacing))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("组件经 makeView(BlockContext) 创建，与抽屉同一渲染管线")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 组件清单与单元格构建

    /// 占位卡（无插件依赖时的兜底对照物）。
    private static let placeholderComponent = SizeLabComponent(
        pluginID: "sizelab",
        blockID: "placeholder",
        title: "Placeholder（占位卡）",
        stateStore: StateStore(
            rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sizelab-placeholder-unused")
        ),
        makeView: { _ in
            AnyView(placeholderCard)
        }
    )

    private static var placeholderCard: some View {
        BlockCard(hoverEffect: true) { _ in
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                Text("占位卡")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                ProgressView(value: 0.6)
                    .frame(width: 80)
            }
        }
    }

    /// 可切换组件：全部已启用插件的真实抽屉块 + 占位卡兜底。
    private var components: [SizeLabComponent] {
        var result: [SizeLabComponent] = [Self.placeholderComponent]
        for entry in pluginManager.entries where entry.isEnabled && entry.instance != nil {
            guard let store = entry.stateStore else { continue }
            for block in entry.blocks where block.kind == .drawer {
                result.append(SizeLabComponent(
                    pluginID: entry.id,
                    blockID: block.id,
                    title: "\(entry.metadata.displayName) — \(block.displayName)",
                    stateStore: store,
                    makeView: block.makeView
                ))
            }
        }
        return result
    }

    private func rebuildCells() {
        guard let component = components.first(where: { $0.id == selectedID }) ?? components.first else {
            cells = []
            return
        }
        if component.id != selectedID {
            selectedID = component.id
        }
        var built: [SizeLabCell] = []
        for rowSpan in 1...maxRows {
            for columnSpan in 1...maxColumns {
                let size = CGSize(
                    width: metrics.width(columns: columnSpan),
                    height: metrics.height(rows: rowSpan)
                )
                let origin = CGPoint(
                    x: contentPadding + metrics.origin(alongWidthAxis: true, atIndex: columnSpan - 1),
                    y: contentPadding + metrics.origin(alongWidthAxis: false, atIndex: rowSpan - 1)
                )
                let context = BlockContext(
                    pluginID: component.pluginID,
                    blockID: component.blockID,
                    placementID: component.placementID,
                    stateStore: component.stateStore,
                    hostController: hostController,
                    layoutInfo: BlockLayoutInfo(
                        region: .drawer,
                        placementID: component.placementID,
                        frame: CGRect(origin: origin, size: size),
                        size: GridSpan(columns: columnSpan, rows: rowSpan),
                        originColumn: 0,
                        originRow: 0,
                        widthColumns: columnSpan,
                        heightRows: rowSpan,
                        isEditing: false
                    )
                )
                built.append(SizeLabCell(
                    columns: columnSpan,
                    rows: rowSpan,
                    origin: origin,
                    size: size,
                    view: component.makeView(context)
                ))
            }
        }
        cells = built
    }
}
// MARK: - 画布单元格

private struct SizeLabCell: Identifiable {
    let columns: Int
    let rows: Int
    let origin: CGPoint
    let size: CGSize
    let view: AnyView

    var id: String { "\(columns)x\(rows)" }
}
#endif
