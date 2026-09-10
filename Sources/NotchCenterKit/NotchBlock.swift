import CoreGraphics
import SwiftUI

// MARK: - 块种类与物理尺寸声明（文档 §4.2）

/// 块所属区域：紧凑区（刘海两侧，槽位数随图标动态伸缩）或抽屉区（展开网格）。
///
/// `.page` 是抽屉区的**独占变体**：它同样占格跨、同样吃 `sizeBox` 三档换算，
/// 但宿主保证同一抽屉页内只会有它一个块（见 Agent Note
/// 2026-09-10-plugin-page-blocks）。用枚举而不是布尔标志，是为了让
/// "紧凑 / 抽屉网格 / 独占整页"互斥关系由类型承担。
public enum BlockKind: Sendable, Hashable {
    case compact
    case drawer
    /// 整页块：独占一个抽屉页，同页不得再有任何其它块。
    case page
}

extension BlockKind {
    /// 是否落在抽屉网格里并吃像素三档 / 格跨换算（`.compact` 之外都吃）。
    /// 尺寸换算、渲染元素构建等"只关心有没有格跨"的站点用它，别写 `!= .compact`
    /// ——新种类落地时这里是要重新审的唯一一处。
    public var occupiesDrawerGrid: Bool { self != .compact }

    /// 是否独占整页（同页禁止共存、不可拖动、不参与重排与跨页搬移）。
    public var isExclusivePage: Bool { self == .page }
}

/// 紧凑块点击行为（文档 §4.2 / §6.2）：默认点击展开抽屉，`.custom` 由插件自行处理。
public enum BlockInteraction: Sendable, Hashable {
    case expandDrawer
    case custom
}

/// 任意网格跨度（列数 × 行数）。
public struct GridSpan: Hashable, Codable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

extension GridSpan {
    /// 网格的不可再分最小跨度：任何块至少占 1×1 格。物理下限由
    /// `NotchBlock.globalMinimumPixel`（75×60）表达——两者在最小格子
    /// （75×60）下恰好重合。
    public static let globalMinimum = GridSpan(columns: 1, rows: 1)

    public var columnRange: ClosedRange<Int> { 1...columns }
    public var rowRange: ClosedRange<Int> { 1...rows }

    /// 是否逐轴落在 `[min...max]` 矩形盒内。
    public func isWithin(min: GridSpan, max: GridSpan) -> Bool {
        (min.columns...max.columns).contains(columns)
            && (min.rows...max.rows).contains(rows)
    }
}

/// 插件提供的**物理像素**尺寸三档（点，与格子尺寸无关）。
///
/// 组件在网格里以整数格跨（列×行）渲染；宿主按**当前用户格子尺寸**把这三档
/// 换算成允许的格跨盒（`NotchBlock.sizeBox(metrics:)`），因此用户无论把格子调
/// 多大或多小，组件的真实物理尺寸都落在声明区间内（粒度取整误差除外）。
///
/// - 全局下限：最小/推荐/最大任一轴的像素不得小于
///   `NotchBlock.globalMinimumPixel`（75×60，恰等于一格的最小物理尺寸）。
public struct BlockPixelSize: Hashable, Codable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// 逐轴是否落在 `[min...max]` 矩形盒内（物理像素）。
    public func isWithin(min: BlockPixelSize, max: BlockPixelSize) -> Bool {
        (min.width...max.width).contains(width)
            && (min.height...max.height).contains(height)
    }
}

/// 打包期"最小尺寸遮挡校验"的自检探针：插件声明某关键 UI 区在给定布局下**必须
/// 完整可见**的矩形（块本地坐标，原点 = 内容区左上）。
///
/// 声明语义是**意图契约**而非渲染实测：探针须由与块视图同一套布局常量/辅助推导
/// （字体高度、行高、控件尺寸等），打包校验器以 `minSize` 作内容盒做纯几何比对——
/// 越出内容盒（内容会伸到邻居块，宿主卡片不裁切 → 块间遮挡源）或探针互叠（组件
/// 内部互相覆盖）即拦截。校验不渲染真实视图；字形级截断等矩形内部细节不在几何
/// 校验范围（作者选 minSize 时自担）。
public struct BlockProbe: Hashable, Sendable {
    /// 插件内唯一探针 ID（如 `"title"`、`"slider.rows"`），用于报错定位。
    public let id: String
    /// 关键 UI 区的必需可见矩形（块本地坐标）。
    public let rect: CGRect

    public init(id: String, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

/// 插件提供的最小 UI 单元（文档 §4.2）。
@MainActor
public struct NotchBlock: Identifiable {
    /// 插件内唯一块类型 ID（如 `"notes.notebook"`）。
    public let id: String
    /// 用户可见名称。
    public let displayName: String
    /// 块种类：紧凑块、抽屉网格块或独占整页块。
    public let kind: BlockKind
    /// 抽屉块的**物理像素**尺寸声明——最小/最大/推荐三档（点）。
    ///
    /// 组件按整数格跨渲染，宿主用当前格子尺寸把三档换算成允许格跨盒
    /// （`sizeBox(metrics:)`）：min 取上整（物理 ≥ 最小）、max 取下整（物理
    /// ≤ 最大）、recommended 就近取整并夹进盒内。用户改格子大小时换算随之
    /// 变化，组件物理尺寸始终尊重声明区间。
    /// 紧凑块固定 44×44，三档恒为 nil；`.drawer` 与 `.page` 都必须声明。
    public let minSize: BlockPixelSize?
    public let maxSize: BlockPixelSize?
    public let recommendedSize: BlockPixelSize?
    /// 紧凑块点击行为（仅紧凑块有意义）。默认 `.expandDrawer`。
    public let interaction: BlockInteraction
    /// 目录条目图标（SF Symbol 名称，可选）。宿主在"添加块"目录里渲染
    /// "图标 + 块名"；未声明时回退纯文本条目（向后兼容第三方插件）。
    public let symbolName: String?
    /// 视图工厂：携带 `BlockContext` 构建块视图。
    public let makeView: @MainActor (BlockContext) -> AnyView
    /// 放置实例级设置界面（可选）。编辑模式块齿轮触发时，宿主优先用它并以
    /// 完整 `BlockContext` 调用（含 placementID / placementStore / 插件级
    /// settingsContext）——同一块类型的多个放置实例可各自单独设置；nil 时
    /// 回退插件级 `NotchCenterPlugin.settingsView`（所有实例共享一份内容）。
    public let instanceSettingsView: (@MainActor (BlockContext) -> AnyView)?

    /// 打包期自检探针（可选，仅 `.drawer` 有意义）：给定布局，返回关键 UI 区的
    /// `BlockProbe` 矩形（见 `BlockProbe` 的声明语义）。打包校验（`verify-sizes`）
    /// 以 `minSize` 作内容盒对探针做几何校验，拦截"最小尺寸下会互遮/溢出"的布局。
    /// 官方 drawer 块必须声明（门禁强制）；compact 与未声明的第三方块跳过校验。
    /// **`.page` 豁免**：探针的"越界 = 会伸到邻居块"论证以"同页还有别的块"为前提，
    /// 整页独占没有这个前提；且整页自管滚动、`minSize` 只是拖拽下限而非运行时
    /// 保证，几何比对会给出假阳性。整页块声明了照常校验，但不强制。
    /// 注意：探针推导**只能依赖 `BlockLayoutInfo.frame`（像素）**，不得依赖
    /// `size/widthColumns/heightRows`（校验时网格上下文不存在，恒为 nil）。
    public let probes: (@MainActor (BlockLayoutInfo) -> [BlockProbe])?

    // MARK: 便捷访问

    /// 抽屉区块的物理像素三档；紧凑块恒 nil。`.drawer` 与 `.page` 共用。
    public var pixelBox: (min: BlockPixelSize, max: BlockPixelSize, recommended: BlockPixelSize)? {
        guard let minSize, let maxSize, let recommendedSize else { return nil }
        return (minSize, maxSize, recommendedSize)
    }

    // MARK: 物理像素 → 格跨换算（文档 §4.2，宿主唯一换算入口）

    /// 按当前格子指标，把像素三档换算成允许的**格跨盒**；紧凑块恒 nil。
    ///
    /// 每轴独立换算（格跨 ≥1）：
    /// - min → 使物理尺寸 ≥ 声明最小的最小格数（向上取整）；
    /// - max → 使物理尺寸 ≤ 声明最大的最大格数（向下取整，至少为 1 ——
    ///   格子被用户调得比声明还大时以 1×1 兜底）；
    /// - recommended → 最接近声明推荐的格数（就近取整），夹进 [min...max]。
    ///
    /// `cell` 传格子的**内容物理尺寸**（宽/高，不含间距）：组件像素声明指
    /// 的是内容区（格子之和），宿主渲染时块内自间距为视觉扩展、不参与换算。
    public func sizeBox(
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> (min: GridSpan, max: GridSpan, recommended: GridSpan)? {
        guard let pixelBox else { return nil }
        let columns = Self.axisSpan(
            minPixel: pixelBox.min.width,
            maxPixel: pixelBox.max.width,
            recommendedPixel: pixelBox.recommended.width,
            cell: cellWidth
        )
        let rows = Self.axisSpan(
            minPixel: pixelBox.min.height,
            maxPixel: pixelBox.max.height,
            recommendedPixel: pixelBox.recommended.height,
            cell: cellHeight
        )
        return (
            GridSpan(columns: columns.min, rows: rows.min),
            GridSpan(columns: columns.max, rows: rows.max),
            GridSpan(columns: columns.recommended, rows: rows.recommended)
        )
    }

    /// 单轴像素 → 格数换算（见 `sizeBox(cellWidth:cellHeight:)` 的语义）。
    static func axisSpan(
        minPixel: CGFloat,
        maxPixel: CGFloat,
        recommendedPixel: CGFloat,
        cell: CGFloat
    ) -> (min: Int, max: Int, recommended: Int) {
        let safeCell = max(cell, 1)
        let minAxis = max(1, Int(ceil(minPixel / safeCell)))
        let maxRaw = max(1, Int(floor(maxPixel / safeCell)))
        // 格子比声明区间还大（max 档取整得 0）时以最小格 1 兜底；min 恒 ≥1
        // 所以 min ≤ max 恒成立。
        let maxAxis = max(maxRaw, minAxis)
        let recommendedAxis = min(
            max(Int((recommendedPixel / safeCell).rounded()), minAxis),
            maxAxis
        )
        return (minAxis, maxAxis, recommendedAxis)
    }

    /// 给定格跨，其是否落在当前格子下换算出的允许盒内。
    /// 紧凑块恒 false。存量布局中"盒外"跨度照常显示，不视为损坏
    /// （首次拖拽时被钳进盒内）。
    public func allows(
        _ span: GridSpan,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> Bool {
        guard let box = sizeBox(cellWidth: cellWidth, cellHeight: cellHeight) else { return false }
        return span.isWithin(min: box.min, max: box.max)
    }

    /// 把跨度逐轴夹进当前格子下换算出的允许盒内（盒外目标的最小修复：直接钳制）。
    public func clamping(
        _ span: GridSpan,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> GridSpan {
        guard let box = sizeBox(cellWidth: cellWidth, cellHeight: cellHeight) else { return span }
        return GridSpan(
            columns: min(max(span.columns, box.min.columns), box.max.columns),
            rows: min(max(span.rows, box.min.rows), box.max.rows)
        )
    }

    // MARK: 初始化

    /// 紧凑块构造：固定 44×44，无需（也不得）声明抽屉三档。
    public init(
        id: String,
        displayName: String,
        kind: BlockKind,
        interaction: BlockInteraction = .expandDrawer,
        symbolName: String? = nil,
        instanceSettingsView: (@MainActor (BlockContext) -> AnyView)? = nil,
        probes: (@MainActor (BlockLayoutInfo) -> [BlockProbe])? = nil,
        makeView: @escaping @MainActor (BlockContext) -> AnyView
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.minSize = nil
        self.maxSize = nil
        self.recommendedSize = nil
        self.interaction = interaction
        self.symbolName = symbolName
        self.instanceSettingsView = instanceSettingsView
        self.probes = probes
        self.makeView = makeView
    }

    /// 抽屉块构造：声明 最小/最大/推荐 三档**物理像素**尺寸。
    ///
    /// `.drawer` 与 `.page` 共用本构造（整页块的像素三档语义与网格块一致，
    /// 只是它的列跨度会被宿主夹到 `[最小列数, 有效容量]` 之间以铺满内容区）。
    ///
    /// 声明必须满足：三档齐全、逐轴 `min ≤ recommended ≤ max`、min 不小于
    /// 全局下限 `globalMinimumPixel`（75×60）。违反时 `validationError` 非空，
    /// 宿主拒绝该块（运行期与打包期一致拦截）。
    public init(
        id: String,
        displayName: String,
        kind: BlockKind,
        minSize: BlockPixelSize,
        maxSize: BlockPixelSize,
        recommendedSize: BlockPixelSize,
        interaction: BlockInteraction = .expandDrawer,
        symbolName: String? = nil,
        instanceSettingsView: (@MainActor (BlockContext) -> AnyView)? = nil,
        probes: (@MainActor (BlockLayoutInfo) -> [BlockProbe])? = nil,
        makeView: @escaping @MainActor (BlockContext) -> AnyView
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.minSize = minSize
        self.maxSize = maxSize
        self.recommendedSize = recommendedSize
        self.interaction = interaction
        self.symbolName = symbolName
        self.instanceSettingsView = instanceSettingsView
        self.probes = probes
        self.makeView = makeView
    }

    /// 校验块声明是否满足架构文档 §4.2 的规则。
    /// - 紧凑块固定 44×44，不得声明抽屉三档；
    /// - `.drawer` / `.page` 必须三档齐全，且逐轴 `min ≤ recommended ≤ max`、
    ///   min 不小于全局像素下限 `globalMinimumPixel`（75×60）；
    /// - `.page` 不得声明 `interaction`（那是紧凑块专属语义，整页没有点击行为）。
    public var validationError: String? {
        switch kind {
        case .compact:
            if minSize != nil || maxSize != nil || recommendedSize != nil {
                return "compact block \(id) must not declare drawer sizes"
            }
            return nil
        case .drawer:
            return pixelBoxValidationError(label: "drawer")
        case .page:
            if let error = pixelBoxValidationError(label: "page") { return error }
            if interaction != .expandDrawer {
                return "page block \(id) must not declare interaction (compact-only)"
            }
            return nil
        }
    }

    /// 像素三档的逐轴校验（`.drawer` 与 `.page` 共用，`label` 只影响报错措辞）。
    private func pixelBoxValidationError(label: String) -> String? {
        guard let minSize, let maxSize, let recommendedSize else {
            return "\(label) block \(id) must declare minSize/maxSize/recommendedSize"
        }
        let floor = Self.globalMinimumPixel
        if minSize.width < floor.width || minSize.height < floor.height {
            return "\(label) block \(id) minSize must be at least \(Int(floor.width))×\(Int(floor.height)) pt (global minimum)"
        }
        if minSize.width > maxSize.width || minSize.height > maxSize.height {
            return "\(label) block \(id) minSize must not exceed maxSize"
        }
        if !recommendedSize.isWithin(min: minSize, max: maxSize) {
            return "\(label) block \(id) recommendedSize must lie within [minSize...maxSize]"
        }
        return nil
    }
}

// MARK: - 全局物理下限

extension NotchBlock {
    /// 组件物理尺寸的全局下限：75×60 点。恰等于一格的最小物理尺寸
    /// （宿主格子范围下限 75×60），保证任何合法组件至少能以 1×1 格呈现。
    public static let globalMinimumPixel = BlockPixelSize(width: 75, height: 60)
}
