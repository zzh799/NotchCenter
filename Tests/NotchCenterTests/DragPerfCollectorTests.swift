import XCTest
@testable import NotchCenter

/// `DragPerfCollector` 的会话语义回归。
///
/// 为什么要测：探针是拖动跟手问题**唯一可对照的判据**——它已证伪三个候选
/// 根因（几何自反馈回路、左扩窗口动画、推挤 spring 逐帧重启）。若会话边界
/// 算错（把拖动前的空闲求值也算进去、或松手后不清零），比值会被稀释或串味，
/// 读数直接失去意义，而探针本身不会报任何错。
@MainActor
final class DragPerfCollectorTests: XCTestCase {

    func testIdleBodyEvaluationsAreNotCounted() {
        let collector = DragPerfCollector()
        // 拖动前的挂载/空闲期求值：不属于任何会话，不得计入。
        for _ in 0..<50 { collector.noteBody() }
        collector.beginEvent(label: "block")
        collector.noteBody()
        collector.endEvent(startedAt: Date().timeIntervalSince1970)
        let summary = collector.finish()
        XCTAssertNotNil(summary)
        XCTAssertTrue(
            summary!.contains("body=1"),
            "空闲期求值必须被排除，否则比值被稀释；实际: \(summary!)"
        )
    }

    func testPerEventRatioIsReadable() {
        let collector = DragPerfCollector()
        // 若某次拖动一个手势事件引发 8 次 body 求值，比值必须能读出来
        // （实测基线恒为 ≈3，显著偏离即负载性瓶颈的信号）。
        for _ in 0..<4 {
            collector.beginEvent(label: "page")
            for _ in 0..<8 { collector.noteBody() }
        }
        let summary = collector.finish()
        XCTAssertTrue(
            summary!.contains("bodyPerEvent=8.00"),
            "每事件求值次数必须能从比值读出；实际: \(summary!)"
        )
    }

    func testHealthyRatioIsAboutOne() {
        let collector = DragPerfCollector()
        for _ in 0..<4 {
            collector.beginEvent(label: "page")
            collector.noteBody()
        }
        let summary = collector.finish()
        XCTAssertTrue(
            summary!.contains("bodyPerEvent=1.00"),
            "每事件一次求值时比值应为 1.00；实际: \(summary!)"
        )
    }

    func testSecondSessionStartsFromZero() {
        let collector = DragPerfCollector()
        for _ in 0..<5 {
            collector.beginEvent(label: "page")
            collector.noteBody()
        }
        _ = collector.finish()
        // 第二次拖动必须从零起算，不继承上一次的累计值。
        collector.beginEvent(label: "page")
        collector.noteBody()
        let summary = collector.finish()
        XCTAssertTrue(
            summary!.contains("events=1") && summary!.contains("body=1"),
            "会话必须隔离，否则读数串味；实际: \(summary!)"
        )
    }

    func testFinishWithoutGestureYieldsNothing() {
        let collector = DragPerfCollector()
        XCTAssertNil(collector.finish(), "无手势的 finish 不应打印噪声日志")
    }

    func testGapStatsTrackEventSpacing() {
        let collector = DragPerfCollector()
        collector.beginEvent(label: "page")
        Thread.sleep(forTimeInterval: 0.03)
        collector.beginEvent(label: "page")
        let summary = collector.finish()
        XCTAssertTrue(summary!.contains("events=2"), "实际: \(summary!)")
        XCTAssertTrue(
            summary!.contains("gapMax=3") || summary!.contains("gapMax=2"),
            "两次事件间隔约 30ms，gapMax 应落在该量级；实际: \(summary!)"
        )
    }
}
