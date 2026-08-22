import AppKit
import XCTest
@testable import NotchCenter

@MainActor
final class NotchGeometryTests: XCTestCase {
    func testActivationFrameCoversCompactStripAndFlushWithTop() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = NotchGeometry.layout(for: nil)

        let activationFrame = NotchGeometry.activationFrame(for: layout, in: screenFrame)

        XCTAssertEqual(activationFrame.width, layout.compactSize.width)
        XCTAssertEqual(activationFrame.height, layout.compactSize.height)
        XCTAssertEqual(activationFrame.midX, screenFrame.midX)
        XCTAssertEqual(activationFrame.maxY, screenFrame.maxY)
    }

    func testFallbackLayoutForScreenWithoutNotch() {
        // 无刘海屏幕：顶部中央回退尺寸（文档 §6.3）；紧凑区高度即刘海高度带。
        let layout = NotchGeometry.layout(for: nil)

        XCTAssertEqual(layout.notchSize, NotchGeometry.fallbackNotchSize)
        XCTAssertEqual(layout.compactSize.height, NotchGeometry.fallbackNotchSize.height)
        XCTAssertEqual(layout.compactSize.width, layout.compactStrip.windowWidth)
    }

    func testTopCenteredFrameMathematics() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = NotchGeometry.topCenteredFrame(
            for: NSSize(width: 300, height: 100),
            topY: screenFrame.maxY,
            in: screenFrame
        )

        XCTAssertEqual(frame.midX, 500)
        XCTAssertEqual(frame.maxY, 800)
        XCTAssertEqual(frame.minY, 700)
    }

    func testCompactStripSplitsSlotsAroundNotch() {
        // 左右面板等宽：黑色带绕刘海左右对称（左 2 右 1 个槽位，但两侧容量一致）。
        let strip = CompactStripLayout(notchWidth: 210, height: 32)

        let slot = NotchGeometry.compactSlotSize
        let padding = NotchGeometry.compactHorizontalPadding
        let spacing = NotchGeometry.compactSlotSpacing
        let gap = NotchGeometry.compactNotchGap

        XCTAssertEqual(strip.leftSlots, 2)
        XCTAssertEqual(strip.rightSlots, 1)
        XCTAssertEqual(strip.leftPanelWidth, strip.rightPanelWidth)
        XCTAssertEqual(
            strip.leftPanelWidth,
            CGFloat(2) * slot.width + spacing + padding * 2
        )
        XCTAssertEqual(strip.rightPanelX, strip.leftPanelWidth + gap + 210 + gap)
        XCTAssertEqual(
            strip.windowWidth,
            strip.rightPanelX + strip.rightPanelWidth + NotchGeometry.compactEditReserve
        )

        // 带体绕刘海的左右边距相等。
        XCTAssertEqual(strip.notchCenterX, strip.windowWidth / 2)
    }

    func testCompactStripSlotRects() {
        let strip = CompactStripLayout(notchWidth: 210, height: 32)
        let slot = NotchGeometry.compactSlotSize
        let expectedY: CGFloat = (32 - slot.height) / 2
        let padding = NotchGeometry.compactHorizontalPadding
        let spacing = NotchGeometry.compactSlotSpacing
        let bandLeft = strip.bandLeft

        // 左侧两个槽位。
        XCTAssertEqual(
            strip.slotRect(at: 0),
            CGRect(x: bandLeft + padding, y: expectedY, width: slot.width, height: slot.height)
        )
        XCTAssertEqual(
            strip.slotRect(at: 1),
            CGRect(
                x: bandLeft + padding + slot.width + spacing,
                y: expectedY,
                width: slot.width,
                height: slot.height
            )
        )

        // 右侧一个槽位（刘海另一侧，紧贴刘海排列）。
        XCTAssertEqual(
            strip.slotRect(at: 2),
            CGRect(
                x: bandLeft + strip.rightPanelX + padding,
                y: expectedY,
                width: slot.width,
                height: slot.height
            )
        )

        // 内侧一对图标绕刘海中心镜像对称。
        let innerLeftCenter = strip.slotRect(at: 1)!.midX
        let rightCenter = strip.slotRect(at: 2)!.midX
        XCTAssertEqual(
            strip.notchCenterX - innerLeftCenter,
            rightCenter - strip.notchCenterX,
            accuracy: 0.5
        )

        // 越界返回 nil。
        XCTAssertNil(strip.slotRect(at: -1))
        XCTAssertNil(strip.slotRect(at: 3))
    }

    func testCompactStripEditButtonInReserveArea() {
        let strip = CompactStripLayout(notchWidth: 210, height: 32)

        // “+”按钮位于右侧面板之外的预留区，垂直居中。
        XCTAssertEqual(strip.editButtonPoint.x, strip.windowWidth - NotchGeometry.compactEditReserve / 2)
        XCTAssertEqual(strip.editButtonPoint.y, 16)
    }
}
