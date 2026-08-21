import AppKit
import CoreGraphics

/// 刘海布局几何：紧凑面板（3 槽）与激活区域（文档 §5.1 / §5.2 / §6.3）。
struct NotchLayout: Equatable {
    /// 刘海尺寸（无刘海屏幕为顶部中央回退尺寸）。
    let notchSize: NSSize
    /// 紧凑面板尺寸：宽度 = 3 槽 + 间距 + 内边距（clamp 到刘海宽度），
    /// 高度 = 刘海高度 + 槽位高度（44）+ 底边距。
    let compactSize: NSSize
    /// 面板顶部相对屏幕顶部的偏移（保持 0，紧贴屏幕顶部）。
    let compactTopOffset: CGFloat
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
    /// 紧凑区槽位参数（文档 §5.2）：3 槽，每槽 44×44。
    static let compactSlotCount = 3
    static let compactSlotSize = NSSize(width: 44, height: 44)
    static let compactSlotSpacing: CGFloat = 6
    static let compactHorizontalPadding: CGFloat = 10

    /// 紧凑面板宽度：三槽 + 间距 + 内边距，clamp 到刘海宽度以内（文档 §5.2 面板水平居中于刘海下方）。
    static var compactPanelWidth: CGFloat {
        let intrinsic = CGFloat(compactSlotCount) * compactSlotSize.width
            + CGFloat(compactSlotCount - 1) * compactSlotSpacing
            + compactHorizontalPadding * 2
        return intrinsic
    }

    /// 无刘海屏幕的顶部中央回退尺寸。
    static let fallbackNotchSize = NSSize(width: 210, height: 32)

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

        let compactWidth = min(compactPanelWidth, max(96, notch.width - 6))
        let compactHeight = notch.height + 44 + 2

        return NotchLayout(
            notchSize: notch,
            compactSize: NSSize(width: compactWidth, height: compactHeight),
            compactTopOffset: 0
        )
    }

    /// 激活区域（热区）：宽度 = 刘海宽度，高度 = 紧凑面板高度。
    static func activationFrame(for layout: NotchLayout, in screenFrame: NSRect) -> NSRect {
        let activationSize = NSSize(
            width: layout.notchSize.width,
            height: layout.compactSize.height
        )
        return topCenteredFrame(
            for: activationSize,
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