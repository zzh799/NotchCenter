import AppKit
import XCTest
@testable import NotchCenter

@MainActor
final class NotchGeometryTests: XCTestCase {
    func testActivationFrameIsCenteredUnderNotchAndFlushWithTop() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = NotchLayout(
            notchSize: NSSize(width: 210, height: 32),
            compactSize: NSSize(width: 164, height: 78),
            compactTopOffset: 0
        )

        let activationFrame = NotchGeometry.activationFrame(for: layout, in: screenFrame)

        XCTAssertEqual(activationFrame.width, 210)
        XCTAssertEqual(activationFrame.height, 78)
        XCTAssertEqual(activationFrame.midX, screenFrame.midX)
        XCTAssertEqual(activationFrame.maxY, screenFrame.maxY)
    }

    func testFallbackLayoutForScreenWithoutNotch() {
        // 无刘海屏幕：顶部中央回退尺寸（文档 §6.3）。
        let layout = NotchGeometry.layout(for: nil)

        XCTAssertEqual(layout.notchSize, NotchGeometry.fallbackNotchSize)
        XCTAssertEqual(
            layout.compactSize.width,
            min(NotchGeometry.compactPanelWidth, NotchGeometry.fallbackNotchSize.width - 6)
        )
        XCTAssertEqual(
            layout.compactSize.height,
            NotchGeometry.fallbackNotchSize.height + 44 + 2
        )
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

    func testCompactPanelWidthMatchesThreeSlots() {
        let expected = CGFloat(3) * NotchGeometry.compactSlotSize.width
            + CGFloat(2) * NotchGeometry.compactSlotSpacing
            + NotchGeometry.compactHorizontalPadding * 2
        XCTAssertEqual(NotchGeometry.compactPanelWidth, expected)
    }
}
