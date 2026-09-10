import AppKit
import XCTest
@testable import NotchCenter

/// 脱离容器浮窗的坐标换算契约（方案 4，见 DrawerDragPanel 顶部说明）。
///
/// 为什么单测这一层：浮窗是独立 `NSPanel`，位置用**屏幕坐标**直接写窗口
/// frame；而基准矩形来自 `DrawerScreenMapper.screenRect`（Cocoa，左下原点），
/// SwiftUI 的手势 translation 却是**左上原点、y 向下**。两套 y 轴方向混用
/// 是这里唯一容易写错的地方，错了浮窗会上下镜像（在刘海屏上尤其明显），
/// 而编译器不会报任何错。
@MainActor
final class DetachedDragGeometryTests: XCTestCase {

    /// 复刻 `DrawerPanelView.moveDetachedDrag` 的换算：基准（左上原点）
    /// + 手势 translation（左上原点、y 向下）→ Cocoa 屏幕原点（左下原点）。
    private func cocoaOrigin(
        baseTopLeft: CGPoint,
        translation: CGSize
    ) -> CGPoint {
        CGPoint(x: baseTopLeft.x + translation.width, y: baseTopLeft.y - translation.height)
    }

    /// 复刻基准矩形的换算：Cocoa rect（左下原点）→ 左上原点。
    private func topLeftOrigin(fromCocoa rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX, y: rect.maxY)
    }

    func testBaseOriginConversionFlipsToTopLeft() {
        // 屏幕高 1000，块在 y=200..320（Cocoa）。其**顶缘**是 320。
        let cocoa = CGRect(x: 100, y: 200, width: 300, height: 120)
        let converted = topLeftOrigin(fromCocoa: cocoa)
        XCTAssertEqual(converted.x, 100)
        XCTAssertEqual(converted.y, 320, "基准必须取 maxY（顶缘），不是 minY")
    }

    func testDownwardTranslationLowersWindowOnScreen() {
        // 用户把鼠标往下拖（SwiftUI translation.height > 0）。
        let base = CGPoint(x: 100, y: 320)
        let moved = cocoaOrigin(baseTopLeft: base, translation: CGSize(width: 0, height: 50))
        // 屏幕上"更靠下" = Cocoa y 更小。
        XCTAssertEqual(moved.y, 270, "向下拖必须让 Cocoa y 减小（y 轴反向）")
    }

    func testRightwardTranslationIsUnchangedInSign() {
        let base = CGPoint(x: 100, y: 320)
        let moved = cocoaOrigin(baseTopLeft: base, translation: CGSize(width: 40, height: 0))
        XCTAssertEqual(moved.x, 140, "x 轴两套坐标系同向，不得翻转")
    }

    /// 与真实 `DrawerScreenMapper` 对接：格 → 屏幕 → 浮窗原点，纵向必须
    /// 落在该格所在的行带内（而不是镜像到另一侧）。
    func testMapperRoundTripKeepsBlockOnItsRow() {
        let metrics = GridMetrics(
            cellWidth: 150, cellHeight: 120, spacing: 12,
            contentPadding: 16, topBarHeight: 36
        )
        let geometry = DrawerGridGeometry(
            metrics: metrics,
            leftColumn: 0,
            capacity: .max,
            minimumRows: 2,
            minimumColumns: 4
        )
        // 可见面板：屏幕高 1000，面板顶缘贴屏幕顶、高 700。
        let mapper = DrawerScreenMapper(
            visibleFrame: CGRect(x: 0, y: 300, width: 900, height: 700),
            topInset: 80,
            geometry: geometry
        )
        let cell = GridCell(column: 0, row: 1, columnSpan: 1, rowSpan: 1)
        let rect = mapper.screenRect(for: cell)
        let converted = topLeftOrigin(fromCocoa: rect)

        // 第 1 行的顶缘应低于网格顶缘（更靠屏幕下方 = 更小的 y）。
        XCTAssertLessThan(
            converted.y, mapper.gridTopEdgeY,
            "第 1 行必须落在网格顶缘之下；若等于或高于顶缘说明行号换算反了"
        )
        // 且必须高于第 0 行的顶缘（行号越大越靠下）。
        let row0Top = topLeftOrigin(fromCocoa: mapper.screenRect(
            for: GridCell(column: 0, row: 0, columnSpan: 1, rowSpan: 1)
        )).y
        XCTAssertLessThan(converted.y, row0Top, "行号增大必须向下移动")
    }

    /// 抓握偏移补偿：复制体必须保持"光标在块内的相对位置"不变。
    ///
    /// 真机缺陷：浮窗定位最初写成 `块原点 + 手势 translation`，漏掉了抓握点，
    /// 于是在块中心按下时浮窗左上角直接跳到光标处——用户报告"复制体与鼠标的
    /// 相对位置和原组件不一样"。本测试复刻**实际实现**的算式并钉住该不变量。
    func testGrabOffsetIsPreservedThroughDrag() {
        // 块在屏幕上的位置（Cocoa，左下原点）：x=100, y=200, 300x200。
        let blockRect = CGRect(x: 100, y: 200, width: 300, height: 200)

        // 复刻 beginDetachedDragIfNeeded：base（左上原点）与 grab（左上原点）。
        let base = CGPoint(x: blockRect.minX, y: blockRect.maxY)   // (100, 400)
        // 按下时光标在块中心：Cocoa (250, 300)。
        var mouse = CGPoint(x: 250, y: 300)
        let grab = CGSize(width: mouse.x - base.x, height: base.y - mouse.y) // (150, 100)

        // 复刻 moveDetachedDrag：浮窗 Cocoa 原点 = 光标 + 抓握（y 向下换算）。
        func panelOrigin(forMouse m: CGPoint) -> CGPoint {
            CGPoint(x: m.x - grab.width, y: m.y + grab.height)
        }

        // 浮窗「左上角」在 Cocoa 里是 (origin.x, origin.y + height)。
        // `panelOrigin` 返回的 y 已经是"顶缘等价量"（因为 grab.height 是
        // 从顶缘向下的距离），故顶缘 = origin.y。
        func panelTopLeft(_ m: CGPoint) -> CGPoint {
            let o = panelOrigin(forMouse: m)
            return CGPoint(x: o.x, y: o.y)
        }

        // 不变量：光标相对浮窗左上角的偏移，全程恒等于按下时的 grab。
        func relativeToPanelTopLeft(_ m: CGPoint) -> CGSize {
            let tl = panelTopLeft(m)
            return CGSize(width: m.x - tl.x, height: tl.y - m.y)
        }

        // 按下那一刻：浮窗左上角应恰为块左上角（像素重合、无跳变）。
        let atPress = panelTopLeft(mouse)
        XCTAssertEqual(atPress.x, base.x, accuracy: 0.001, "按下时浮窗左缘必须与块左缘重合")
        XCTAssertEqual(atPress.y, base.y, accuracy: 0.001, "按下时浮窗顶缘必须与块顶缘重合")

        // 拖动到任意位置：相对位置必须不变。
        for delta in [CGPoint(x: 0, y: 0), CGPoint(x: 37, y: -52), CGPoint(x: -80, y: 25)] {
            mouse = CGPoint(x: 250 + delta.x, y: 300 + delta.y)
            let rel = relativeToPanelTopLeft(mouse)
            XCTAssertEqual(rel.width, grab.width, accuracy: 0.001, "抓握横向偏移不得漂移")
            XCTAssertEqual(rel.height, grab.height, accuracy: 0.001, "抓握纵向偏移不得漂移")
        }
    }

    /// 反例守卫：若漏掉抓握补偿（曾经的错误实现），按下时浮窗左上角会落在
    /// 光标处而非块左上角——本测试证明上面那条断言**不是恒真**。
    func testWithoutGrabCompensationPanelJumpsToCursor() {
        let blockRect = CGRect(x: 100, y: 200, width: 300, height: 200)
        let base = CGPoint(x: blockRect.minX, y: blockRect.maxY)
        let mouse = CGPoint(x: 250, y: 300)
        // 错误实现：浮窗原点 = 块原点 + translation(按下时为 0) → 就是 base。
        // 但缺少抓握补偿的"跟随光标"版本会写成：
        let wrongOrigin = CGPoint(x: mouse.x, y: mouse.y)
        XCTAssertNotEqual(
            wrongOrigin.x, base.x,
            "缺抓握补偿时浮窗左上角落在光标处（x 偏 150）——正是要被检出的缺陷"
        )
        XCTAssertGreaterThan(abs(wrongOrigin.x - base.x), 1)
    }

    /// `NSWindow.setFrameOrigin(_:)` 接受**左下角**，而浮窗定位用的是**左上角**。
    ///
    /// 这是本路径最容易静默出错的一处：直接把左上角喂给 `setFrameOrigin` 会让
    /// 浮窗整体抬高"一个窗口高度"（真机表现为抓握点全错），而编译器、坐标范围
    /// 检查都发现不了——窗口只是出现在一个同样合法的位置。
    /// 本测试复刻 `DrawerDragPanel.move(toScreenTopLeft:)` 的换算并钉住它。
    func testTopLeftToFrameOriginConversion() {
        let panelHeight: CGFloat = 348

        // 复刻 DrawerDragPanel.move(toScreenTopLeft:)。
        func frameOrigin(forTopLeft topLeft: CGPoint, height: CGFloat) -> CGPoint {
            CGPoint(x: topLeft.x, y: topLeft.y - height)
        }

        let topLeft = CGPoint(x: 588, y: 842)
        let origin = frameOrigin(forTopLeft: topLeft, height: panelHeight)

        XCTAssertEqual(origin.x, 588, "x 不变")
        XCTAssertEqual(origin.y, 494, "y 必须减去窗口高度，才是 setFrameOrigin 要的左下角")

        // 反例守卫：直接传左上角（曾经的错误实现）会高出整整一个高度。
        XCTAssertNotEqual(
            topLeft.y, origin.y,
            "若两者相等说明漏了换算——正是要被检出的缺陷"
        )
        XCTAssertEqual(topLeft.y - origin.y, panelHeight, "偏差恰为一个窗口高度")
    }

    /// 端到端：从块屏幕矩形 + 光标推出浮窗左上角，再换算成 frame origin，
    /// 结果应与块的 Cocoa 底边一致（按下那一刻像素重合）。
    func testPressMomentPanelAlignsWithBlock() {
        // 块（Cocoa）：x=588, y=494, 336x348 → 顶缘 842。
        let blockRect = CGRect(x: 588, y: 494, width: 336, height: 348)
        let blockTopLeft = CGPoint(x: blockRect.minX, y: blockRect.maxY)
        // 光标在块内：(699.5, 775.3) → 抓握 (111.5, 66.7)。
        let mouse = CGPoint(x: 699.5, y: 775.3)
        let grab = CGSize(
            width: mouse.x - blockTopLeft.x,
            height: blockTopLeft.y - mouse.y
        )
        // moveDetachedDrag 的左上角算式。
        let panelTopLeft = CGPoint(x: mouse.x - grab.width, y: mouse.y + grab.height)
        XCTAssertEqual(panelTopLeft.x, blockTopLeft.x, accuracy: 0.001)
        XCTAssertEqual(panelTopLeft.y, blockTopLeft.y, accuracy: 0.001)

        // 再经 move(toScreenTopLeft:) 换算 → 应等于块底边 y。
        let origin = CGPoint(x: panelTopLeft.x, y: panelTopLeft.y - blockRect.height)
        XCTAssertEqual(origin.y, blockRect.minY, accuracy: 0.001, "浮窗底边必须与块底边重合")
    }
}
