import AppKit
import CoreGraphics

/// 刘海布局几何：紧凑区（左右分列刘海两侧的按钮带）与激活区域
/// （文档 §5.1 / §5.2 / §6.3）。
struct NotchLayout: Equatable {
    /// 刘海尺寸（无刘海屏幕为顶部中央回退尺寸）。
    let notchSize: NSSize
    /// 紧凑热区窗口尺寸：宽度覆盖 左面板+间隙+刘海+间隙+右面板，
    /// 高度 = 刘海高度（紧凑区不再向下超出刘海）。
    let compactSize: NSSize
    /// 面板顶部相对屏幕顶部的偏移（保持 0，紧贴屏幕顶部）。
    let compactTopOffset: CGFloat

    /// 紧凑区左右分列布局（由刘海尺寸推导，窗口内容坐标系为左上原点）。
    var compactStrip: CompactStripLayout {
        CompactStripLayout(notchWidth: notchSize.width, height: compactSize.height)
    }
}

/// 紧凑区分列布局：左侧最多 2 个槽位、其余在右侧，中间留出刘海本身。
struct CompactStripLayout: Equatable {
    let notchWidth: CGFloat
    let height: CGFloat

    private var slotSize: NSSize { NotchGeometry.compactSlotSize }
    private var spacing: CGFloat { NotchGeometry.compactSlotSpacing }
    private var padding: CGFloat { NotchGeometry.compactHorizontalPadding }
    private var gap: CGFloat { NotchGeometry.compactNotchGap }

    var leftSlots: Int {
        min(NotchGeometry.compactSlotCount, NotchGeometry.maxCompactSlotsPerSide)
    }

    var rightSlots: Int {
        NotchGeometry.compactSlotCount - leftSlots
    }

    /// 面板宽度：左右两侧等宽（按单侧最大槽位数计算），
    /// 使黑色带绕刘海左右对称；右侧槽位仍从靠刘海一侧排起。
    private func panelWidth(slots: Int) -> CGFloat {
        guard slots > 0 else { return 0 }
        return CGFloat(slots) * slotSize.width
            + CGFloat(slots - 1) * spacing
            + padding * 2
    }

    var leftPanelWidth: CGFloat { panelWidth(slots: NotchGeometry.maxCompactSlotsPerSide) }
    var rightPanelWidth: CGFloat { panelWidth(slots: NotchGeometry.maxCompactSlotsPerSide) }

    /// 右侧面板在黑色带内的水平原点（带内坐标）。
    var rightPanelX: CGFloat {
        leftPanelWidth + gap + notchWidth + gap
    }

    /// 黑色带宽度（不含右侧编辑占位区）。
    var bandWidth: CGFloat {
        rightPanelX + rightPanelWidth
    }

    /// 带体在窗口内的水平起点：窗口含编辑占位且整体屏幕居中，
    /// 带体在窗口内居中放置，保证绕物理刘海左右对称。
    var bandLeft: CGFloat {
        (windowWidth - bandWidth) / 2
    }

    /// 刘海中心的窗口横坐标。
    var notchCenterX: CGFloat {
        bandLeft + leftPanelWidth + gap + notchWidth / 2
    }

    /// 热区窗口总宽度（与黑色带同宽，带体绕刘海左右对称）。
    var windowWidth: CGFloat {
        bandWidth
    }

    /// 槽位矩形（窗口内容坐标，左上原点）；越界返回 nil。
    func slotRect(at index: Int) -> CGRect? {
        guard index >= 0, index < NotchGeometry.compactSlotCount else { return nil }
        let y = (height - slotSize.height) / 2
        if index < leftSlots {
            let x = bandLeft + padding + CGFloat(index) * (slotSize.width + spacing)
            return CGRect(x: x, y: y, width: slotSize.width, height: slotSize.height)
        }
        let j = index - leftSlots
        let x = bandLeft + rightPanelX + padding + CGFloat(j) * (slotSize.width + spacing)
        return CGRect(x: x, y: y, width: slotSize.width, height: slotSize.height)
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
    /// 紧凑区槽位参数（文档 §5.2）：共 3 槽，分列刘海两侧（左 2 右 1）。
    nonisolated static let compactSlotCount = 3
    /// 槽位尺寸适配刘海高度带：紧凑区不向下超出刘海。
    nonisolated static let compactSlotSize = NSSize(width: 28, height: 28)
    nonisolated static let compactSlotSpacing: CGFloat = 8
    nonisolated static let compactHorizontalPadding: CGFloat = 10
    /// 两侧面板与刘海边缘的间隙。
    nonisolated static let compactNotchGap: CGFloat = 5
    /// 单侧最大槽位数（超出部分放到另一侧）。
    nonisolated static let maxCompactSlotsPerSide = 2

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

    static func layout(for screen: NSScreen?) -> NotchLayout {
        let measured = screen?.measuredNotchSize ?? .zero
        let notch = measured == .zero ? fallbackNotchSize : measured
        let strip = CompactStripLayout(notchWidth: notch.width, height: notch.height)

        return NotchLayout(
            notchSize: notch,
            compactSize: NSSize(width: strip.windowWidth, height: strip.height),
            compactTopOffset: 0
        )
    }

    /// 激活区域（热区）：整个紧凑带（含左右面板与刘海上方区域），
    /// 高度 = 刘海高度。
    static func activationFrame(for layout: NotchLayout, in screenFrame: NSRect) -> NSRect {
        topCenteredFrame(
            for: NSSize(
                width: layout.compactSize.width,
                height: layout.compactSize.height
            ),
            topY: screenFrame.maxY + layout.compactTopOffset,
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
