import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 滚动裁切后的可见性

/// 行内元素（胶囊 / 加号）被顶栏滚动区裁切后的可见性——**命中门控**的依据。
/// `clipped()` 只裁绘制不裁命中，溢出段会盖在齿轮/钉住上把点击抢走。
enum DrawerCapsuleVisibility: Equatable {
    case full
    /// 只露出这一段：相对元素自身左缘的偏移与宽度。
    case partial(offset: CGFloat, width: CGFloat)
    case hidden
}

// MARK: - 纯几何：胶囊行槽位与拖动落点

/// 分页胶囊行的槽位数学（值类型、无视图依赖，可单测重放）。
/// 前提是胶囊**定宽等距**：槽位原点 = 槽位 × `step`，落点只需位移量、不必测 frame。
enum DrawerPagePillLayout {
    /// 定宽取"图标 + 标题"所需（符号 + 3~4 个汉字），超出截断；
    /// 槽位数学全部由本常量派生，改动会等比传导到高光/拖动落点。
    static let pillWidth: CGFloat = 52
    static let pillHeight: CGFloat = 22
    /// 每颗胶囊的命中/悬停框比胶囊高一档：顶角的设置/删除角标必须落在框内，
    /// 否则指针一移到角标上 `onHover` 就翻 false，角标当场消失、永远点不到。
    static let rowHeight: CGFloat = 28
    static let pillSpacing: CGFloat = 4
    /// 加号在胶囊外，不参与排序数学。
    static let addSpacing: CGFloat = 6
    /// 行首行尾加号的直径（隐藏时 opacity 0 仍占布局，行宽恒定）。
    static let addButtonDiameter: CGFloat = 20
    static let badgeSide: CGFloat = 12
    /// 按压位移超过该值才认定是拖动（否则视同点击切页）。
    static let dragPickupDistance: CGFloat = 4

    static var step: CGFloat { pillWidth + pillSpacing }

    /// 高亮层左缘：激活槽位 → 目标槽位的线性插值。跟手、落位 spring 与回弹共用同一份进度。
    static func highlightX(fromSlot: Int, toSlot: Int, progress: CGFloat) -> CGFloat {
        let p = min(max(progress, 0), 1)
        return (CGFloat(fromSlot) + (CGFloat(toSlot) - CGFloat(fromSlot)) * p) * step
    }

    static func targetIndex(draggedIndex: Int, translation: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let shifted = draggedIndex + Int((translation / step).rounded())
        return min(max(shifted, 0), count - 1)
    }

    /// 预览期某槽位的显示位置：被拖者留在原槽（基座钉死，跟手靠 offset），
    /// 其余在被跨越区间整体平移一位。必须与 `LayoutEngine.moveDrawerPage`
    ///（remove + insert）逐位同解，否则松手瞬间会看到一次回弹。
    static func displayIndex(slot: Int, draggedIndex: Int, targetIndex: Int) -> Int {
        if slot == draggedIndex { return draggedIndex }
        if draggedIndex < targetIndex, slot > draggedIndex, slot <= targetIndex {
            return slot - 1
        }
        if draggedIndex > targetIndex, slot >= targetIndex, slot < draggedIndex {
            return slot + 1
        }
        return slot
    }

    // MARK: 顶栏滚动区（偏移几何）

    /// 溢出侧渐隐遮罩宽度（纯视觉，不参与任何命中数学）。
    static let fadeWidth: CGFloat = 8
    /// 拖动期边缘自动滚的触发边带宽度（指针进带即滚，压入越深越快）。
    static let autoScrollEdge: CGFloat = 24
    /// 自动滚最大速率（pt/s，指针压到边带最外侧时）。
    static let autoScrollMaxSpeed: CGFloat = 420

    /// 滚动余量：行心相对区心的最大偏移（行放得下时为 0 = 不可滚）。偏移域
    /// 是**对称**的 `[-余量, +余量]`——`offset == 0` 恒等于"行心对齐区心"。
    static func scrollExtent(regionWidth: CGFloat, pageCount: Int) -> CGFloat {
        max(0, (rowWidth(pageCount: pageCount) - regionWidth) / 2)
    }

    /// 偏移夹紧到对称域。**渲染前必夹**：区域宽随面板/指标变化，存量偏移可能越界。
    static func clampedOffset(
        _ offset: CGFloat,
        regionWidth: CGFloat,
        pageCount: Int
    ) -> CGFloat {
        let extent = scrollExtent(regionWidth: regionWidth, pageCount: pageCount)
        return min(max(offset, -extent), extent)
    }

    /// 行左缘相对滚动区左缘的位置 = 居中位置 − 偏移。放得下时居中对齐、放不下
    /// 时两端对称裁切，同一套语义贯穿两档——面板宽度变化时行心钉在区心上，
    /// 整排胶囊不平移（旧"溢出即左对齐"把行左缘绑在随面板宽度移动的区左缘上，
    /// 切页/改格宽时胶囊会跟着平移 Δ/2）。
    static func rowLeftInRegion(
        regionWidth: CGFloat,
        pageCount: Int,
        offset: CGFloat
    ) -> CGFloat {
        (regionWidth - rowWidth(pageCount: pageCount)) / 2 - offset
    }

    /// 单颗胶囊在行坐标系里的横向区间（加号在槽位数学外，单独给）。
    static func pillRange(slot: Int) -> ClosedRange<CGFloat> {
        let left = addButtonDiameter + addSpacing + CGFloat(slot) * step
        return left...(left + pillWidth)
    }

    /// 行首加号 / 行尾加号在行坐标系里的横向区间。
    static var leadingAddRange: ClosedRange<CGFloat> { 0...addButtonDiameter }

    static func trailingAddRange(pageCount: Int) -> ClosedRange<CGFloat> {
        let right = rowWidth(pageCount: pageCount)
        return (right - addButtonDiameter)...right
    }

    /// 滚动区映射到行坐标系的可见窗口（宽恒 = 区宽，中心恒 = 行心 − 偏移）。
    static func visibleRange(
        regionWidth: CGFloat,
        pageCount: Int,
        offset: CGFloat
    ) -> ClosedRange<CGFloat> {
        let pad = (regionWidth - rowWidth(pageCount: pageCount)) / 2
        return (offset - pad)...(offset + regionWidth - pad)
    }

    /// 行内区间被滚动区裁切后露出的那一段（已换算成相对区间起点的横段）；
    /// nil = 完全在视野外。
    static func visibleSpan(
        of range: ClosedRange<CGFloat>,
        regionWidth: CGFloat,
        pageCount: Int,
        offset: CGFloat
    ) -> (offset: CGFloat, width: CGFloat)? {
        let window = visibleRange(regionWidth: regionWidth, pageCount: pageCount, offset: offset)
        let lower = max(range.lowerBound, window.lowerBound)
        let upper = min(range.upperBound, window.upperBound)
        guard upper > lower else { return nil }
        return (lower - range.lowerBound, upper - lower)
    }

    /// 行内区间的可见性（命中门控用）：完全在视野内、只露一段、完全在视野外。
    /// `regionWidth <= 0`（宽度还没量到）视为不裁。
    static func visibility(
        of range: ClosedRange<CGFloat>,
        regionWidth: CGFloat,
        pageCount: Int,
        offset: CGFloat
    ) -> DrawerCapsuleVisibility {
        guard regionWidth > 0 else { return .full }
        guard let span = visibleSpan(
            of: range,
            regionWidth: regionWidth,
            pageCount: pageCount,
            offset: offset
        ) else { return .hidden }
        let width = range.upperBound - range.lowerBound
        guard span.width < width - 0.5 else { return .full }
        return .partial(offset: span.offset, width: span.width)
    }

    /// 让给定槽位**全部完整可见**所需的最小偏移调整（并集在区内装不下时退化
    /// 为只保证最后一个——滑动切页里目标页比起点重要）。传当前值即"就近夹紧"，
    /// 传会话起点的冻结基座即"从基座插值"；槽位已可见时原样返回。
    static func offsetRevealing(
        slots: [Int],
        offset: CGFloat,
        regionWidth: CGFloat,
        pageCount: Int
    ) -> CGFloat {
        guard pageCount > 0, !slots.isEmpty else {
            return clampedOffset(offset, regionWidth: regionWidth, pageCount: pageCount)
        }
        let clamped = slots.map { min(max($0, 0), pageCount - 1) }
        let ranges = clamped.map(pillRange(slot:))
        let needLeft = ranges.map(\.lowerBound).min() ?? 0
        let needRight = ranges.map(\.upperBound).max() ?? 0
        guard needRight - needLeft <= regionWidth else {
            return offsetRevealing(
                slot: clamped[clamped.count - 1],
                offset: offset,
                regionWidth: regionWidth,
                pageCount: pageCount
            )
        }
        // 可见窗口 = [offset + pad, offset + 区宽 + pad]（pad = 居中余量，负数即
        // 溢出），要让 [needLeft, needRight] 整个落进去：偏移落在下面这个区间里。
        let pad = (regionWidth - rowWidth(pageCount: pageCount)) / 2
        let lower = needRight - regionWidth + pad
        let upper = needLeft + pad
        return clampedOffset(min(max(offset, lower), upper), regionWidth: regionWidth, pageCount: pageCount)
    }

    static func offsetRevealing(
        slot: Int,
        offset: CGFloat,
        regionWidth: CGFloat,
        pageCount: Int
    ) -> CGFloat {
        offsetRevealing(
            slots: [slot],
            offset: offset,
            regionWidth: regionWidth,
            pageCount: pageCount
        )
    }

    /// 拖动期边缘自动滚的带符号速率（pt/s，偏移增量口径：正 = 行左移、露出
    /// 右侧内容）。只在两侧边带内非零，压入越深越快。
    static func autoScrollVelocity(
        pointerX: CGFloat,
        regionLeft: CGFloat,
        regionWidth: CGFloat
    ) -> CGFloat {
        guard regionWidth > 0 else { return 0 }
        let intoLeading = regionLeft + autoScrollEdge - pointerX
        let intoTrailing = pointerX - (regionLeft + regionWidth - autoScrollEdge)
        if intoLeading > 0, intoLeading >= intoTrailing {
            return -autoScrollMaxSpeed * min(intoLeading / autoScrollEdge, 1)
        }
        if intoTrailing > 0 {
            return autoScrollMaxSpeed * min(intoTrailing / autoScrollEdge, 1)
        }
        return 0
    }

    // MARK: 胶囊行命中（设置面板拖拽的驻留切页）

    /// 胶囊行内容总宽（含两端加号）。加号常驻占位（隐藏只是 opacity 0），
    /// 行宽与加号显隐无关，命中数学因此恒定。
    static func rowWidth(pageCount: Int) -> CGFloat {
        guard pageCount > 0 else { return 0 }
        return 2 * (addButtonDiameter + addSpacing)
            + CGFloat(pageCount) * pillWidth
            + CGFloat(pageCount - 1) * pillSpacing
    }

    /// 胶囊行中心相对顶栏中线的水平偏移。顶栏两侧 Spacer 均分剩余空间，
    /// 行心 = 中线 + 左右按钮组宽度差的一半：非编辑左齿轮 = 右钉住（24）
    /// 偏移 0；编辑模式左侧多一颗"一键重排"（24pt 按钮 + 8pt HStack 间距）
    /// 行心右移 16pt。与 `DrawerPanelView.topBar` 的布局常量同源，改动须同步。
    static func rowCenterOffset(isEditing: Bool) -> CGFloat {
        isEditing ? (24 + 8 + 24 - 24) / 2 : 0
    }

    /// 屏幕 x → 胶囊槽位（就近取槽）：`rowLeft` 为胶囊行左缘。加号区与
    /// 胶囊间隙一并计入就近范围（驻留目标是"大致指到某颗胶囊"，命中面
    /// 宜宽）；行范围外只让出半个间隙（再远返回 nil），行内的超界取整
    /// 由两端夹紧兜回（尾部加号区就近归末颗胶囊）。
    static func hoveredSlot(x: CGFloat, rowLeft: CGFloat, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let halfGap = pillSpacing / 2
        guard x >= rowLeft - halfGap, x <= rowLeft + rowWidth(pageCount: pageCount) + halfGap else {
            return nil
        }
        let raw = (x - rowLeft - (addButtonDiameter + addSpacing)) / step
        return min(max(Int(raw.rounded()), 0), pageCount - 1)
    }
}

// MARK: - 外观常量：胶囊底衬与悬浮高光

/// 胶囊与高光的全部视觉常量（与 `DrawerPagePillLayout` 分离：调视觉不碰几何）。
enum DrawerPagePillAppearance {
    /// 胶囊底衬只有「本身 × 悬停」两档——选中态归常驻高光层。
    static let hovering: Double = 0.10
    static let normal: Double = 0.055
    /// 底衬描边单档（悬停不加重）。
    static let strokeOpacity: Double = 0.06
    /// 悬浮高光比底衬明显更实：填充盖住底下底衬（跨界时明暗变化被自身亮度吞掉）、
    /// 投影把它从底衬平面抬起——缺了就是"同平面第二颗胶囊"，观感发闷。
    static let highlightFillOpacity: Double = 0.24
    static let highlightStrokeOpacity: Double = 0.24
    static let highlightShadowOpacity: Double = 0.30
    static let highlightShadowRadius: CGFloat = 5
    static let highlightShadowY: CGFloat = 2
}

// MARK: - 抽屉分页胶囊行（顶栏中间）

/// 每页一颗独立胶囊 + 行首行尾两颗**胶囊外**的加号。胶囊内容：图标 + 标题
///（无图标退化为标题/序号，主页默认房子）。点击与拖动共用一条按压手势
///（非编辑模式只认点击）；编辑模式悬停出设置/删除角标、横向拖动排序。
/// 选中态由常驻高光层表示：静止钉在激活胶囊、滑动会话期随 `swipe.progress` 平移。
struct DrawerPageCapsule: View {
    let pages: [Int]
    let titles: [String: String]
    let icons: [String: String]
    let activePage: Int
    let isEditing: Bool
    /// 两颗加号的显隐（编辑模式且指针悬停在顶栏上）。
    let showsAddButtons: Bool
    /// 滑动切页会话（nil = 静止）。
    let swipe: PanelUIState.DrawerSwipe?
    /// 顶栏中间**滚动区**的尺寸（视图实测下发）：行在区内的定位、裁切与逐元素
    /// 可见性命中门控全由它派生（几何唯一真源在 `DrawerPagePillLayout`）。
    let regionSize: CGSize
    /// 行在滚动区内的滚动偏移（对称域 `±(行宽 − 区宽)/2`，`0` = 行心对齐区心；
    /// 控制器写、渲染前夹紧）。
    let scrollOffset: CGFloat
    let onSelect: (Int) -> Void
    let onAdd: (DrawerPageSide) -> Void
    let onMove: (Int, Int) -> Void
    let onShowSettings: (Int, CGRect) -> Void
    /// 删除请求（带胶囊全局 frame：非空页需二次确认，确认浮窗锚定在该 frame）。
    let onRemove: (Int, CGRect) -> Void
    /// 胶囊拖动回调（聚合至滑动让路）。
    var onDraggingChanged: (Bool) -> Void = { _ in }
    /// 拖动中的指针屏幕坐标（nil = 拖动结束）：控制器据此驱动滚动区边缘自动滚。
    var onDragPointer: (CGPoint?) -> Void = { _ in }

    /// 编辑拖动排序预览：被拖页 + 目标槽位，两者同设同清。
    private struct DragPreview {
        let page: Int
        let target: Int
    }
    @State private var dragPreview: DragPreview?
    /// 被拖胶囊跟手位移的逐帧镜像（经 `onDragOffsetChanged` 上报）：激活页
    /// 被拖时高光要随之跟手，而位移是胶囊内部状态，父级只能镜像。
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        rowBody
            .offset(
                x: DrawerPagePillLayout.rowLeftInRegion(
                    regionWidth: regionSize.width,
                    pageCount: pages.count,
                    offset: renderedOffset
                ),
                // 行在滚动区里垂直居中：区高 = 顶栏高、比胶囊行高一档，拖动
                // 拾取（放大 + 投影）才有溢出余地不被裁掉。
                y: (regionSize.height - DrawerPagePillLayout.rowHeight) / 2
            )
            .frame(
                width: regionSize.width,
                height: regionSize.height,
                alignment: .topLeading
            )
            // 行比滚动区宽时只露区内那一段（两侧按钮组因此永远压不到）。
            .clipped()
            // 有隐藏内容的一侧渐隐，提示"还能滚"；滚到端点即消失。
            .mask(edgeFade)
    }

    /// 行本体：宽度 = `rowWidth`（不受滚动区约束），定位与裁切在外层。
    private var rowBody: some View {
        HStack(spacing: DrawerPagePillLayout.addSpacing) {
            addButton(.left)
            ZStack(alignment: .topLeading) {
                PagePillHighlight(x: highlightX, animationKey: highlightKey)
                HStack(spacing: DrawerPagePillLayout.pillSpacing) {
                    ForEach(Array(pages.enumerated()), id: \.element) { slot, page in
                        pill(page: page, slot: slot)
                    }
                }
                .animation(nil, value: pages)
            }
            .animation(nil, value: pages)
            addButton(.right)
        }
        .frame(height: DrawerPagePillLayout.rowHeight)
        // 行上不得挂 `.animation(value:)`：任何行级动画都会把被拖胶囊的跟手
        // 位移与高光的会话进度一起 spring 化（胶囊"追赶光标"）。让位动画挂在
        // 各胶囊自己的 `shift` 上，高光落位由控制器那条 spring 驱动。
    }

    /// 渲染用的偏移：**渲染前夹紧**——区域宽与页数都会变，存量偏移可能越界，
    /// 视图自身自洽就不必指望每个写入口都夹准。
    private var renderedOffset: CGFloat {
        DrawerPagePillLayout.clampedOffset(
            scrollOffset,
            regionWidth: regionSize.width,
            pageCount: pages.count
        )
    }

    /// 两端渐隐（仅视觉）：只在确实还有隐藏内容的一侧出现。偏移域对称，
    /// 两端各有余量时两侧同时渐隐（行比区宽的那一档常态如此）。
    private var edgeFade: some View {
        let extent = DrawerPagePillLayout.scrollExtent(
            regionWidth: regionSize.width,
            pageCount: pages.count
        )
        return HStack(spacing: 0) {
            if renderedOffset > -extent + 0.5 {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: DrawerPagePillLayout.fadeWidth)
            }
            Rectangle().fill(.black)
            if renderedOffset < extent - 0.5 {
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: DrawerPagePillLayout.fadeWidth)
            }
        }
    }

    // MARK: 槽位与高光几何（胶囊让位与高光层的唯一数学）

    /// 槽位在拖动预览期的显示槽位（无拖动 = 原槽）。
    private func displayedSlot(_ slot: Int) -> Int {
        guard let preview = dragPreview,
              let draggedIndex = pages.firstIndex(of: preview.page) else { return slot }
        return DrawerPagePillLayout.displayIndex(
            slot: slot,
            draggedIndex: draggedIndex,
            targetIndex: preview.target
        )
    }

    private var activeSlot: Int { pages.firstIndex(of: activePage) ?? 0 }

    /// 高光左缘：会话期按进度在激活/目标槽位间插值；静止钉在激活页的显示槽位，
    /// 激活页被拖时叠加跟手位移（基座钉原槽、位移一致，高光贴住被拖胶囊）。
    private var highlightX: CGFloat {
        if let swipe {
            let toSlot = LayoutModel.neighborPage(in: pages, active: activePage, side: swipe.side)
                .flatMap { pages.firstIndex(of: $0) } ?? activeSlot
            return DrawerPagePillLayout.highlightX(
                fromSlot: activeSlot,
                toSlot: toSlot,
                progress: swipe.progress
            )
        }
        let base = CGFloat(displayedSlot(activeSlot)) * DrawerPagePillLayout.step
        return dragPreview?.page == activePage ? base + dragOffset : base
    }

    /// 高光自身 spring 的触发键（离散槽位，不是连续位移）：编辑排序期随显示槽位
    /// 换档、与胶囊 `shift` 同帧同曲线；会话期恒 -1 不触发——位置由进度派生、
    /// 逐帧直渲，落位/回弹由控制器那条 spring 驱动（跟手不加动画）。会话起止帧
    /// key 跨越 -1 时 x 不变（进度 = 0 / 已落位），无可见动画。
    private var highlightKey: Int {
        swipe == nil ? displayedSlot(activeSlot) : -1
    }

    // MARK: 胶囊

    private func pill(page: Int, slot: Int) -> some View {
        DrawerPagePill(
            page: page,
            slot: slot,
            count: pages.count,
            label: label(for: page, slot: slot),
            icon: LayoutModel.pageIcon(page: page, icons: icons),
            help: LayoutModel.pageDisplayName(in: pages, page: page, titles: titles),
            // 胶囊壳不承载选中态；内容亮度随激活/进度变化，作高光层的"内的呼应"。
            contentActivation: activationWeight(page: page),
            isEditing: isEditing,
            isSwipeActive: swipe != nil,
            shift: displayedSlot(slot) - slot,
            visibility: pillVisibility(slot: slot),
            scrollOffset: renderedOffset,
            onSelect: { onSelect(page) },
            onDragTargetChanged: { dragPreview = DragPreview(page: page, target: $0) },
            onDragOffsetChanged: { dragOffset = $0 },
            onDragCommit: { target in
                // 提交后与预览同帧瞬移：基座 pages 重排与 shift 清零都不加动画，避免与 shift 预览的 spring 叠加成二次排序交换动画
                onMove(page, target)
                dragPreview = nil
                dragOffset = 0
            },
            onDraggingChanged: { isDragging in
                onDraggingChanged(isDragging)
                if !isDragging { onDragPointer(nil) }
            },
            onDragPointerChanged: { onDragPointer($0) },
            onShowSettings: { onShowSettings(page, $0) },
            onRemove: { onRemove(page, $0) }
        )
    }

    /// 该槽位胶囊被滚动区裁切后的可见性（命中门控用）。按**显示槽位**算：
    /// 拖动让位预览期其余胶囊整体平移一位，门控必须跟着它们当前画在哪。
    private func pillVisibility(slot: Int) -> DrawerCapsuleVisibility {
        DrawerPagePillLayout.visibility(
            of: DrawerPagePillLayout.pillRange(slot: displayedSlot(slot)),
            regionWidth: regionSize.width,
            pageCount: pages.count,
            offset: renderedOffset
        )
    }

    /// 内容激活程度（0…1），与 `swipe.progress` 同源：会话期激活页按 (1 − p)
    /// 渐暗、目标页按 p 渐亮、其余恒 0；无会话激活页 1、其余 0。直渲不加动画。
    private func activationWeight(page: Int) -> CGFloat {
        guard let swipe else { return page == activePage ? 1 : 0 }
        if page == activePage { return 1 - swipe.progress }
        if swipe.targetPage == page { return swipe.progress }
        return 0
    }

    /// 胶囊文字：自定义标题 → 序号；主页无标题时留空（画房子图标）。
    private func label(for page: Int, slot: Int) -> String {
        if let title = titles[String(page)], !title.isEmpty { return title }
        return page == LayoutModel.homePage ? "" : String(slot + 1)
    }

    // MARK: 加号（胶囊外）

    /// 隐藏时保留槽位（胶囊行不位移）且不吞点击；封顶后同样隐形。
    /// 被滚动区裁切时（行溢出且加号骑在区边缘上）**只有完整露出才可点**——
    /// 半截加号既瞄不准，露出的圆角也会盖到齿轮/钉住的命中框上（`IconCircleButton`
    /// 是 `Button`，命中形状在它内部定死，外层 `contentShape` 管不住）。
    private func addButton(_ side: DrawerPageSide) -> some View {
        let isVisible = showsAddButtons && pages.count < LayoutModel.maxDrawerPageCount
        let visibility = DrawerPagePillLayout.visibility(
            of: side == .left
                ? DrawerPagePillLayout.leadingAddRange
                : DrawerPagePillLayout.trailingAddRange(pageCount: pages.count),
            regionWidth: regionSize.width,
            pageCount: pages.count,
            offset: renderedOffset
        )
        let help = side == .left
            ? L("panel.help.page.addLeft")
            : L("panel.help.page.addRight")
        return IconCircleButton(
            systemImage: "plus",
            helpText: help,
            diameter: DrawerPagePillLayout.addButtonDiameter,
            action: { onAdd(side) }
        )
        .accessibilityLabel(help)
        .opacity(isVisible && visibility != .hidden ? 1 : 0)
        .allowsHitTesting(isVisible && visibility == .full)
        // 动画只挂加号自身（行上禁挂，见 body）；`visibility` 刻意不挂动画
        // ——它随滚动逐帧变，任何挂它的动画都会在滚动帧里给加号引入滞后。
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

// MARK: - 常驻悬浮高光（选中态的唯一表示）

/// 行内常驻的白色悬浮胶囊：从不消失、从不淡出。位置与动画键由
/// `DrawerPageCapsule` 统一计算，这里只管画。
/// ⚠️ 必须 `.offset` 定位、不能用 `.position`：`.position` 的布局尺寸恒等于
/// 父容器提案，会把 ZStack 撑满整行，`.topLeading` 对齐把胶囊钉到行首。
private struct PagePillHighlight: View {
    let x: CGFloat
    let animationKey: Int

    var body: some View {
        Capsule(style: .continuous)
            .fill(.white.opacity(DrawerPagePillAppearance.highlightFillOpacity))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        .white.opacity(DrawerPagePillAppearance.highlightStrokeOpacity),
                        lineWidth: 1
                    )
            }
            .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.pillHeight)
            .shadow(
                color: .black.opacity(DrawerPagePillAppearance.highlightShadowOpacity),
                radius: DrawerPagePillAppearance.highlightShadowRadius,
                y: DrawerPagePillAppearance.highlightShadowY
            )
            .offset(x: x, y: (DrawerPagePillLayout.rowHeight - DrawerPagePillLayout.pillHeight) / 2)
            .animation(DrawerAnimation.spring, value: animationKey)
            .allowsHitTesting(false)
    }
}

// MARK: - 单颗页面胶囊

/// 独立结构体而非视图方法：悬停与拖动都要持 `@State`。
private struct DrawerPagePill: View {
    let page: Int
    let slot: Int
    let count: Int
    /// 胶囊文字（空串 = 主页无标题，图标兜底画房子）。
    let label: String
    /// 胶囊图标（nil = 无图标，纯文本）。
    let icon: String?
    let help: String
    /// 内容激活程度（0…1）：决定图标/文本亮度，随滑动进度直渲。
    let contentActivation: CGFloat
    let isEditing: Bool
    /// 滑动中暂停排序。
    var isSwipeActive: Bool = false
    /// 让位预览的槽位偏移（被拖者恒 0——它跟手靠 `dragOffset`）。
    let shift: Int
    /// 被滚动区裁切后的可见性：完全在视野外不接事件，只露一段时把命中面
    /// 也裁到那一段（`clipped()` 不裁命中，见 `PillHitSpan`）。
    let visibility: DrawerCapsuleVisibility
    /// 行的滚动偏移（拖动跟手补偿用）。
    let scrollOffset: CGFloat
    let onSelect: () -> Void
    let onDragTargetChanged: (Int) -> Void
    /// 跟手位移逐帧上报（**没有** target 越界也要报）：高光在激活页被拖时要随胶囊跟手。
    let onDragOffsetChanged: (CGFloat) -> Void
    let onDragCommit: (Int) -> Void
    var onDraggingChanged: (Bool) -> Void = { _ in }
    /// 拖动中的指针屏幕坐标（喂滚动区边缘自动滚；手势坐标只有局部意义）。
    var onDragPointerChanged: (CGPoint) -> Void = { _ in }
    /// 设置角标触发：上报胶囊全局 frame 作为浮窗锚点。
    let onShowSettings: (CGRect) -> Void
    /// 删除请求（带胶囊全局 frame：确认浮窗锚定于此）。
    let onRemove: (CGRect) -> Void

    @State private var isHovering = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// 拾取那一刻的行偏移：拖动期行被自动滚推动时，被拖胶囊要同帧把这笔增量
    /// 补回跟手位移，否则行一滚胶囊就与光标脱手。
    @State private var pickupScrollOffset: CGFloat = 0
    /// 只在目标槽位真的变了时才上报：逐帧写 @State 会让让位动画每次都被重启。
    @State private var reportedTarget: Int?
    @State private var globalFrame: CGRect = .zero

    private var isHome: Bool { page == LayoutModel.homePage }
    private var isFullyVisible: Bool { visibility == .full }

    /// 行内跟手位移：指针位移 + 拾取后行自身的滚动增量。补偿写进**同一帧的
    /// 布局表达式**（不做 onChange 回写——回写晚一帧就是可见的脱手滞后）。
    private var effectiveDragOffset: CGFloat {
        guard isDragging else { return 0 }
        return dragOffset + (scrollOffset - pickupScrollOffset)
    }

    /// 图标/标题随激活度提亮的统一透明度（与旧纯文本档位一致）。
    private var contentOpacity: Double {
        icon == nil ? 0.5 + 0.45 * Double(contentActivation)
                    : 0.45 + 0.5 * Double(contentActivation)
    }

    var body: some View {
        pressSurface
            .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.rowHeight)
            // 锚定矩形捕获（量逻辑位置，与抽屉块齿轮同一模式）：设置角标点击时
            // 上报给页面设置浮窗。
            .background {
                GlobalFrameReader { globalFrame = $0 }
            }
            .overlay(alignment: .top) { badgeCluster }
            // 拾取弹簧（scale/shadow）必须排在位移层**前**：isDragging 翻转那帧
            // dragOffset 首次出现的跳变若被同一 spring 化，胶囊滞后于光标、与直渲
            // 的高光错位。跟手位移（dragOffset）直渲，只有让位（shift）走 spring。
            .scaleEffect(isDragging ? 1.06 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.45 : 0), radius: 6, y: 2)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(DrawerAnimation.spring, value: isDragging)
            .offset(x: CGFloat(shift) * DrawerPagePillLayout.step + effectiveDragOffset)
            .animation(DrawerAnimation.spring, value: shift)
            .onHover { isHovering = $0 }
            // 完全在滚动区外：整颗（含角标 overlay）不接事件。
            .allowsHitTesting(visibility != .hidden)
    }

    /// 按压面：**不能是 `Button`**——按钮在 AppKit 层接管按下，鼠标拖动的中间
    /// 事件直到松手才回流给祖先手势（整行只在松开一瞬才动）。点击与拖动都由
    /// `pressGesture` 一条手势分类（与 Kit `blockPopoverTrigger` 同一结论）。
    /// 手势挂这一层：落在角标上的按下归更晚 overlay 上的角标按钮。
    private var pressSurface: some View {
        content
            .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.pillHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(isHovering
                        ? DrawerPagePillAppearance.hovering
                        : DrawerPagePillAppearance.normal))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        .white.opacity(DrawerPagePillAppearance.strokeOpacity),
                        lineWidth: 1
                    )
            )
            .frame(height: DrawerPagePillLayout.rowHeight)
            .contentShape(hitShape)
            .pointingHandCursor()
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .gesture(pressGesture)
    }

    /// 命中形状：只露一段时按露出的横段裁（滚动区外的部分压在齿轮/钉住上，
    /// 不裁就会把它们点击抢走）。
    private var hitShape: PillHitSpan {
        guard case let .partial(offset, width) = visibility else {
            return PillHitSpan(x: 0, width: DrawerPagePillLayout.pillWidth)
        }
        return PillHitSpan(x: offset, width: width)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let icon {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(NotchTokens.Text.system(10, weight: .semibold))
                    if !label.isEmpty {
                        Text(label)
                            .font(NotchTokens.Text.system(10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else {
                Text(label)
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
            }
        }
        .foregroundStyle(.white.opacity(contentOpacity))
        // 排序提交后的序号重排走淡入淡出（label 只在提交变，不波及滑动期直渲）。
        .id(label)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: label)
    }

    // MARK: 编辑模式角标（齿轮打开页面设置浮窗 / 删除页面）

    /// 顶角两条角标，落在胶囊命中框内（见 `rowHeight`）。主页不给删除。
    /// **只给完整露出的胶囊**：角标是 `Button`（命中形状在内部定死，外层
    /// `contentShape` 管不住），半截胶囊的角标会悬在滚动区外抢两侧按钮的点击。
    @ViewBuilder
    private var badgeCluster: some View {
        if isEditing && isHovering && isFullyVisible {
            HStack(spacing: 0) {
                EditGlyphButton(
                    systemImage: "gearshape.fill",
                    helpText: L("panel.help.page.settings"),
                    side: DrawerPagePillLayout.badgeSide
                ) {
                    onShowSettings(globalFrame)
                }
                Spacer(minLength: 0)
                if !isHome {
                    EditGlyphButton(
                        systemImage: "xmark.circle.fill",
                        helpText: L("panel.help.page.delete"),
                        side: DrawerPagePillLayout.badgeSide,
                        action: { onRemove(globalFrame) }
                    )
                }
            }
            .frame(width: DrawerPagePillLayout.pillWidth, height: DrawerPagePillLayout.badgeSide)
        }
    }

    // MARK: 按压：点击切页 / 拖动排序

    /// 一条手势管两种意图（`minimumDistance: 0` 从按下那刻起持续收事件）：
    /// 横向位移越阈 = 拖动（逐帧跟手 + 让位预览，松手提交）；未越阈 = 点击切页
    ///（编辑期也靠胶囊切页，不能只剩拖动）。
    private var pressGesture: some Gesture {
        // 平移量必须在稳定坐标系度量：默认 `.local` 挂在胶囊自己身上，胶囊被
        // `.offset` 推动后下一帧 translation 被这份位移扣掉，形成"前跳一步 /
        // 后退半格"的锯齿（不跟手 + 闪烁）。`.global` 即宿主窗口坐标，拖动期间不动。
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // 滑动进行中不接管胶囊拖动：条带位移由控制器独占，胶囊让位预览
                // 若同时跟手会与高光进度抢同一份水平位移。**点击不受此限**——
                // 会话期点击由控制器即时打断在飞弹簧并跳页（2026-09-13 起不再
                // 在这里丢弃，见 onEnded）。
                guard !isSwipeActive else { return }
                if !isDragging {
                    guard isEditing,
                          abs(value.translation.width) > DrawerPagePillLayout.dragPickupDistance else { return }
                    isDragging = true
                    reportedTarget = nil
                    pickupScrollOffset = scrollOffset
                    onDraggingChanged(true)
                }
                dragOffset = value.translation.width
                // 逐帧上报（与 target 上报解耦）：位移供高光跟随，越界才换槽。
                // 上报的是**行内**位移（含滚动补偿），高光与它同坐标系。
                onDragOffsetChanged(effectiveDragOffset)
                // 拖动期指针位置喂滚动区边缘自动滚：手势坐标只有局部意义，
                // 一律用全局鼠标位置（与抽屉内重排同一先例）。
                onDragPointerChanged(NSEvent.mouseLocation)
                // 落点按**行内**位移判槽：行被自动滚推动时补偿量已含在内，
                // 用原始 translation 会把指针与槽位算错（游标与胶囊脱节）。
                let target = target(for: effectiveDragOffset)
                guard target != reportedTarget else { return }
                reportedTarget = target
                onDragTargetChanged(target)
            }
            .onEnded { value in
                if isDragging {
                    let target = target(for: effectiveDragOffset)
                    // 与父级的页序提交同帧瞬移，避免二次交换动画；scale/shadow 仍由 .animation(value:isDragging) 的 spring 驱动
                    dragOffset = 0
                    pickupScrollOffset = 0
                    isDragging = false
                    reportedTarget = nil
                    onDraggingChanged(false)
                    onDragCommit(target)
                    return
                }
                // 滑动会话期的点击**不再丢弃**（旧守卫在弹簧全程留下 0.4–0.6s
                // 的点击死窗：轻扫后立刻点胶囊无响应，须等散场再点）：交给控制
                // 器即时打断在飞会话并跳页。拖动排序仍由 onChanged 的守卫拦住，
                // 与会话互斥不变。
                // 未进拖动且位移没越阈才算点击：按下后拖一把再松手不该切页。
                guard hypot(value.translation.width, value.translation.height)
                        <= DrawerPagePillLayout.dragPickupDistance else { return }
                onSelect()
            }
    }

    private func target(for translation: CGFloat) -> Int {
        DrawerPagePillLayout.targetIndex(draggedIndex: slot, translation: translation, count: count)
    }
}

// MARK: - 滚动裁切后的命中形状

/// 胶囊被滚动区裁切时的命中横段（纵向仍整条命中框 = `rowHeight`）。
/// 存在的理由：`clipped()` 只裁绘制不裁命中，溢出到滚动区外的胶囊会把齿轮/
/// 钉住的点击抢走——命中面必须与"看得见的那一段"同源。
private struct PillHitSpan: Shape {
    /// 相对胶囊左缘的起偏移与宽度（`DrawerCapsuleVisibility.partial` 的口径）。
    let x: CGFloat
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lower = max(x, rect.minX)
        let upper = min(x + width, rect.maxX)
        guard upper > lower else { return path }
        path.addRect(CGRect(x: lower, y: rect.minY, width: upper - lower, height: rect.height))
        return path
    }
}
