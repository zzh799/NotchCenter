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
        // 窗口与带同宽（bandLeft == 0）：槽位横坐标从窗口左缘起算。

        // 偶数索引在左：索引 0 靠刘海一侧（左列 0）、索引 2 向外（左列 1）。
        XCTAssertEqual(
            strip.slotRect(at: 0),
            CGRect(x: padding, y: expectedY, width: slot.width, height: slot.height)
        )
        XCTAssertEqual(
            strip.slotRect(at: 2),
            CGRect(
                x: padding + slot.width + spacing,
                y: expectedY,
                width: slot.width,
                height: slot.height
            )
        )

        // 奇数索引在右：索引 1 靠刘海一侧（右列 0）。
        XCTAssertEqual(
            strip.slotRect(at: 1),
            CGRect(
                x: strip.rightPanelX + padding,
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

    // MARK: 活动摘要带宽（Agent Note 2026-09-03-compact-area-activity-summary）

    func testSummaryBandKeepsPanelsEqualAndNotchCentered() {
        // 摘要芯片带宽计入两面板（取两侧较大值）：任一侧有摘要，面板仍然
        // 等宽、刘海恒为带宽中心（无摘要一侧的余量落在面板外端）。
        let gap = NotchGeometry.summaryIconGap
        let iconOnly = CompactStripLayout(notchWidth: 210, height: 32, slotCount: 3)
        let leftOnly = CompactStripLayout(
            notchWidth: 210, height: 32, slotCount: 3, leftSummaryWidth: 90
        )
        let rightOnly = CompactStripLayout(
            notchWidth: 210, height: 32, slotCount: 3, rightSummaryWidth: 60
        )
        let both = CompactStripLayout(
            notchWidth: 210, height: 32, slotCount: 3,
            leftSummaryWidth: 90, rightSummaryWidth: 60
        )

        for strip in [leftOnly, rightOnly, both] {
            XCTAssertEqual(strip.leftPanelWidth, strip.rightPanelWidth)
            XCTAssertEqual(strip.notchCenterX, strip.windowWidth / 2, accuracy: 0.001)
        }
        // 左侧 90 芯片 → sideSummaryBand = 90 + gap；两面板各加一份。
        XCTAssertEqual(leftOnly.windowWidth - iconOnly.windowWidth, 2 * (90 + gap), accuracy: 0.001)
        // 两侧都在时取较大侧（90 + gap），不是两侧之和。
        XCTAssertEqual(both.windowWidth - iconOnly.windowWidth, 2 * (90 + gap), accuracy: 0.001)
    }

    func testSummaryChipRectsFlankNotchInsidePanels() {
        let padding = NotchGeometry.compactHorizontalPadding
        let gap = NotchGeometry.summaryIconGap
        let strip = CompactStripLayout(
            notchWidth: 210, height: 32, slotCount: 3,
            leftSummaryWidth: 90, rightSummaryWidth: 60
        )

        // 芯片贴各面板靠刘海一端（内侧），无摘要侧返回 nil。
        let leftChip = strip.leftSummaryRect
        let rightChip = strip.rightSummaryRect
        XCTAssertNotNil(leftChip)
        XCTAssertNotNil(rightChip)
        XCTAssertEqual(leftChip!.width, 90)
        XCTAssertEqual(rightChip!.width, 60)
        // 芯片高度随紧凑带自适应（夹在上下留白内、上下对称）。
        XCTAssertEqual(leftChip!.midY, rightChip!.midY)
        XCTAssertEqual(leftChip!.midY, strip.height / 2)

        // 芯片与同侧最内图标之间恰好一个 summaryIconGap。
        let innerLeftIcon = strip.slotRect(at: 2)! // 左列 1（靠刘海一侧的左图标）
        let innerRightIcon = strip.slotRect(at: 1)! // 右列 0（靠刘海一侧的右图标）
        XCTAssertEqual(leftChip!.minX - innerLeftIcon.maxX, gap, accuracy: 0.001)
        XCTAssertEqual(innerRightIcon.minX - rightChip!.maxX, gap, accuracy: 0.001)
        // 芯片不出面板：左芯片右缘 ≤ 左面板内缘（留 padding）、右芯片在右面板内。
        XCTAssertLessThanOrEqual(leftChip!.maxX, strip.leftPanelWidth)
        XCTAssertGreaterThanOrEqual(rightChip!.minX, strip.rightPanelX)
        // 面板外侧仍留 padding：芯片/图标不与面板外缘贴合。
        XCTAssertEqual(leftChip!.maxX, strip.leftPanelWidth - padding, accuracy: 0.001)
    }

    func testSummaryBandShiftsIconsOnlyOnChipSide() {
        // 右侧有摘要时右列图标整体外移：面板等宽化增量（sideSummaryBand，
        // 右面板随左侧面板一起右移） + 自身芯片带（rightSummaryBand）；
        // 左列图标不移动（左芯片占用的是面板内侧新增带宽）。
        let iconOnly = CompactStripLayout(notchWidth: 210, height: 32, slotCount: 3)
        let withRight = CompactStripLayout(
            notchWidth: 210, height: 32, slotCount: 3, rightSummaryWidth: 60
        )
        XCTAssertEqual(
            withRight.slotRect(at: 1)!.minX - iconOnly.slotRect(at: 1)!.minX,
            withRight.sideSummaryBand + withRight.rightSummaryBand,
            accuracy: 0.001
        )
        XCTAssertEqual(withRight.slotRect(at: 0)!.minX, iconOnly.slotRect(at: 0)!.minX)

        // 左侧芯片只在面板内侧新增带宽：左图标槽位与纯图标几何一致。
        let withLeft = CompactStripLayout(
            notchWidth: 210, height: 32, slotCount: 3, leftSummaryWidth: 90
        )
        XCTAssertEqual(withLeft.slotRect(at: 0)!.minX, iconOnly.slotRect(at: 0)!.minX)
        XCTAssertEqual(withLeft.slotRect(at: 2)!.minX, iconOnly.slotRect(at: 2)!.minX)
    }

    func testActivationFrameIncludesSummaryBand() {
        // 热区 frame 透传摘要宽度：宽度 = 含芯片带宽的紧凑尺寸、贴屏幕顶、
        // 绕屏幕中线居中（控制器据此重摆热区窗口，窗口 frame 不参与动画）。
        let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = NotchGeometry.layout(for: nil, compactCount: 3)
        let frame = NotchGeometry.activationFrame(
            for: layout,
            slotCount: 3,
            leftSummaryWidth: 90,
            rightSummaryWidth: 60,
            in: screenFrame
        )
        XCTAssertEqual(
            frame.width,
            layout.compactSize(
                slotCount: 3,
                leftSummaryWidth: 90,
                rightSummaryWidth: 60
            ).width
        )
        XCTAssertEqual(frame.midX, screenFrame.midX)
        XCTAssertEqual(frame.maxY, screenFrame.maxY)
    }

    // MARK: 设置面板摆位（抽屉下方优先 / 屏幕底部兜底）→ 抽屉限高

    /// 982 高屏幕（无 Dock）、刘海 32；窗口 frame 高度 = 内容 425 + 28 titlebar。
    private enum SettingsFixture {
        static let screenMaxY: CGFloat = 982
        static let noDockMinY: CGFloat = 0
        static let dockMinY: CGFloat = 70
        static let compactHeight: CGFloat = 32
        static let bandHeight: CGFloat = SettingsWindowMetrics.windowFrameHeight

        /// 抽屉可见底缘：顶缘钉死屏幕顶，往下让出紧凑带与内容高。
        static func drawerBottomY(contentHeight: CGFloat) -> CGFloat {
            NotchGeometry.drawerVisibleBottomY(
                screenMaxY: screenMaxY,
                compactHeight: compactHeight,
                drawerContentHeight: contentHeight
            )
        }
    }

    func testDockedSettingsTopYIncludesInsetAndBandHeight() {
        // 停靠顶缘 = visibleFrame 底缘 + 底部间距 + 窗口 frame 高度
        // （内容高度 + 28 透明 titlebar，调试页改高后由调用方现算传入）。
        let bandHeight = SettingsFixture.bandHeight
        let topY = NotchGeometry.dockedSettingsTopY(visibleMinY: 70, bandHeight: bandHeight)
        XCTAssertEqual(topY, 70 + SettingsWindowMetrics.bottomInset + bandHeight)
        XCTAssertEqual(
            SettingsWindowMetrics.windowFrameHeight,
            SettingsWindowMetrics.height + SettingsWindowMetrics.titleBarHeight
        )
    }

    func testSettingsPlacementPrefersBelowDrawerWhenSpaceSuffices() {
        // 抽屉内容 200：底缘 982 - 32 - 200 = 750，面板顶缘贴其下 8pt →
        // 底缘 742 - 453 = 289，仍在 visibleFrame（0）底缘间距之上 → 贴抽屉。
        let placement = NotchGeometry.settingsPlacement(
            visibleMinY: SettingsFixture.noDockMinY,
            drawerBottomY: SettingsFixture.drawerBottomY(contentHeight: 200),
            bandHeight: SettingsFixture.bandHeight
        )
        XCTAssertEqual(placement.mode, .belowDrawer)
        XCTAssertEqual(placement.frameTopY, 750 - SettingsWindowMetrics.gapFromSettings)
        XCTAssertGreaterThan(
            placement.frameOriginY(bandHeight: SettingsFixture.bandHeight),
            SettingsFixture.noDockMinY + SettingsWindowMetrics.bottomInset
        )
    }

    func testSettingsPlacementFallsBackToScreenBottomWhenSpaceIsTight() {
        // 抽屉内容 600：底缘 350，面板塞不进 350 与屏幕底之间 → 退回底部停靠
        // （抽屉再由限高让位，见 `testSettingsCappedDrawerHeight...`）。
        let placement = NotchGeometry.settingsPlacement(
            visibleMinY: SettingsFixture.noDockMinY,
            drawerBottomY: SettingsFixture.drawerBottomY(contentHeight: 600),
            bandHeight: SettingsFixture.bandHeight
        )
        XCTAssertEqual(placement.mode, .screenBottom)
        XCTAssertEqual(
            placement.frameTopY,
            NotchGeometry.dockedSettingsTopY(
                visibleMinY: SettingsFixture.noDockMinY,
                bandHeight: SettingsFixture.bandHeight
            )
        )
    }

    func testSettingsPlacementAccountsForDock() {
        // 同一抽屉高度（内容 400）在有 Dock 的屏上可贴抽屉，Dock 抬高
        // visibleFrame 底缘后仍以「窗口完整落在抽屉下方」为准。
        let noDock = NotchGeometry.settingsPlacement(
            visibleMinY: SettingsFixture.noDockMinY,
            drawerBottomY: SettingsFixture.drawerBottomY(contentHeight: 400),
            bandHeight: SettingsFixture.bandHeight
        )
        XCTAssertEqual(noDock.mode, .belowDrawer)

        // 抽屉几乎占满屏幕（内容 900）：两种屏都只能退到底部，Dock 让顶缘更高。
        let tallDrawerBottom = SettingsFixture.drawerBottomY(contentHeight: 900)
        let withDock = NotchGeometry.settingsPlacement(
            visibleMinY: SettingsFixture.dockMinY,
            drawerBottomY: tallDrawerBottom,
            bandHeight: SettingsFixture.bandHeight
        )
        XCTAssertEqual(withDock.mode, .screenBottom)
        XCTAssertEqual(
            withDock.frameTopY,
            NotchGeometry.dockedSettingsTopY(
                visibleMinY: SettingsFixture.dockMinY,
                bandHeight: SettingsFixture.bandHeight
            )
        )
    }

    func testSettingsCappedDrawerHeightIsIdentityWhenDockedBelowDrawer() {
        // 贴抽屉下方时「限高」必须等于裁定时的抽屉高度（空操作）：抽屉在
        // 设置页打开期间长高应当触发重裁摆位，而不是被悄悄截断。
        let contentHeight: CGFloat = 200
        let placement = NotchGeometry.settingsPlacement(
            visibleMinY: SettingsFixture.noDockMinY,
            drawerBottomY: SettingsFixture.drawerBottomY(contentHeight: contentHeight),
            bandHeight: SettingsFixture.bandHeight
        )
        let capped = NotchGeometry.settingsCappedDrawerHeight(
            screenMaxY: SettingsFixture.screenMaxY,
            settingsTopY: placement.frameTopY,
            compactHeight: SettingsFixture.compactHeight
        )
        XCTAssertEqual(capped, contentHeight, accuracy: 0.001)
    }

    func testSettingsCappedDrawerHeightKeepsGapAboveSettingsPanel() {
        // 底部停靠（抽屉放不下）：抽屉可见底缘 ≥ 面板顶缘 + 间距。
        let dockedTopY = NotchGeometry.dockedSettingsTopY(
            visibleMinY: SettingsFixture.noDockMinY,
            bandHeight: SettingsFixture.bandHeight
        )
        let capped = NotchGeometry.settingsCappedDrawerHeight(
            screenMaxY: SettingsFixture.screenMaxY,
            settingsTopY: dockedTopY,
            compactHeight: SettingsFixture.compactHeight
        )
        XCTAssertEqual(
            capped,
            SettingsFixture.screenMaxY - dockedTopY
                - SettingsWindowMetrics.gapFromSettings - SettingsFixture.compactHeight
        )
        // 让位后的抽屉底缘正好落在面板顶缘之上一个间距。
        XCTAssertEqual(
            SettingsFixture.drawerBottomY(contentHeight: capped),
            dockedTopY + SettingsWindowMetrics.gapFromSettings,
            accuracy: 0.001
        )
        // 切换摆位的临界高度：自然高度超过该上限就只能退到底部停靠。
        let atLimit = NotchGeometry.settingsPlacement(
            visibleMinY: SettingsFixture.noDockMinY,
            drawerBottomY: SettingsFixture.drawerBottomY(contentHeight: capped),
            bandHeight: SettingsFixture.bandHeight
        )
        XCTAssertEqual(atLimit.mode, .belowDrawer)
        let overLimit = NotchGeometry.settingsPlacement(
            visibleMinY: SettingsFixture.noDockMinY,
            drawerBottomY: SettingsFixture.drawerBottomY(contentHeight: capped + 1),
            bandHeight: SettingsFixture.bandHeight
        )
        XCTAssertEqual(overLimit.mode, .screenBottom)
    }

    func testSettingsCappedDrawerHeightShrinksOnShortScreens() {
        // 有 Dock 的屏幕：visibleMinY 抬高面板顶缘，限高随之收紧。
        let noDockTopY = NotchGeometry.dockedSettingsTopY(
            visibleMinY: SettingsFixture.noDockMinY,
            bandHeight: SettingsFixture.bandHeight
        )
        let dockTopY = NotchGeometry.dockedSettingsTopY(
            visibleMinY: SettingsFixture.dockMinY,
            bandHeight: SettingsFixture.bandHeight
        )
        let noDock = NotchGeometry.settingsCappedDrawerHeight(
            screenMaxY: SettingsFixture.screenMaxY,
            settingsTopY: noDockTopY,
            compactHeight: SettingsFixture.compactHeight
        )
        let withDock = NotchGeometry.settingsCappedDrawerHeight(
            screenMaxY: SettingsFixture.screenMaxY,
            settingsTopY: dockTopY,
            compactHeight: SettingsFixture.compactHeight
        )
        XCTAssertEqual(withDock, noDock - SettingsFixture.dockMinY, accuracy: 0.001)

        // 极端矮屏返回值 ≤ 0：调用方据此整体放弃限高（允许重叠），不得塌成 0。
        let tiny = NotchGeometry.settingsCappedDrawerHeight(
            screenMaxY: 500,
            settingsTopY: noDockTopY,
            compactHeight: SettingsFixture.compactHeight
        )
        XCTAssertLessThanOrEqual(tiny, 0)
    }
}
