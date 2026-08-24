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

    /// 黑色带宽度。
    var bandWidth: CGFloat {
        rightPanelX + rightPanelWidth
    }

    /// 带体在窗口内的水平起点：窗口与带同宽（不再为编辑模式“+”预留
    /// 右端占位），带体恒占满窗口并绕物理刘海左右对称。
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
        guard index >= 0, index < slotCount else { return nil }
        let y = (height - slotSize.height) / 2
        let column = index / 2
        let x: CGFloat = index % 2 == 0
            ? bandLeft + padding + CGFloat(column) * (slotSize.width + spacing)
            : bandLeft + rightPanelX + padding + CGFloat(column) * (slotSize.width + spacing)
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
