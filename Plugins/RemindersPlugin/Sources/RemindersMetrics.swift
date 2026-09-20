import CoreGraphics
import NotchCenterKit
import SwiftUI

// MARK: - 三态版式（决策 D3：宽 × 高双轴断点）
//
// 参考截图是三张不同长宽比的玻璃卡，按长宽比而非"大中小"划分：
//   左卡 206×328（0.63 竖长）→ 窄态；中卡 368×290（1.27 横扁）→ 宽态；
//   右卡 406×435（0.93 近方）→ 大态。
// 单一轴排序会错位——左卡比中卡还高，按高度排它落不进最小心态。
// 宽态头部自 2026-09-20 起 footer 上移（决策 2026-09-20-reminders-wide-footer-to-top），
// 中卡的"计数沉底"不再复刻。
//
// **版式与探针同源**：块视图读 `RemindersLayout`，打包期探针也从同一个
// `layout(for:)` 推导。二者一旦各写一份，改版式就会静默让探针失真。

enum RemindersLayoutState: String, CaseIterable, Sendable {
    /// 宽 < 阈值：名称左 + 计数右，纯行列表，无分隔线。
    case narrow
    /// 宽 ≥ 阈值且高 < 阈值：顶部「徽章 + 大计数 + 名称」同行，其下纯行列表。
    case wide
    /// 宽高均 ≥ 阈值：头部「大计数在上 + 名称在下」，其下是从顶部起排、
    /// 带虚线分隔的行列表，右上角标放大并对齐内容盒。
    case large
}

/// 一次渲染所需的全部几何量。视图只读它，几何单测直接断言它。
struct RemindersLayout: Equatable, Sendable {
    let state: RemindersLayoutState
    let size: CGSize
    /// 顶部区带：窄态 = 名称 + 计数；宽态 = 徽章 + 计数 + 名称（同行）；
    /// 大态 = 大计数（上）+ 名称（下），区带底边挂头部线。
    let topBand: CGRect
    /// 行列表区带（块内滚动视口），三态底边都直达块底。
    let listBand: CGRect
    /// 顶部区带内容盒（去掉内边距、并让出角标占位后的实际可用矩形）。
    let topContentRect: CGRect
    let rowHeight: CGFloat
    /// 行内容左右缩进（行分隔线只画在缩进内，与截图一致）。
    let rowInset: CGFloat
    let checklistDiameter: CGFloat
    /// 勾选圈描边线宽（大态按复刻图收细到 1pt）。
    let checklistLineWidth: CGFloat
    let titleFontSize: CGFloat
    let countFontSize: CGFloat
    let nameFontSize: CGFloat
    /// 行间是否画发丝分隔线。窄态不画（截图里的左卡没有分隔线）。
    let showsRowDividers: Bool
    /// 行间分隔线是否走虚线。仅大态为真（复刻图：1pt、dash 2 / gap 1）。
    let rowDividerDashed: Bool
    /// 行间分隔线左端相对行内容左缘的额外缩进：对齐标题起点，避开勾选圈。
    let dividerLeadingInset: CGFloat
    /// 行内元素间距（勾选圈 ↔ 标题 ↔ 重复图标）。
    let rowSpacing: CGFloat
    /// 行尾重复图标字号。
    let repeatIconSize: CGFloat
    /// 顶部区带底边的头部线高度（0 = 不画）。仅大态画，宽度即内容盒全宽。
    let headerRuleHeight: CGFloat
    /// 块内悬浮角标（切换数据源）的直径与距块边缘距离。大态放大并对齐内容盒。
    let cornerControlDiameter: CGFloat
    let cornerControlInset: CGFloat

    /// 列表区带在给定高度下能完整容纳的行数（下限 1）。
    var visibleRowCount: Int {
        max(1, Int(listBand.height / rowHeight))
    }
}

enum RemindersMetrics {
    // MARK: 断点（取网格整数倍：300 = 2 格宽，360 = 3 格高）

    /// 宽态 / 大态的宽度门槛。
    static let wideWidthThreshold: CGFloat = 300
    /// 大态的高度门槛。**300 而不是 360**：格子 75×75 / 间距 12 时块高只取
    /// 162 / 249 / 336 / 423… 这些离散档，360 会把 4×4（336×336）永远锁在
    /// 宽态（计数沉底的版式）。300 落在 249 与 336 之间，4×2/4×3 仍走宽态。
    /// 详见决策记录 `2026-09-20-reminders-large-header` D1。
    static let tallHeightThreshold: CGFloat = 300

    // MARK: 内边距与区带内容高

    static let padding: CGFloat = NotchTokens.Space.cardPadding
    /// 大态内边距（16）：复刻图实测值；其余态沿用 10（截图左卡/中卡的量）。
    /// 两档并存，`padding` 因此按态取值。
    static let paddingLarge: CGFloat = 16

    /// 窄态顶部内容高（名称 + 计数同一行）。
    static let narrowHeaderContentHeight: CGFloat = 20
    /// 大态顶部内容高（大计数 31 + 名称 16 两行堆叠后行盒高 54）。
    static let largeHeaderContentHeight: CGFloat = 54
    /// 大态头部线：画在顶部区带底边，2pt。
    static let headerRuleHeight: CGFloat = 2
    /// 大态名称行盒底 → 头部线的间距。
    static let headerRuleGap: CGFloat = 10
    /// 宽态圆形徽章直径（同时也是它所在区带的内容高）。
    static let badgeDiameter: CGFloat = 28
    /// 宽态顶部内容高：徽章（⌀28）与「大计数 + 名称」同盒，取较大值（都是 28）。
    static let wideHeaderContentHeight: CGFloat = 28

    /// 区带高度 = 上下内边距 + 内容高。区带高度用这个而不是裸内容高——
    /// 探针拿区带矩形做越界/重叠判定，漏掉内边距会让判定与实际布局错位。
    /// 大态不走这里：它的区带底边是头部线，没有下内边距（见 `layout(for:)`）。
    private static func bandHeight(contentHeight: CGFloat, padding: CGFloat) -> CGFloat {
        contentHeight + padding * 2
    }

    // MARK: 行与字号

    static let rowHeightNarrow: CGFloat = 22
    static let rowHeightRegular: CGFloat = 25
    /// 大态行高（复刻图实测行节距 36.5）。
    static let rowHeightLarge: CGFloat = 36.5
    static let checklistDiameterNarrow: CGFloat = 14
    static let checklistDiameterRegular: CGFloat = 16
    /// 大态勾选圈（实测 ⌀16.5，描边 1pt）。
    static let checklistDiameterLarge: CGFloat = 16.5
    static let checklistLineWidthRegular: CGFloat = 1.2
    static let checklistLineWidthLarge: CGFloat = 1

    static let titleFontSizeNarrow: CGFloat = 11
    static let titleFontSizeRegular: CGFloat = 12
    /// 大态行标题（实测墨高 12 → 13.5pt 字）。
    static let titleFontSizeLarge: CGFloat = 13.5
    static let countFontSizeNarrowHeader: CGFloat = 15
    /// 宽态顶行大计数（footer 上移后沿用原底部 22pt）。
    static let countFontSizeWideHeader: CGFloat = 22
    /// 大态头部计数（实测墨高 22.5 → 31pt 字，比原 24 大一档）。
    static let countFontSizeLargeHeader: CGFloat = 31
    static let nameFontSizeNarrowHeader: CGFloat = 11
    static let nameFontSizeWideHeader: CGFloat = 12
    /// 大态头部清单名（实测墨高 14 → 16pt 字）。
    static let nameFontSizeLargeHeader: CGFloat = 16

    /// 行尾重复图标字号。
    static let repeatIconSize: CGFloat = 10
    /// 大态行尾重复图标（实测 11）。
    static let repeatIconSizeLarge: CGFloat = 11
    /// 行内元素间距（勾选圈 ↔ 标题 ↔ 重复图标）。
    static let rowSpacing: CGFloat = 8
    /// 大态行内元素间距（实测圈 → 标题 10.5）。
    static let rowSpacingLarge: CGFloat = 10.5

    // MARK: 角标、撤销条、节流

    /// 块内悬浮角标距块边缘的距离：与宿主编辑角标同一环（DESIGN.md §9）。
    static let cornerControlInset: CGFloat = 6
    static let cornerControlDiameter: CGFloat = 22
    /// 大态角标：放大并对齐内容盒（复刻图实测 ⌀34、距块边 16）。
    static let cornerControlInsetLarge: CGFloat = 16
    static let cornerControlDiameterLarge: CGFloat = 34
    /// 撤销条高度。
    static let undoBarHeight: CGFloat = 26
    /// 撤销条可见时长（决策 D10：起算点是"条目移出列表"的那一刻）。
    static let undoVisibleDuration: Duration = .milliseconds(2500)
    /// 外部变更（`EKEventStoreChanged`）重拉的节流窗（决策 D9）。
    static let externalRefreshThrottle: Duration = .milliseconds(300)

    // MARK: 版式推导

    static func state(for size: CGSize) -> RemindersLayoutState {
        guard size.width >= wideWidthThreshold else { return .narrow }
        return size.height >= tallHeightThreshold ? .large : .wide
    }

    /// 顶部区带内容在**尾部**需要让出的宽度：角标恒悬浮在右上角，不让出就会在
    /// 悬停瞬间盖住计数/清单名。窄态与宽态同款——宽态的计数/名称上移进顶行后
    /// 同样占顶行；大态角标放大且对齐内容盒，让位相应变大。
    static func topTrailingReserve(for state: RemindersLayoutState) -> CGFloat {
        switch state {
        case .narrow, .wide:
            return cornerControlInset + cornerControlDiameter + rowSpacing
        case .large:
            return paddingLarge + cornerControlDiameterLarge + rowSpacing
        }
    }

    /// 该态的内容内边距（大态 16，其余 10）。
    static func padding(for state: RemindersLayoutState) -> CGFloat {
        state == .large ? paddingLarge : padding
    }

    static func layout(for size: CGSize) -> RemindersLayout {
        let state = Self.state(for: size)
        let reserve = topTrailingReserve(for: state)
        let inset = padding(for: state)

        switch state {
        case .narrow:
            let topHeight = bandHeight(contentHeight: narrowHeaderContentHeight, padding: inset)
            let topBand = CGRect(x: 0, y: 0, width: size.width, height: topHeight)
            return RemindersLayout(
                state: .narrow,
                size: size,
                topBand: topBand,
                listBand: CGRect(
                    x: 0, y: topBand.maxY,
                    width: size.width, height: max(size.height - topHeight, 0)),
                topContentRect: contentRect(
                    in: topBand, padding: inset, contentHeight: narrowHeaderContentHeight,
                    trailingReserve: reserve),
                rowHeight: rowHeightNarrow,
                rowInset: inset,
                checklistDiameter: checklistDiameterNarrow,
                checklistLineWidth: checklistLineWidthRegular,
                titleFontSize: titleFontSizeNarrow,
                countFontSize: countFontSizeNarrowHeader,
                nameFontSize: nameFontSizeNarrowHeader,
                showsRowDividers: false,
                rowDividerDashed: false,
                dividerLeadingInset: 0,
                rowSpacing: rowSpacing,
                repeatIconSize: repeatIconSize,
                headerRuleHeight: 0,
                cornerControlDiameter: cornerControlDiameter,
                cornerControlInset: cornerControlInset)
        case .wide:
            // 顶行 = 徽章与「大计数 + 名称」同盒：内容高取二者较大值（都是 28），
            // 区带高 48 与 footer 上移前一致，列表因此净增一个旧 footer 区带高。
            let topHeight = bandHeight(contentHeight: wideHeaderContentHeight, padding: inset)
            let topBand = CGRect(x: 0, y: 0, width: size.width, height: topHeight)
            return RemindersLayout(
                state: .wide,
                size: size,
                topBand: topBand,
                listBand: CGRect(
                    x: 0, y: topBand.maxY,
                    width: size.width, height: max(size.height - topHeight, 0)),
                topContentRect: contentRect(
                    in: topBand, padding: inset, contentHeight: wideHeaderContentHeight,
                    trailingReserve: reserve),
                rowHeight: rowHeightRegular,
                rowInset: inset,
                checklistDiameter: checklistDiameterRegular,
                checklistLineWidth: checklistLineWidthRegular,
                titleFontSize: titleFontSizeRegular,
                countFontSize: countFontSizeWideHeader,
                nameFontSize: nameFontSizeWideHeader,
                showsRowDividers: true,
                rowDividerDashed: false,
                dividerLeadingInset: 0,
                rowSpacing: rowSpacing,
                repeatIconSize: repeatIconSize,
                headerRuleHeight: 0,
                cornerControlDiameter: cornerControlDiameter,
                cornerControlInset: cornerControlInset)
        case .large:
            // 区带 = 上内边距 + 内容（计数 31 + 名称 16 两行）+ 内容→头部线间距
            // + 头部线本身。头部线画在区带**底边**、其下再无下内边距：行列表紧贴其后
            // 起排，"从上到下排布"的留白全沉到块底（复刻图实测首行圆心距线 12）。
            let topHeight = inset + largeHeaderContentHeight + headerRuleGap + headerRuleHeight
            let topBand = CGRect(x: 0, y: 0, width: size.width, height: topHeight)
            return RemindersLayout(
                state: .large,
                size: size,
                topBand: topBand,
                listBand: CGRect(
                    x: 0, y: topBand.maxY,
                    width: size.width, height: max(size.height - topHeight, 0)),
                topContentRect: contentRect(
                    in: topBand, padding: inset, contentHeight: largeHeaderContentHeight,
                    trailingReserve: reserve),
                rowHeight: rowHeightLarge,
                rowInset: inset,
                checklistDiameter: checklistDiameterLarge,
                checklistLineWidth: checklistLineWidthLarge,
                titleFontSize: titleFontSizeLarge,
                countFontSize: countFontSizeLargeHeader,
                nameFontSize: nameFontSizeLargeHeader,
                showsRowDividers: true,
                rowDividerDashed: true,
                dividerLeadingInset: checklistDiameterLarge + rowSpacingLarge,
                rowSpacing: rowSpacingLarge,
                repeatIconSize: repeatIconSizeLarge,
                headerRuleHeight: headerRuleHeight,
                cornerControlDiameter: cornerControlDiameterLarge,
                cornerControlInset: cornerControlInsetLarge)
        }
    }

    /// 区带 → 内容盒：上下左右各让出 `padding`，尾部再让出角标占位。
    private static func contentRect(
        in band: CGRect,
        padding: CGFloat,
        contentHeight: CGFloat,
        trailingReserve: CGFloat
    ) -> CGRect {
        CGRect(
            x: band.minX + padding,
            y: band.minY + padding,
            width: max(band.width - padding - trailingReserve, 0),
            height: max(contentHeight, 0))
    }

    // MARK: 探针

    /// 打包期最小尺寸遮挡校验探针。三态各由同一份版式推导出各自的区带——
    /// 注意打包校验器**只用 `minSize` 跑一次**，`minSize`（150×150）恒落在窄态，
    /// 因此宽态/大态的这两组探针在门禁里永远不会被走到。它们是同一契约的另两个
    /// 分支，只能靠 `RemindersMetricsTests` 显式覆盖（见决策记录的 Consequences）。
    static func probes(for size: CGSize) -> [BlockProbe] {
        let layout = layout(for: size)
        return [
            BlockProbe(id: "reminders.\(layout.state.rawValue).top", rect: layout.topBand),
            BlockProbe(id: "reminders.\(layout.state.rawValue).list", rect: layout.listBand),
        ]
    }

    /// 块内悬浮角标（切换数据源）的矩形。**不单列 `BlockProbe`**：角标默认隐藏、
    /// 悬停才浮出，落位必然叠在顶部区带探针上，单列会被互不重叠判定判错
    /// （见 docs/agents/插件开发约定.md）。这里只用于单测核对它落在 `minSize`
    /// 内容盒内、且落在顶部区带探针内。
    static func cornerControlRect(in size: CGSize) -> CGRect {
        let state = Self.state(for: size)
        let inset = state == .large ? cornerControlInsetLarge : cornerControlInset
        let diameter = state == .large ? cornerControlDiameterLarge : cornerControlDiameter
        return CGRect(
            x: size.width - inset - diameter,
            y: inset,
            width: diameter,
            height: diameter)
    }

    /// 底部撤销条的矩形（纯叠加层，同样不单列探针）。
    static func undoBarRect(in size: CGSize) -> CGRect {
        CGRect(
            x: padding,
            y: max(size.height - padding - undoBarHeight, 0),
            width: max(size.width - padding * 2, 0),
            height: undoBarHeight)
    }
}
