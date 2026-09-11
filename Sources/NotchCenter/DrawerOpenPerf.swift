import AppKit
import Foundation

// MARK: - 抽屉打开性能诊断

/// 抽屉展开性能诊断开关（`NOTCHCENTER_DRAWER_PERF=1`；与
/// `DragPerfLog` / `DrawerScrollProbe` 同族的环境变量探针，默认关闭）。
///
/// 为什么需要它：展开路径的耗时分布在**宿主侧重建**（`rebuildContent` 的
/// 元素构建 + 插件 `makeView`）、**SwiftUI 挂载/布局**（N 个块视图 + 每块
/// 1~2 个 GeometryReader）、**固定延迟的内容淡入**三段里，三者的优化手段
/// 完全不同（见 `docs/agent-notes/implemented/2026-09-11-drawer-open-timing.md`）。
/// 没有分解读数就只能猜——本探针给每一段一个毫秒数。
///
/// `NOTCHCENTER_DRAWER_BENCH=1` 时同样生效（自动基准由 `AppDelegate` 驱动，
/// 见 `maybeRunDrawerOpenBench`）。
enum DrawerOpenPerfLog {
    static let enabled = ProcessInfo.processInfo.environment["NOTCHCENTER_DRAWER_PERF"] == "1"
        || ProcessInfo.processInfo.environment["NOTCHCENTER_DRAWER_BENCH"] != nil
}

/// 单次展开的性能分解器。
///
/// 一次「冷展开」（收起 → 展开）＝一个会话，埋点按时间顺序落进
/// `Stage`，`enter` 为 0 基准。会话在最后一个阶段（`.visible`）自动收尾并
/// 打印一行分解；任一段超时未到达（例如内容分支没进树）由看门狗兜底收尾，
/// 读数标 `incomplete`——**不吞样本**，漏阶段本身就是要看的信号。
///
/// 与 `DragPerfCollector` 同款约束：**刻意一个 `@Published` 都不加**，
/// 否则探针自己会触发重绘、把测量对象变成被测负载。
@MainActor
final class DrawerOpenPerfCollector {
    /// 生产路径共用的一份（单次展开同一时刻只有一个会话）。
    static let shared = DrawerOpenPerfCollector()

    /// 可自由构造（单测注入）：`forceEnabled` 绕过环境变量开关、
    /// `watchdogSeconds` 缩短未完成样本的兜底窗口、`log` 收走输出行。
    /// 生产路径一律走 `shared` 的默认参数。
    init(
        forceEnabled: Bool = false,
        watchdogSeconds: Double = 5,
        log: @escaping (String) -> Void = { print($0) }
    ) {
        self.forceEnabled = forceEnabled
        self.watchdogSeconds = watchdogSeconds
        self.log = log
    }

    private let forceEnabled: Bool
    private let watchdogSeconds: Double
    private let log: (String) -> Void

    /// 本次是否埋点（环境变量或测试注入，二者取或）。
    private var isEnabled: Bool { forceEnabled || DrawerOpenPerfLog.enabled }

    /// 展开路径的阶段（枚举顺序 = 期望到达顺序）。
    enum Stage: String, CaseIterable {
        /// `expand()` 冷路径入口（守卫通过、开始动状态之前）。
        case enter
        /// `rebuildContent()` 返回（宿主侧元素构建 + 可能发生的 `makeView`）。
        case rebuilt
        /// 窗口上线 + 尺寸 spring 起播（`setDrawerRevealed` 之后）。
        case revealed
        /// SwiftUI 已把内容分支插入视图树（`DrawerPanelView.onChange` 展开分支）。
        case inserted
        /// 宿主视图完成展开后的首次布局（内容树构建 + 布局走完）。
        case laidOut
        /// 内容淡入完成（用户看到完整抽屉；≈ 感知到的"打开了"）。
        case visible
    }

    /// 一次展开的读数（报告与统计的最小单位）。
    struct Sample {
        /// 调用方给的会话标签（基准的 `r<轮>p<页>`；生产路径为空）。
        let label: String
        let page: Int
        let pageCount: Int
        let drawerBlocks: Int
        let compactSlots: Int
        /// 本次展开里真正调用 `makeView` 的次数（缓存未命中）。
        let makeViewCalls: Int
        /// 本次展开里命中视图复用缓存的次数。
        let cacheHits: Int
        /// 各阶段相对 `enter` 的毫秒数（看门狗收尾时缺失阶段为 nil）。
        let marks: [Stage: Double]

        /// 宿主侧重建耗时（元素构建 + 未命中的 makeView）。
        var rebuildMs: Double? { marks[.rebuilt] }
        /// 窗口上线耗时（重建之后到 spring 起播）。
        var revealMs: Double? { marks[.revealed] }
        /// SwiftUI 挂载 + 首次布局耗时：`revealed → laidOut`，N 的主战场。
        var mountMs: Double? {
            guard let a = marks[.revealed], let b = marks[.laidOut] else { return nil }
            return b - a
        }
        /// 展开起点 → 内容淡入完成：用户实际等待的全量。
        var visibleMs: Double? { marks[.visible] }
        var isComplete: Bool { Stage.allCases.allSatisfy { marks[$0] != nil } }
    }

    private struct Session {
        let id: Int
        let label: String
        let startedAt: CFTimeInterval
        var marks: [Stage: Double] = [:]
        var page = 0
        var pageCount = 0
        var drawerBlocks = 0
        var compactSlots = 0
        var makeViewCalls = 0
        var cacheHits = 0
    }

    /// 下一次 `begin()` 的标签（基准在触发展开前写入；生产路径恒为空）。
    var pendingLabel = ""

    private var session: Session?
    private var nextID = 1
    /// 已收尾样本（基准汇总用）。
    private(set) var samples: [Sample] = []

    // MARK: 会话生命周期

    /// 开始一次冷展开会话。已有未收尾会话时先按"未完成"收尾（不丢样本）。
    /// `label` 只用于报告里对齐调用方语境（如基准的 `r<轮>p<页>`）：
    /// 传空则取 `pendingLabel`。展开路径（控制器）不感知基准，标签由基准在
    /// 触发展开前写 `pendingLabel`——探针不该为诊断反向污染生产路径的签名。
    func begin(label: String = "") {
        guard isEnabled else { return }
        if session != nil { finish(reason: "superseded") }
        let id = nextID
        nextID += 1
        let resolved = label.isEmpty ? pendingLabel : label
        pendingLabel = ""
        session = Session(id: id, label: resolved, startedAt: CACurrentMediaTime())
        mark(.enter)
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogSeconds) { [weak self] in
            guard let self, self.session?.id == id else { return }
            self.finish(reason: "watchdog")
        }
    }

    /// 落一个阶段：只记首次到达（重复埋点不覆盖首个读数）。
    func mark(_ stage: Stage) {
        guard isEnabled, var session else { return }
        guard session.marks[stage] == nil else { return }
        session.marks[stage] = (CACurrentMediaTime() - session.startedAt) * 1000
        let done = stage == .visible
        self.session = session
        if done { finish(reason: nil) }
    }

    /// 本次展开的内容规模（`rebuildContent` 末尾一处写入，供报告解读 N）。
    func noteContent(
        page: Int,
        pageCount: Int,
        drawerBlocks: Int,
        compactSlots: Int
    ) {
        guard isEnabled, var session else { return }
        session.page = page
        session.pageCount = pageCount
        session.drawerBlocks = drawerBlocks
        session.compactSlots = compactSlots
        self.session = session
    }

    /// 记一次 `makeView`（缓存未命中：插件侧构造视图 + SwiftUI 全新子树）。
    func noteMakeView() {
        guard isEnabled, var session else { return }
        session.makeViewCalls += 1
        self.session = session
    }

    /// 记一次视图复用缓存命中（跳过 `makeView`，只复用上次的视图值）。
    func noteCacheHit() {
        guard isEnabled, var session else { return }
        session.cacheHits += 1
        self.session = session
    }

    /// 宿主视图完成一次布局（`DrawerHostingView.layout()` 调）。
    /// 展开后的**首次**布局即"内容树构建 + 布局走完"的界标。
    func noteHostLayout(isExpanded: Bool) {
        guard isEnabled, isExpanded, let session, session.marks[.laidOut] == nil else {
            return
        }
        mark(.laidOut)
    }

    /// 是否有未收尾会话（基准用：事件驱动地等一次展开读完再开下一次，
    /// 避免"上一次的 mount 还没落、下一次已经开始"的会话重叠串味）。
    var isSessionActive: Bool { session != nil }

    // MARK: 测试支持（命名与 `LayoutEngine.modelForTesting` 同惯例）

    /// 写入某阶段的**指定**相对毫秒数，绕过真实时钟——报告格式与聚合统计
    /// 需要确定性输入才可断言。`.visible` 与其他阶段同语义（触发收尾）。
    func markAtForTesting(_ stage: Stage, milliseconds: Double) {
        guard isEnabled, var session else { return }
        session.marks[stage] = milliseconds
        let done = stage == .visible
        self.session = session
        if done { finish(reason: nil) }
    }

    /// 读进行中会话的某阶段读数（nil = 尚未到达或无会话）。
    func sessionMarkForTesting(_ stage: Stage) -> Double? {
        session?.marks[stage]
    }

    /// 收尾并打印一行分解；`reason` 非空表示异常收尾（标 incomplete）。
    /// 幂等靠 `self.session = nil` 一处保证：三条收尾路径（末段埋点、看门狗、
    /// 新展开顶掉旧会话）不会有第二条生效。
    private func finish(reason: String?) {
        guard let session else { return }
        self.session = nil
        let sample = Sample(
            label: session.label,
            page: session.page,
            pageCount: session.pageCount,
            drawerBlocks: session.drawerBlocks,
            compactSlots: session.compactSlots,
            makeViewCalls: session.makeViewCalls,
            cacheHits: session.cacheHits,
            marks: session.marks
        )
        samples.append(sample)
        log(Self.line(for: sample, index: samples.count, reason: reason))
    }

    // MARK: 报告

    /// 单行分解（字段名与探针族一致：`[drawer-perf]` 前缀便于 grep）。
    static func line(for sample: Sample, index: Int, reason: String?) -> String {
        func ms(_ stage: Stage) -> String {
            guard let value = sample.marks[stage] else { return "-" }
            return String(format: "%.1f", value)
        }
        let tag = sample.label.isEmpty ? "" : " [\(sample.label)]"
        var text = String(
            format: "[drawer-perf] open#%d%@ page=%d/%d blocks=%d compact=%d "
                + "makeView=%d cache=%d rebuild=%@ms reveal=%@ms mount=%@ms "
                + "insert=%@ms layout=%@ms visible=%@ms",
            index,
            tag as NSString,
            sample.page,
            sample.pageCount,
            sample.drawerBlocks,
            sample.compactSlots,
            sample.makeViewCalls,
            sample.cacheHits,
            ms(.rebuilt),
            ms(.revealed),
            sample.mountMs.map { String(format: "%.1f", $0) } ?? "-",
            ms(.inserted),
            ms(.laidOut),
            ms(.visible)
        )
        if let reason {
            text += " incomplete(\(reason))"
        }
        return text
    }

    /// 基准汇总表：按页（= 块数）分组，给出 mount / visible 的最小、中位、最大。
    func report() -> String {
        guard !samples.isEmpty else { return "[drawer-perf] 无样本" }
        var lines = [
            "=== 抽屉打开基准（逐页逐轮，单位 ms；mount = 窗口上线→首次布局，"
                + "visible = 展开入口→内容淡入完成）===",
            "page  blocks  runs  makeView  mount(min/med/max)      visible(min/med/max)",
        ]
        let byPage = Dictionary(grouping: samples, by: \.page).sorted { $0.key < $1.key }
        for (page, group) in byPage {
            let mounts = group.compactMap(\.mountMs).sorted()
            let visibles = group.compactMap(\.visibleMs).sorted()
            let makeViews = group.map(\.makeViewCalls).reduce(0, +)
            lines.append(
                String(
                    format: "%-5d %-7d %-5d %-9d %-22@ %@",
                    page,
                    group.first?.drawerBlocks ?? 0,
                    group.count,
                    makeViews,
                    Self.triple(mounts) as NSString,
                    Self.triple(visibles) as NSString
                )
            )
        }
        let allMounts = samples.compactMap(\.mountMs)
        let allVisibles = samples.compactMap(\.visibleMs)
        lines.append("--- 合计：\(samples.count) 次展开；"
            + "mount \(Self.triple(allMounts.sorted()))；"
            + "visible \(Self.triple(allVisibles.sorted()))；"
            + "未完成 \(samples.filter { !$0.isComplete }.count) 次")
        return lines.joined(separator: "\n")
    }

    private static func triple(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let median = values[values.count / 2]
        return String(
            format: "%.1f / %.1f / %.1f",
            values.first ?? 0,
            median,
            values.last ?? 0
        )
    }
}

// MARK: - 合成基准布局（N 曲线，可复量）

/// `NOTCHCENTER_DRAWER_BENCH=synthetic` 用的合成布局：把**已加载可用的块型**
/// （pluginID / blockID / 跨度）按面积从大到小循环填进 `pageBlockCounts` 六页，
/// 货架式排布（逐行从左到右，行高取该行最矮块）。
///
/// 为什么要有它：优化做完必须用**同一份**布局复量，数字才可比；用户真实布局
/// 既不可控（组件会被增删）也不可复现（换台机器就变），而未安装插件的块会被
/// 宿主静默跳过、把 N 曲线打成残废——所以块型只能取自本机**已加载**的块。
///
/// 两道防写坏用户数据的闸：
/// 1. `redirectLayoutFile()` 在控制器构造前把 `NOTCHCENTER_LAYOUT_FILE` 指到
///    临时文件（并顺手把真实布局复制过去当模板）——合成模型落盘只落在临时文件；
/// 2. 合成发生在控制器起来**之后**（插件已加载，才拿得到可用块型），
///    经 `LayoutEngine.modelForTesting` 换模型并重建内容。
enum DrawerBenchLayout {
    /// 基准模式：`nCurve` = 逐页递增块数（量"块数 → 耗时"），
    /// `uniform` = 每页 12 枚同型块（量"哪个块型贵"）。
    enum Mode {
        case nCurve
        case uniform

        var pageLabel: String {
            switch self {
            case .nCurve: return "N曲线"
            case .uniform: return "同型对照"
            }
        }
    }

    /// 每页块数（= N 曲线的采样点）。
    static let pageBlockCounts = [2, 4, 8, 12, 16, 20]
    /// 同型对照每页的块数（块型之间可比；12 枚足以拉开差距又不至于爆屏）。
    static let uniformPageBlocks = 12
    /// 货架排布的每行宽度上限（列）：取够放下两块 4×4 即可，宽度进不了测量
    /// 口径（面板宽由用户列数配置与屏幕容量决定），只影响块的相邻关系。
    static let rowColumns = 8
    /// 合成布局写出的位置（跑完不清理：/tmp 由系统回收）。
    static let syntheticLayoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("notchcenter-drawer-bench-layout.json")

    /// 请求的基准模式；非合成模式返回 nil。
    static var requestedMode: Mode? {
        switch ProcessInfo.processInfo.environment["NOTCHCENTER_DRAWER_BENCH"] {
        case "synthetic", "ncurve": return .nCurve
        case "uniform": return .uniform
        default: return nil
        }
    }

    /// 把布局读写重定向到临时文件。**必须在 `NotchPanelController()` 之前调用**
    /// ——布局是引擎 init 时读盘的。真实布局存在时先复制过去，让引擎照常加载
    /// （启用状态、列数配置等模板字段仍来自用户配置），后续写入只落临时文件。
    static func redirectLayoutFile() {
        if let data = try? Data(contentsOf: CorePaths.layoutFileURL) {
            try? data.write(to: syntheticLayoutURL, options: .atomic)
        }
        setenv("NOTCHCENTER_LAYOUT_FILE", syntheticLayoutURL.path, 1)
    }

    /// 用给定块型造基准布局，落盘并返回（供 `modelForTesting` 装载）。
    /// 块型为空（一个可用块都没有）或写盘失败时返回 nil，调用方提示后退出。
    static func writeSyntheticLayout(
        shapes: [PlacedBlock],
        template: LayoutModel,
        mode: Mode
    ) -> LayoutModel? {
        guard let model = makeSynthetic(shapes: shapes, template: template, mode: mode),
              let encoded = try? JSONEncoder().encode(model),
              (try? encoded.write(to: syntheticLayoutURL, options: .atomic)) != nil else {
            return nil
        }
        return model
    }

    /// 纯值转换（可测）：按模式把块型铺成页——`nCurve` 循环铺满递增块数的
    /// 六页，`uniform` 每个块型一页、页内全是同型块。
    static func makeSynthetic(
        shapes rawShapes: [PlacedBlock],
        template source: LayoutModel,
        mode: Mode
    ) -> LayoutModel? {
        var shapes: [PlacedBlock] = []
        for block in rawShapes
        where !shapes.contains(where: { $0.blockID == block.blockID && $0.pluginID == block.pluginID }) {
            shapes.append(block)
        }
        guard !shapes.isEmpty else { return nil }
        shapes.sort { $0.widthColumns * $0.heightRows > $1.widthColumns * $1.heightRows }

        var model = LayoutModel()
        model.maxColumns = source.maxColumns
        model.minRows = source.minRows
        model.minColumns = source.minColumns
        model.compactSlots = []
        model.enabledPluginIDs = source.enabledPluginIDs
        // 页 = (块型序列, 每页块数)：N 曲线是"全部块型循环"的递增页，
        // 同型对照是"每个块型铺满一页"。
        let pages: [(label: String, shapes: [PlacedBlock], count: Int)] = switch mode {
        case .nCurve:
            pageBlockCounts.enumerated().map { index, count in
                ("N=\(count)", shapes, count)
            }
        case .uniform:
            shapes.enumerated().map { index, shape in
                ("\(shape.pluginID)/\(shape.blockID)", [shape], uniformPageBlocks)
            }
        }
        model.drawerPages = Array(0..<pages.count)
        model.drawerPageTitles = Dictionary(
            uniqueKeysWithValues: pages.enumerated().map { (String($0.offset), $0.element.label) }
        )
        model.drawerBlocks = []
        for (page, spec) in pages.enumerated() {
            var column = 0
            var row = 0
            var rowHeight = 0
            for index in 0..<spec.count {
                let shape = spec.shapes[index % spec.shapes.count]
                if column > 0, column + shape.widthColumns > rowColumns {
                    row += rowHeight
                    column = 0
                    rowHeight = 0
                }
                model.drawerBlocks.append(PlacedBlock(
                    pluginID: shape.pluginID,
                    blockID: shape.blockID,
                    placementID: UUID().uuidString,
                    page: page,
                    originColumn: column,
                    originRow: row,
                    widthColumns: shape.widthColumns,
                    heightRows: shape.heightRows
                ))
                column += shape.widthColumns
                rowHeight = max(rowHeight, shape.heightRows)
            }
        }
        return model
    }
}
