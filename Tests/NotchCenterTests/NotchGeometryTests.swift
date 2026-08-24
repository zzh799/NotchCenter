import AppKit
import XCTest
@testable import NotchCenter

@MainActor
final class NotchGeometryTests: XCTestCase {
    func testActivationFrameCoversCompactStripAndFlushWithTop() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = NotchGeometry.layout(for: nil, compactCount: 3)

        let activationFrame = NotchGeometry.activationFrame(for: layout, slotCount: 3, in: screenFrame)

        XCTAssertEqual(activationFrame.width, layout.compactSize(slotCount: 3).width)
        XCTAssertEqual(activationFrame.height, layout.compactSize(slotCount: 3).height)
        XCTAssertEqual(activationFrame.midX, screenFrame.midX)
        XCTAssertEqual(activationFrame.maxY, screenFrame.maxY)
    }

    func testFallbackLayoutForScreenWithoutNotch() {
        // 无刘海屏幕：顶部中央回退尺寸（文档 §6.3）；紧凑区高度即刘海高度带。
        let layout = NotchGeometry.layout(for: nil, compactCount: 2)

        XCTAssertEqual(layout.notchSize, NotchGeometry.fallbackNotchSize)
        XCTAssertEqual(layout.compactHeight, NotchGeometry.fallbackNotchSize.height)
        let strip = layout.compactStrip(slotCount: 2)
        XCTAssertEqual(layout.compactSize(slotCount: 2).width, strip.windowWidth)
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
        // 两面板等宽（按较大一侧实际槽数）：黑色带绕刘海左右对称
        // （3 个图标时左 2 右 1，但两侧面板等宽、带宽一致）。
        let strip = CompactStripLayout(notchWidth: 210, height: 32, slotCount: 3)

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
        // 窗口与黑色带同宽（不再为编辑模式“+”预留右端占位）。
        XCTAssertEqual(strip.windowWidth, strip.rightPanelX + strip.rightPanelWidth)
        XCTAssertEqual(strip.windowWidth, strip.bandWidth)

        // 带体绕刘海的左右边距相等。
        XCTAssertEqual(strip.notchCenterX, strip.windowWidth / 2)
    }

    func testCompactStripAlternatesSidesBalanced() {
        // 左右均衡交替：偶数索引在左、奇数在右（5 个图标 = 左 3 右 2）。
        let strip = CompactStripLayout(notchWidth: 210, height: 32, slotCount: 5)

        XCTAssertEqual(strip.leftSlots, 3)
        XCTAssertEqual(strip.rightSlots, 2)
        XCTAssertEqual(strip.sideSlots, 3)
        XCTAssertEqual(strip.leftPanelWidth, strip.rightPanelWidth)

        XCTAssertLessThan(strip.slotRect(at: 0)!.midX, strip.notchCenterX)
        XCTAssertGreaterThan(strip.slotRect(at: 1)!.midX, strip.notchCenterX)
        XCTAssertLessThan(strip.slotRect(at: 2)!.midX, strip.notchCenterX)
        XCTAssertGreaterThan(strip.slotRect(at: 3)!.midX, strip.notchCenterX)
        XCTAssertLessThan(strip.slotRect(at: 4)!.midX, strip.notchCenterX)

        // 最内一对图标（左列末 = 索引 4 & 右列首 = 索引 1）绕刘海中心镜像对称。
        let innerPair = [strip.slotRect(at: 4)!, strip.slotRect(at: 1)!]
        XCTAssertEqual(
            strip.notchCenterX - innerPair[0].midX,
            innerPair[1].midX - strip.notchCenterX,
            accuracy: 0.5
        )
    }

    func testCompactStripWidthGrowsWithIcons() {
        // 带宽随图标数动态伸缩，且始终与内容匹配：两面板等宽（按较大一侧
        // 槽数），所以宽度成对增长——1↔2 图标同宽（两侧各 1 槽）、
        // 3↔4 同宽（左 2 右 2）、5 再增宽……
        let widths = (1...8).map { count in
            CompactStripLayout(notchWidth: 210, height: 32, slotCount: count).windowWidth
        }
        XCTAssertEqual(widths[0], widths[1], "1 与 2 个图标同宽（左右各 1 槽）")
        XCTAssertLessThan(widths[1], widths[2], "第 3 个图标增宽（左 2 右 1）")
        XCTAssertEqual(widths[2], widths[3], "3 与 4 个图标同宽（左 2 右 2）")
        XCTAssertLessThan(widths[3], widths[4], "第 5 个图标再增宽（左 3 右 2）")

        // 任意数量下面板等宽、刘海中心恒为带宽中心。
        for count in 1...8 {
            let strip = CompactStripLayout(notchWidth: 210, height: 32, slotCount: count)
            XCTAssertEqual(strip.leftPanelWidth, strip.rightPanelWidth)
            XCTAssertEqual(strip.notchCenterX, strip.windowWidth / 2, accuracy: 0.001)
        }
    }

    func testCompactStripSlotRects() {
        let strip = CompactStripLayout(notchWidth: 210, height: 32, slotCount: 3)
        let slot = NotchGeometry.compactSlotSize
        let expectedY: CGFloat = (32 - slot.height) / 2
        let padding = NotchGeometry.compactHorizontalPadding
        let spacing = NotchGeometry.compactSlotSpacing
        let bandLeft = strip.bandLeft

        // 偶数索引在左：索引 0 靠刘海一侧（左列 0）、索引 2 向外（左列 1）。
        XCTAssertEqual(
            strip.slotRect(at: 0),
            CGRect(x: bandLeft + padding, y: expectedY, width: slot.width, height: slot.height)
        )
        XCTAssertEqual(
            strip.slotRect(at: 2),
            CGRect(
                x: bandLeft + padding + slot.width + spacing,
                y: expectedY,
                width: slot.width,
                height: slot.height
            )
        )

        // 奇数索引在右：索引 1 靠刘海一侧（右列 0）。
        XCTAssertEqual(
            strip.slotRect(at: 1),
            CGRect(
                x: bandLeft + strip.rightPanelX + padding,
                y: expectedY,
                width: slot.width,
                height: slot.height
            )
        )

        // 最内一对图标（左列 1 与右列 0）绕刘海中心镜像对称。
        let innerLeftCenter = strip.slotRect(at: 2)!.midX
        let rightCenter = strip.slotRect(at: 1)!.midX
        XCTAssertEqual(
            strip.notchCenterX - innerLeftCenter,
            rightCenter - strip.notchCenterX,
            accuracy: 0.5
        )

        // 越界返回 nil（slotCount = 3 → 索引 3 越界）。
        XCTAssertNil(strip.slotRect(at: -1))
        XCTAssertNil(strip.slotRect(at: 3))
    }
}