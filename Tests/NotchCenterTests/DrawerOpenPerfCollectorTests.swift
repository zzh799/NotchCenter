import XCTest
@testable import NotchCenter

/// `DrawerOpenPerfCollector` 的会话语义与报告格式回归。
///
/// 为什么要测：它是「抽屉打开慢」的**唯一分解判据**——宿主侧重建、SwiftUI
/// 挂载/布局、固定淡入延迟三段各占多少毫秒，全靠它区分；优化方案（减负 /
/// 常驻挂载 / 两段式展开）怎么选也靠它给的数。会话边界或埋点语义一旦算错
/// （重复埋点覆盖首个读数、看门狗把样本吞掉、内容规模串到下一次展开），
/// 读数会静默失真——探针自己不会报错，只会给出一个看起来合理的错数。
@MainActor
final class DrawerOpenPerfCollectorTests: XCTestCase {

    /// 建一个强制开启、输出收进数组的收集器（不污染测试日志）。
    private func makeCollector(
        watchdogSeconds: Double = 5
    ) -> (collector: DrawerOpenPerfCollector, lines: () -> [String]) {
        let box = LineBox()
        let collector = DrawerOpenPerfCollector(
            forceEnabled: true,
            watchdogSeconds: watchdogSeconds,
            log: { box.append($0) }
        )
        return (collector, { box.lines })
    }

    /// 输出行的可变盒子（`log` 是逃逸闭包，捕获 `var` 数组不允许）。
    private final class LineBox: @unchecked Sendable {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    // MARK: 会话生命周期

    func testFullOpenRecordsOneCompleteSample() throws {
        let (collector, lines) = makeCollector()
        collector.begin()
        collector.mark(.rebuilt)
        collector.mark(.revealed)
        collector.mark(.inserted)
        collector.mark(.laidOut)
        collector.mark(.visible)

        XCTAssertEqual(collector.samples.count, 1, "一次展开 = 一条样本")
        let sample = try XCTUnwrap(collector.samples.first)
        XCTAssertTrue(sample.isComplete, "五段齐全即完整样本")
        // 阶段按时间顺序落，读数必然非降。
        XCTAssertLessThanOrEqual(sample.marks[.enter] ?? -1, sample.marks[.rebuilt] ?? -1)
        XCTAssertLessThanOrEqual(sample.marks[.rebuilt] ?? -1, sample.marks[.visible] ?? -1)
        XCTAssertEqual(lines().count, 1, "收尾打印且只打印一次")
        XCTAssertTrue(lines()[0].hasPrefix("[drawer-perf] open#1"), "实际: \(lines()[0])")
    }

    func testRepeatedMarkKeepsFirstReading() async throws {
        let (collector, _) = makeCollector()
        collector.begin()
        collector.mark(.rebuilt)
        let first = try XCTUnwrap(collector.sessionMarkForTesting(.rebuilt))
        try await Task.sleep(for: .milliseconds(30))
        collector.mark(.rebuilt)
        let second = try XCTUnwrap(collector.sessionMarkForTesting(.rebuilt))
        XCTAssertEqual(first, second, "重复埋点不得覆盖首个读数（否则读数被后续噪声拉长）")
    }

    func testNewOpenSupersedesStaleSessionWithoutLosingSample() {
        let (collector, lines) = makeCollector()
        collector.begin()
        collector.mark(.rebuilt)
        // 上一次没收尾就来了新的展开（例如快速连点）：旧样本按未完成收尾，
        // 不能丢——丢样本会让"某次展开根本没走完"这个信号消失。
        collector.begin()
        XCTAssertEqual(collector.samples.count, 1)
        XCTAssertEqual(collector.samples[0].isComplete, false)
        XCTAssertTrue(lines()[0].contains("incomplete(superseded)"), "实际: \(lines()[0])")
    }

    func testWatchdogFinishesIncompleteSampleInsteadOfHanging() async throws {
        let (collector, lines) = makeCollector(watchdogSeconds: 0.05)
        collector.begin()
        collector.mark(.rebuilt)
        // 内容淡入段永不到达（真出现即"卡在展开途中"）：看门狗必须兜底收尾。
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(collector.samples.count, 1)
        XCTAssertEqual(collector.samples[0].isComplete, false)
        XCTAssertTrue(lines()[0].contains("incomplete(watchdog)"), "实际: \(lines()[0])")
    }

    // MARK: 内容规模与缓存计数

    func testContentSizeAndViewCacheCountsLandInSample() {
        let (collector, _) = makeCollector()
        collector.begin()
        collector.noteContent(page: 2, pageCount: 4, drawerBlocks: 14, compactSlots: 6)
        collector.noteMakeView()
        collector.noteMakeView()
        collector.noteCacheHit()
        collector.noteCacheHit()
        collector.noteCacheHit()
        collector.mark(.visible)

        let sample = collector.samples[0]
        XCTAssertEqual(sample.page, 2)
        XCTAssertEqual(sample.pageCount, 4)
        XCTAssertEqual(sample.drawerBlocks, 14)
        XCTAssertEqual(sample.compactSlots, 6)
        XCTAssertEqual(sample.makeViewCalls, 2, "未命中次数 = 真正重挂插件视图的块数")
        XCTAssertEqual(sample.cacheHits, 3)
    }

    func testHostLayoutOnlyCountsWhileExpanded() {
        let (collector, _) = makeCollector()
        collector.begin()
        collector.mark(.revealed)
        collector.noteHostLayout(isExpanded: false)   // 收起态的布局不算
        XCTAssertNil(collector.sessionMarkForTesting(.laidOut))
        collector.noteHostLayout(isExpanded: true)
        XCTAssertNotNil(collector.sessionMarkForTesting(.laidOut))
    }

    func testDisabledCollectorIsInert() {
        // 未注入 forceEnabled、环境变量未开：一切埋点必须零副作用
        // （生产路径的调用点不做开关判断，靠这里兜住）。
        guard !DrawerOpenPerfLog.enabled else { return }
        let collector = DrawerOpenPerfCollector()
        collector.begin()
        collector.mark(.rebuilt)
        collector.noteMakeView()
        collector.noteContent(page: 1, pageCount: 1, drawerBlocks: 3, compactSlots: 3)
        XCTAssertTrue(collector.samples.isEmpty)
        XCTAssertNil(collector.sessionMarkForTesting(.rebuilt))
    }

    // MARK: 报告

    func testLineReadsMountDurationFromRevealToLayout() {
        let sample = DrawerOpenPerfCollector.Sample(
            label: "r2p0",
            page: 0,
            pageCount: 2,
            drawerBlocks: 12,
            compactSlots: 5,
            makeViewCalls: 1,
            cacheHits: 11,
            marks: [.enter: 0, .rebuilt: 4, .revealed: 6, .inserted: 20, .laidOut: 34, .visible: 420]
        )
        let line = DrawerOpenPerfCollector.line(for: sample, index: 3, reason: nil)
        XCTAssertTrue(line.contains("open#3"), line)
        XCTAssertTrue(line.contains("[r2p0]"), line)
        XCTAssertTrue(line.contains("blocks=12"), line)
        XCTAssertTrue(line.contains("makeView=1 cache=11"), line)
        XCTAssertTrue(line.contains("mount=28.0ms"), "mount = laidOut − revealed = 28ms；实际: \(line)")
        XCTAssertTrue(line.contains("visible=420.0ms"), line)
        XCTAssertFalse(line.contains("incomplete"), line)
    }

    func testReportGroupsSamplesByPage() {
        let (collector, _) = makeCollector()
        func open(page: Int, blocks: Int, mount: Double, visible: Double) {
            collector.begin()
            collector.noteContent(page: page, pageCount: 2, drawerBlocks: blocks, compactSlots: 4)
            // 全程注入固定读数：mount 段 = revealed→laidOut 的差，断言才确定。
            collector.markAtForTesting(.rebuilt, milliseconds: 4)
            collector.markAtForTesting(.revealed, milliseconds: 6)
            collector.markAtForTesting(.inserted, milliseconds: 20)
            collector.markAtForTesting(.laidOut, milliseconds: 6 + mount)
            collector.markAtForTesting(.visible, milliseconds: visible)
        }
        open(page: 0, blocks: 6, mount: 12, visible: 400)
        open(page: 0, blocks: 6, mount: 18, visible: 410)
        open(page: 1, blocks: 20, mount: 44, visible: 700)

        let report = collector.report()
        XCTAssertTrue(report.contains("page  blocks"), report)
        // 两页 → 两行数据行 + 一行合计。
        XCTAssertTrue(report.contains("0     6"), report)
        XCTAssertTrue(report.contains("1     20"), report)
        XCTAssertTrue(report.contains("合计：3 次展开"), report)
        XCTAssertTrue(report.contains("未完成 0 次"), report)
        XCTAssertTrue(report.contains("12.0 / 18.0 / 18.0"), "页内 mount 最小/中位/最大；实际: \(report)")
    }
}
