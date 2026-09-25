import AppKit
import CoreGraphics

/// 刘海布局几何：紧凑区（左右分列刘海两侧的按钮带）与激活区域
/// （文档 §5.1 / §5.2 / §6.3）。
struct NotchLayout: Equatable {
    /// 刘海尺寸（无刘海屏幕为顶部中央回退尺寸）。
    let notchSize: NSSize
    /// 紧凑区高度（= 刘海高度；不随图标数变化，紧凑区不向下超出刘海）。
    let compactHeight: CGFloat

    /// 指定紧凑图标数下的紧凑区条带几何（宽度随图标数动态伸缩）。
    /// `leftSummaryWidth` / `rightSummaryWidth`：两侧活动摘要芯片宽度
    /// （>0 时计入带宽，缺省 0 = 纯图标几何）。
    func compactStrip(
        slotCount: Int,
        leftSummaryWidth: CGFloat = 0,
        rightSummaryWidth: CGFloat = 0
    ) -> CompactStripLayout {
        CompactStripLayout(
            notchWidth: notchSize.width,
            height: compactHeight,
            slotCount: max(0, slotCount),
            leftSummaryWidth: max(0, leftSummaryWidth),
            rightSummaryWidth: max(0, rightSummaryWidth)
        )
    }

    /// 指定紧凑图标数下的紧凑区窗口尺寸（含摘要带宽）。
    func compactSize(
        slotCount: Int,
        leftSummaryWidth: CGFloat = 0,
        rightSummaryWidth: CGFloat = 0
    ) -> NSSize {
        NSSize(
            width: compactStrip(
                slotCount: slotCount,
                leftSummaryWidth: leftSummaryWidth,
                rightSummaryWidth: rightSummaryWidth
            ).windowWidth,
            height: compactHeight
        )
    }
}

/// 紧凑区分列布局：图标按添加顺序**左右均衡交替**排布（偶数索引在左、奇数
/// 在右，均从靠刘海一侧排起——最内一对图标绕刘海中心镜像对称），两面板
/// 等宽（按较大一侧的实际槽数）保证黑色带绕刘海左右对称、刘海中心恒为
/// 带宽中心（== 窗口中心，窗口绕屏幕中线居中）。带宽随 `slotCount`
/// （当前紧凑图标数）动态伸缩，不再固定 3 槽。
///
/// 活动摘要芯片（可选）贴刘海两侧、处于各自面板的**内侧**：左摘要位于
/// 左面板靠刘海一端、右摘要位于右面板靠刘海一端；有摘要的一侧图标被向外
/// 推移一个芯片带（`leftSummaryWidth` / `rightSummaryWidth` > 0 时生效，
/// 缺省 0 = 与旧几何完全一致）。两侧面板等宽原则不变：芯片带宽取两侧
/// 较大值计入两面板（`sideSummaryBand`），无摘要一侧的余量落在面板外端，
/// 保证刘海恒为带宽中心（决策：Agent Note 2026-09-03-compact-area-activity-summary）。
struct CompactStripLayout: Equatable {
    let notchWidth: CGFloat
    let height: CGFloat
    /// 当前紧凑图标数（紧凑引用数组长度）。
    let slotCount: Int
    /// 左侧摘要芯片宽度（0 = 无摘要；含芯片自身全部外观宽度）。
    var leftSummaryWidth: CGFloat = 0
    /// 右侧摘要芯片宽度（0 = 无摘要）。
    var rightSummaryWidth: CGFloat = 0

    private var slotSize: NSSize { NotchGeometry.compactSlotSize }
    private var spacing: CGFloat { NotchGeometry.compactSlotSpacing }
    private var padding: CGFloat { NotchGeometry.compactHorizontalPadding }
    private var gap: CGFloat { NotchGeometry.compactNotchGap }
    private var summaryIconGap: CGFloat { NotchGeometry.summaryIconGap }

    /// 左右均衡交替：偶数索引在左、奇数在右，每侧列号 = index / 2。
    var leftSlots: Int { (slotCount + 1) / 2 }
    var rightSlots: Int { slotCount / 2 }

    /// 面板宽度：按单侧槽数计算。
    private func panelWidth(slots: Int) -> CGFloat {
        guard slots > 0 else { return 0 }
        return CGFloat(slots) * slotSize.width
            + CGFloat(slots - 1) * spacing
            + padding * 2
    }

    /// 两面板等宽（按较大一侧实际槽数）：黑色带绕刘海左右对称。
    var sideSlots: Int { max(leftSlots, rightSlots) }

    // MARK: - 活动摘要带宽

    var hasLeftSummary: Bool { leftSummaryWidth > 0 }
    var hasRightSummary: Bool { rightSummaryWidth > 0 }

    /// 左侧芯片占用的面板带宽（芯片 + 与图标的间隙）。
    var leftSummaryBand: CGFloat {
        hasLeftSummary ? leftSummaryWidth + summaryIconGap : 0
    }

    /// 右侧芯片占用的面板带宽（芯片 + 与图标的间隙）。
    var rightSummaryBand: CGFloat {
        hasRightSummary ? rightSummaryWidth + summaryIconGap : 0
    }

    /// 两侧面板统一的摘要带宽（取两侧较大值：面板等宽、刘海恒居中）。
    var sideSummaryBand: CGFloat {
        max(leftSummaryBand, rightSummaryBand)
    }

    /// 摘要芯片显示高度（随紧凑带高度自适应，夹在上下留白内）。
    var summaryHeight: CGFloat {
        min(NotchGeometry.summaryChipHeight, max(NotchGeometry.summaryChipMinHeight, height - 6))
    }

    var leftPanelWidth: CGFloat { panelWidth(slots: sideSlots) + sideSummaryBand }
    var rightPanelWidth: CGFloat { panelWidth(slots: sideSlots) + sideSummaryBand }

    /// 左侧摘要芯片矩形（窗口内容坐标，左上原点）；无摘要返回 nil。
    var leftSummaryRect: CGRect? {
        guard hasLeftSummary else { return nil }
        return CGRect(
            x: leftPanelWidth - padding - leftSummaryWidth,
            y: (height - summaryHeight) / 2,
            width: leftSummaryWidth,
            height: summaryHeight
        )
    }

    /// 右侧摘要芯片矩形（窗口内容坐标，左上原点）；无摘要返回 nil。
    var rightSummaryRect: CGRect? {
        guard hasRightSummary else { return nil }
        return CGRect(
            x: rightPanelX + padding,
            y: (height - summaryHeight) / 2,
            width: rightSummaryWidth,
            height: summaryHeight
        )
    }

    /// 右侧面板在黑色带内的水平原点（带内坐标）。
    var rightPanelX: CGFloat {
        leftPanelWidth + gap + notchWidth + gap
    }

    /// 黑色带宽度（窗口与带同宽：窗口绕屏幕中线居中，带体恒占满窗口，
    /// 刘海中心恒为带宽中心——不再有带内偏移）。
    var bandWidth: CGFloat {
        rightPanelX + rightPanelWidth
    }

    /// 刘海中心的窗口横坐标（== 带宽中心，窗口绕屏幕中线居中）。
    var notchCenterX: CGFloat {
        leftPanelWidth + gap + notchWidth / 2
    }

    /// 热区窗口总宽度（与黑色带同宽，带体绕刘海左右对称）。
    var windowWidth: CGFloat {
        bandWidth
    }

    /// 内容坐标 x → **屏幕插入位置**（0...slotCount，slotCount = 末尾）：
    /// 按屏幕从左到右的顺序找第一个中线在 x 右侧的槽位。
    /// 返回的是屏幕序号而不是数组下标——落点语义统一为屏幕位置，
    /// 由 `CompactSlotOrder` 负责与数组下标互转（方案 A）。
    func screenInsertionIndex(atContentX x: CGFloat) -> Int {
        guard slotCount > 0 else { return 0 }
        for (position, index) in CompactSlotOrder.screenOrder(slotCount: slotCount).enumerated() {
            if x < (slotRect(at: index)?.midX ?? 0) { return position }
        }
        return slotCount
    }

    /// 槽位矩形（窗口内容坐标，左上原点）；越界返回 nil。
    /// 偶数（左面板）锚定外端、奇数（右面板）锚定靠刘海一端——右侧有摘要
    /// 芯片时图标整体外移一个芯片带（`rightSummaryBand`），左侧图标不移动
    /// （左芯片占用的是内侧新增带宽）。
    func slotRect(at index: Int) -> CGRect? {
        guard index >= 0, index < slotCount else { return nil }
        let y = (height - slotSize.height) / 2
        let column = index / 2
        let x: CGFloat = index % 2 == 0
            ? padding + CGFloat(column) * (slotSize.width + spacing)
            : rightPanelX + padding + rightSummaryBand + CGFloat(column) * (slotSize.width + spacing)
        return CGRect(x: x, y: y, width: slotSize.width, height: slotSize.height)
    }
}

// MARK: - 快捷区屏幕顺序 ↔ 数组下标

/// 快捷区「屏幕位置 ↔ 数组下标」的双向映射（拖动重排与拖入落位的共同基础）。
///
/// 数组下标按奇偶分列（偶数进左面板、奇数进右面板，每侧列号 = index / 2），
/// 于是**屏幕从左到右 = 全部偶数下标升序 → 全部奇数下标升序**：
///
/// ```
/// 数组 [A, B, C, D, E]  →  屏幕 A C E | B D
/// 下标  0  1  2  3  4        (0,2,4 在左；1,3 在右)
/// ```
///
/// 如果直接按数组语义插入（旧实现），在数组中间插一个会让后续下标整体
/// 后移，而下标决定左右分列——屏幕上其余图标会集体换位。因此所有落点都
/// 先换算成**屏幕位置**，在屏幕序列里移动/插入，再经本映射写回数组，
/// 保证"屏幕上只有被操作的那一个移动，其余保持相对顺序"。
enum CompactSlotOrder {
    /// 屏幕第 position 位对应的数组下标序列（长度 = slotCount）。
    static func screenOrder(slotCount: Int) -> [Int] {
        guard slotCount > 0 else { return [] }
        return stride(from: 0, to: slotCount, by: 2).map { $0 }
            + stride(from: 1, to: slotCount, by: 2).map { $0 }
    }

    /// 数组下标 → 屏幕位置（不在范围内返回 nil）。
    static func screenPosition(of slotIndex: Int, slotCount: Int) -> Int? {
        screenOrder(slotCount: slotCount).firstIndex(of: slotIndex)
    }

    /// 重排后的数组内容：把 `from` 移到屏幕位置 `to`（0...count），
    /// 其余保持屏幕相对顺序。返回 nil 表示无变化（越界或落点即原位）。
    ///
    /// - 屏幕序列里移动：移除被拖项 → 插到目标屏幕位置；
    /// - 写回数组：屏幕第 j 位 → 数组下标 `screenOrder[j]`（映射只依赖总数）。
    static func reordered(
        _ slots: [CompactSlotReference?],
        from: Int,
        to screenPosition: Int
    ) -> [CompactSlotReference?]? {
        let count = slots.count
        guard slots.indices.contains(from) else { return nil }
        let order = screenOrder(slotCount: count)
        guard let fromPosition = order.firstIndex(of: from) else { return nil }

        var screenItems = order.map { slots[$0] }
        let moved = screenItems.remove(at: fromPosition)
        let target = min(
            max(screenPosition > fromPosition ? screenPosition - 1 : screenPosition, 0),
            screenItems.count
        )
        guard target != fromPosition else { return nil }
        screenItems.insert(moved, at: target)

        var result = slots
        for (position, slotIndex) in order.enumerated() {
            result[slotIndex] = screenItems[position]
        }
        return result
    }

    /// 在屏幕位置 `position`（0...count）插入新元素后的数组内容；
    /// 其余保持屏幕相对顺序（插入后总数 +1，映射随之变化）。
    static func inserting(
        _ item: CompactSlotReference,
        into slots: [CompactSlotReference?],
        atScreenPosition position: Int
    ) -> [CompactSlotReference?] {
        let count = slots.count
        let oldOrder = screenOrder(slotCount: count)
        let newOrder = screenOrder(slotCount: count + 1)

        // 新屏幕序列：旧的第 [0, position) 位 + 新元素 + 旧的第 [position...) 位。
        var screenItems: [CompactSlotReference?] = []
        screenItems.reserveCapacity(count + 1)
        for screenPosition in 0...count {
            if screenPosition == position {
                screenItems.append(item)
            } else {
                let oldIndex = screenPosition < position
                    ? oldOrder[screenPosition]
                    : oldOrder[screenPosition - 1]
                screenItems.append(slots[oldIndex])
            }
        }

        var result: [CompactSlotReference?] = Array(repeating: nil, count: count + 1)
        for (screenPosition, slotIndex) in newOrder.enumerated() {
            result[slotIndex] = screenItems[screenPosition]
        }
        return result
    }

    /// 移除数组下标 `index` 后的数组内容（其余保持屏幕相对顺序）。
    /// 与插入/重排同理：直接 remove 会让后续下标重排、屏幕上集体换位。
    static func removing(
        _ slots: [CompactSlotReference?],
        at index: Int
    ) -> [CompactSlotReference?]? {
        let count = slots.count
        guard slots.indices.contains(index) else { return nil }
        let order = screenOrder(slotCount: count)
        let screenItems = order.filter { $0 != index }.map { slots[$0] }
        let newOrder = screenOrder(slotCount: count - 1)
        var result: [CompactSlotReference?] = Array(repeating: nil, count: count - 1)
        for (position, slotIndex) in newOrder.enumerated() {
            result[slotIndex] = screenItems[position]
        }
        return result
    }

    /// 批量移除若干屏幕图标后的数组内容：其余图标保持屏幕相对顺序，等价于按
    /// 屏幕位置逐个 `removing`，只是一次重映射。无命中时原样返回。
    ///
    /// **必须走这里，不能直接 `filter` 数组**：数组下标决定左右分列
    /// （`screenOrder` 只依赖总数），长度一变映射就变——被删项之后的图标会
    /// 整体换列，屏幕上表现为"删一个、其余好几个跳边"。
    static func removingAll(
        _ slots: [CompactSlotReference?],
        where shouldRemove: (CompactSlotReference?) -> Bool
    ) -> [CompactSlotReference?] {
        let count = slots.count
        let screenItems = screenOrder(slotCount: count)
            .map { slots[$0] }
            .filter { !shouldRemove($0) }
        let newCount = screenItems.count
        guard newCount < count else { return slots }

        let newOrder = screenOrder(slotCount: newCount)
        var result: [CompactSlotReference?] = Array(repeating: nil, count: newCount)
        for (position, slotIndex) in newOrder.enumerated() {
            result[slotIndex] = screenItems[position]
        }
        return result
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }

    var isBuiltInDisplay: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    var measuredNotchSize: NSSize {
        guard #available(macOS 12.0, *), safeAreaInsets.top > 0 else {
            return .zero
        }

        guard let leftArea = auxiliaryTopLeftArea, let rightArea = auxiliaryTopRightArea else {
            return .zero
        }

        let notchWidth = frame.width - leftArea.width - rightArea.width
        guard notchWidth > 0, notchWidth < frame.width else {
            return .zero
        }

        return NSSize(width: notchWidth, height: safeAreaInsets.top)
    }
}

// MARK: - 设置面板摆位

/// 设置面板的垂直摆位模式（见 `NotchGeometry.settingsPlacement`）。
enum SettingsDockMode: Equatable {
    /// 抽屉下方：窗口顶缘贴抽屉可见底缘之下一个间距——抽屉下方放得下时
    /// 优先，面板与抽屉上下咬合，读数视线不离刘海。
    case belowDrawer
    /// 屏幕底部：抽屉下方放不下，退回 visibleFrame 底缘停靠（抽屉限高让位）。
    case screenBottom
}

/// 设置面板摆位结果（Cocoa 屏幕坐标，y 向上）。
struct SettingsPlacement: Equatable {
    let mode: SettingsDockMode
    /// 设置窗口 **frame** 顶缘 Y（含透明 titlebar 的那条上边）。
    let frameTopY: CGFloat

    /// 窗口 frame 底缘 Y（AppKit origin）：顶缘下移一个窗口 frame 高度。
    func frameOriginY(bandHeight: CGFloat) -> CGFloat {
        frameTopY - bandHeight
    }
}

@MainActor
enum NotchGeometry {
    /// 紧凑区槽位参数（文档 §5.2）：槽位数**不固定**，随添加的图标动态伸缩；
    /// 图标按添加顺序左右均衡交替排布（偶数索引在左、奇数在右，均从靠
    /// 刘海一侧排起），带宽 = 两侧面板 + 间隙 + 刘海。
    nonisolated static let compactSlotSize = NSSize(width: 28, height: 28)
    nonisolated static let compactSlotSpacing: CGFloat = 8
    nonisolated static let compactHorizontalPadding: CGFloat = 10
    /// 两侧面板与刘海边缘的间隙。
    nonisolated static let compactNotchGap: CGFloat = 5

    // MARK: 活动摘要芯片
    /// 摘要芯片与同侧图标的间隙（芯片贴刘海、图标在其外侧）。
    nonisolated static let summaryIconGap: CGFloat = 6
    /// 摘要芯片高度上限（紧凑带较矮时随带自适应收缩，见 `summaryMinHeight`）。
    nonisolated static let summaryChipHeight: CGFloat = 26
    /// 摘要芯片高度下限。
    nonisolated static let summaryChipMinHeight: CGFloat = 18

    /// 无刘海屏幕的顶部中央回退尺寸。
    nonisolated static let fallbackNotchSize = NSSize(width: 210, height: 32)

    /// 鼠标所在屏幕（文档 §6.3：面板跟随鼠标所在屏幕）。
    static func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func layout(for screen: NSScreen?, compactCount: Int) -> NotchLayout {
        let measured = screen?.measuredNotchSize ?? .zero
        let notch = measured == .zero ? fallbackNotchSize : measured

        return NotchLayout(
            notchSize: notch,
            compactHeight: notch.height
        )
    }

    /// 激活区域（热区）：整个紧凑带（含左右面板与刘海上方区域），
    /// 高度 = 刘海高度，宽度随当前紧凑图标数与摘要带宽动态伸缩。
    static func activationFrame(
        for layout: NotchLayout,
        slotCount: Int,
        leftSummaryWidth: CGFloat = 0,
        rightSummaryWidth: CGFloat = 0,
        in screenFrame: NSRect
    ) -> NSRect {
        topCenteredFrame(
            for: layout.compactSize(
                slotCount: slotCount,
                leftSummaryWidth: leftSummaryWidth,
                rightSummaryWidth: rightSummaryWidth
            ),
            topY: screenFrame.maxY,
            in: screenFrame
        )
    }

    static func topCenteredFrame(
        for size: NSSize,
        topY: CGFloat,
        in screenFrame: NSRect
    ) -> NSRect {
        NSRect(
            x: screenFrame.midX - size.width / 2,
            y: topY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: 设置面板摆位

    /// 抽屉可见底缘 Y（Cocoa 屏幕坐标）：抽屉顶缘钉死屏幕顶缘，可见高度
    /// = 紧凑带 + 抽屉内容高。
    nonisolated static func drawerVisibleBottomY(
        screenMaxY: CGFloat,
        compactHeight: CGFloat,
        drawerContentHeight: CGFloat
    ) -> CGFloat {
        screenMaxY - compactHeight - drawerContentHeight
    }

    /// 停靠屏幕底部的设置面板窗口顶缘 Y：visibleFrame 底缘（避开 Dock）
    /// + 底部间距 + 窗口 frame 高度（内容高度 + 透明 titlebar，调试页可调，
    /// 由调用方从 SettingsStore 现算传入）。
    nonisolated static func dockedSettingsTopY(
        visibleMinY: CGFloat,
        bandHeight: CGFloat
    ) -> CGFloat {
        visibleMinY + SettingsWindowMetrics.bottomInset + bandHeight
    }

    /// 裁定设置面板摆位：**抽屉下方空间足够就贴抽屉底缘**（窗口完整落在
    /// 抽屉可见底缘之下一个间距、且底缘仍高于 visibleFrame 底缘安全间距），
    /// 否则退回屏幕底部停靠（由抽屉限高让位，见
    /// `settingsCappedDrawerHeight`）。
    ///
    /// 判据只用**未限高**的抽屉自然高度（`drawerBottomY`）——限高结果依赖
    /// 摆位、摆位又依赖限高会自激（抽屉越矮越"放得下"，永远停在抽屉下方）。
    nonisolated static func settingsPlacement(
        visibleMinY: CGFloat,
        drawerBottomY: CGFloat,
        bandHeight: CGFloat
    ) -> SettingsPlacement {
        let belowDrawerTopY = drawerBottomY - SettingsWindowMetrics.gapFromSettings
        let fitsBelowDrawer = belowDrawerTopY - bandHeight
            >= visibleMinY + SettingsWindowMetrics.bottomInset
        guard fitsBelowDrawer else {
            return SettingsPlacement(
                mode: .screenBottom,
                frameTopY: dockedSettingsTopY(visibleMinY: visibleMinY, bandHeight: bandHeight)
            )
        }
        return SettingsPlacement(mode: .belowDrawer, frameTopY: belowDrawerTopY)
    }

    /// 设置打开期间抽屉可见内容的高度上限（不含紧凑带）：抽屉顶缘钉死
    /// `screenMaxY`，可见底缘不得低于设置面板顶缘再留间距。
    ///
    /// `settingsTopY` 由 `settingsPlacement` 现算——两种摆位共用同一条不变量，
    /// 贴抽屉下方时该上限 == 裁定时的抽屉自然高度（限高为空操作，抽屉长高
    /// 会触发重裁摆位而不是被悄悄截断）。极端矮屏返回值可能 ≤ 0——调用方须
    /// 先与最小抽屉尺寸比较，放不开时整体放弃限高（允许重叠），不能把抽屉
    /// 塌成 0。
    nonisolated static func settingsCappedDrawerHeight(
        screenMaxY: CGFloat,
        settingsTopY: CGFloat,
        compactHeight: CGFloat
    ) -> CGFloat {
        screenMaxY - settingsTopY - SettingsWindowMetrics.gapFromSettings - compactHeight
    }
}
