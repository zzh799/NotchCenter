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
    func compactStrip(slotCount: Int) -> CompactStripLayout {
        CompactStripLayout(
            notchWidth: notchSize.width,
            height: compactHeight,
            slotCount: max(0, slotCount)
        )
    }

    /// 指定紧凑图标数下的紧凑区窗口尺寸。
    func compactSize(slotCount: Int) -> NSSize {
        NSSize(width: compactStrip(slotCount: slotCount).windowWidth, height: compactHeight)
    }
}

/// 紧凑区分列布局：图标按添加顺序**左右均衡交替**排布（偶数索引在左、奇数
/// 在右，均从靠刘海一侧排起——最内一对图标绕刘海中心镜像对称），两面板
/// 等宽（按较大一侧的实际槽数）保证黑色带绕刘海左右对称、刘海中心恒为
/// 带宽中心（== 窗口中心，窗口绕屏幕中线居中）。带宽随 `slotCount`
/// （当前紧凑图标数）动态伸缩，不再固定 3 槽。
struct CompactStripLayout: Equatable {
    let notchWidth: CGFloat
    let height: CGFloat
    /// 当前紧凑图标数（紧凑引用数组长度）。
    let slotCount: Int

    private var slotSize: NSSize { NotchGeometry.compactSlotSize }
    private var spacing: CGFloat { NotchGeometry.compactSlotSpacing }
    private var padding: CGFloat { NotchGeometry.compactHorizontalPadding }
    private var gap: CGFloat { NotchGeometry.compactNotchGap }

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

    var leftPanelWidth: CGFloat { panelWidth(slots: sideSlots) }
    var rightPanelWidth: CGFloat { panelWidth(slots: sideSlots) }

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
    func slotRect(at index: Int) -> CGRect? {
        guard index >= 0, index < slotCount else { return nil }
        let y = (height - slotSize.height) / 2
        let column = index / 2
        let x: CGFloat = index % 2 == 0
            ? padding + CGFloat(column) * (slotSize.width + spacing)
            : rightPanelX + padding + CGFloat(column) * (slotSize.width + spacing)
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
    /// 高度 = 刘海高度，宽度随当前紧凑图标数动态伸缩。
    static func activationFrame(
        for layout: NotchLayout,
        slotCount: Int,
        in screenFrame: NSRect
    ) -> NSRect {
        topCenteredFrame(
            for: layout.compactSize(slotCount: slotCount),
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
}
