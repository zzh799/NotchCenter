import CoreGraphics
import NotchCenterKit
import Testing

@testable import RemindersPlugin

// MARK: - 三态版式与探针几何回归
//
// 打包期门禁（`BlockSizeVerifier`）**只用 `minSize` 跑一次**，而 `minSize`
// （150×150）恒落在窄态——宽态/大态的探针在门禁里永远不会被走到。这是真实的
// 门禁盲区（见决策记录的 Consequences），所以三态几何必须在这里显式覆盖。
//
// 全部为纯几何断言：不渲染 SwiftUI、不触碰 EventKit、不需要 AppKit 运行环境。

struct RemindersMetricsTests {
    /// 覆盖三态与边界的关键尺寸。150×150 是三档声明里的 min（门禁实际取值）。
    /// 336×162 / 336×336 是当前网格（cell 75×75、间距 12）下的 4×2 与 4×4 实况：
    /// 断点下调到 300 就是为了把 4×4 从宽态捞进大态（见决策记录 D1）。
    private static let sizes: [CGSize] = [
        CGSize(width: 150, height: 150),
        CGSize(width: 150, height: 240),
        CGSize(width: 300, height: 240),
        CGSize(width: 450, height: 240),
        CGSize(width: 336, height: 162),
        CGSize(width: 336, height: 249),
        CGSize(width: 336, height: 336),
        CGSize(width: 300, height: 360),
        CGSize(width: 600, height: 480),
        CGSize(width: 900, height: 600),
    ]

    @Test func breakpointsUseBothAxes() {
        // 窄态只看宽度：宽度不足时再高也还是窄态。
        #expect(RemindersMetrics.state(for: CGSize(width: 150, height: 150)) == .narrow)
        #expect(RemindersMetrics.state(for: CGSize(width: 299, height: 600)) == .narrow)
        // 宽够但高不足 → 宽态。
        // 宽够但高不足 → 宽态（高度门槛 300：4×3 = 336×249 仍属横扁卡）。
        #expect(RemindersMetrics.state(for: CGSize(width: 300, height: 240)) == .wide)
        #expect(RemindersMetrics.state(for: CGSize(width: 336, height: 249)) == .wide)
        #expect(RemindersMetrics.state(for: CGSize(width: 900, height: 299)) == .wide)
        // 宽高都够 → 大态。4×4（336×336）必须落进来：这是断点下调的全部理由。
        #expect(RemindersMetrics.state(for: CGSize(width: 336, height: 336)) == .large)
        #expect(RemindersMetrics.state(for: CGSize(width: 300, height: 300)) == .large)
        #expect(RemindersMetrics.state(for: CGSize(width: 900, height: 600)) == .large)
    }

    /// 大态头部是「计数在上 + 名称在下」的两行堆叠：内容盒要装得下 31pt + 16pt
    /// 两行，且区带底边挂着头部线（区带内没有下内边距）。
    @Test func largeHeaderBandHoldsTwoLinesAndRule() {
        let layout = RemindersMetrics.layout(for: CGSize(width: 336, height: 336))
        #expect(layout.state == .large)
        #expect(layout.topBand.height == 82)
        #expect(layout.headerRuleHeight == 2)
        #expect(layout.topContentRect.height == 54)
        #expect(layout.topContentRect.minX == 16)
        #expect(layout.topContentRect.minY == 16)
        // 行列表紧贴头部线起排，大态行距比其余态高一档。
        #expect(layout.listBand.minY == layout.topBand.maxY)
        #expect(layout.rowHeight == 36.5)
    }

    /// 大态行间分隔线走虚线，且左端缩进到标题起点（避开勾选圈）。
    @Test func largeRowDividerIsDashedAndInsetToTitle() {
        let layout = RemindersMetrics.layout(for: CGSize(width: 336, height: 336))
        #expect(layout.rowDividerDashed)
        #expect(layout.dividerLeadingInset == layout.checklistDiameter + layout.rowSpacing)
        // 其余态不变：仍是实线、不额外缩进。
        let wide = RemindersMetrics.layout(for: CGSize(width: 336, height: 162))
        #expect(wide.state == .wide)
        #expect(!wide.rowDividerDashed)
        #expect(wide.dividerLeadingInset == 0)
    }

    /// 三档声明必须与三态对上：min 落窄态、recommended 落大态、max 落大态。
    /// 这条锁的是"改断点时忘了同步尺寸声明"这类回归。
    @Test func declaredSizesLandInExpectedStates() {
        #expect(RemindersMetrics.state(for: CGSize(width: 150, height: 150)) == .narrow)
        #expect(RemindersMetrics.state(for: CGSize(width: 300, height: 360)) == .large)
        #expect(RemindersMetrics.state(for: CGSize(width: 900, height: 600)) == .large)
    }

    /// 三态在各自尺寸下探针都零违规（不越界、不互叠）。
    @Test(arguments: RemindersMetricsTests.sizes)
    func probesHaveNoViolations(size: CGSize) {
        let probes = RemindersMetrics.probes(for: size)
        #expect(!probes.isEmpty)
        let violations = BlockSizeVerifier.violations(probes: probes, contentSize: size)
        #expect(violations.isEmpty, "\(size) 探针违规：\(violations)")
    }

    /// 探针必须由版式同源推导：id 前缀带状态名，且矩形与版式区带逐一相等。
    /// footer 区带已随宽态头部上移删除（2026-09-20-reminders-wide-footer-to-top），
    /// 三态统一只剩 top + list 两个探针。
    @Test(arguments: RemindersMetricsTests.sizes)
    func probesMirrorLayoutBands(size: CGSize) {
        let layout = RemindersMetrics.layout(for: size)
        let probes = RemindersMetrics.probes(for: size)
        #expect(probes.map(\.id) == expectedProbeIDs(for: layout.state))
        let byID = Dictionary(uniqueKeysWithValues: probes.map { ($0.id, $0.rect) })
        #expect(byID["reminders.\(layout.state.rawValue).top"] == layout.topBand)
        #expect(byID["reminders.\(layout.state.rawValue).list"] == layout.listBand)
        #expect(!probes.contains { $0.id.hasSuffix(".footer") })
    }

    private func expectedProbeIDs(for state: RemindersLayoutState) -> [String] {
        ["reminders.\(state.rawValue).top", "reminders.\(state.rawValue).list"]
    }

    /// 区带纵向首尾相接、合起来正好是块高，横向撑满。区带之间有缝或重叠都会让
    /// 探针判定与实际渲染错位。三态都只剩 top + list，list 底边必须直达块底
    /// （宽态 footer 上移后正是靠这条锁住"列表不再被页脚截断"）。
    @Test(arguments: RemindersMetricsTests.sizes)
    func bandsTileTheWholeBlock(size: CGSize) {
        let layout = RemindersMetrics.layout(for: size)
        let bands = [layout.topBand, layout.listBand]

        #expect(bands[0].minY == 0)
        for (earlier, later) in zip(bands, bands.dropFirst()) {
            #expect(earlier.maxY == later.minY, "区带之间有缝或重叠：\(earlier) → \(later)")
        }
        #expect(bands.last?.maxY == size.height)
        #expect(bands.allSatisfy { $0.minX == 0 && $0.maxX == size.width })
    }

    /// 窄态不画行分隔线、宽态与大态画——对齐参考截图的三张卡。
    @Test func dividerVisibilityFollowsState() {
        #expect(!RemindersMetrics.layout(for: CGSize(width: 150, height: 150)).showsRowDividers)
        #expect(RemindersMetrics.layout(for: CGSize(width: 300, height: 240)).showsRowDividers)
        #expect(RemindersMetrics.layout(for: CGSize(width: 300, height: 360)).showsRowDividers)
    }

    /// 最小尺寸（门禁取值）下窄态至少要能看见 3 行——否则这个块放不下任何内容。
    @Test func minimumSizeStillShowsUsableRowCount() {
        let layout = RemindersMetrics.layout(for: CGSize(width: 150, height: 150))
        #expect(layout.visibleRowCount >= 3)
    }

    /// 顶部内容盒必须完整落在顶部区带内、左右内边距对称（大态 16，其余 10）。
    /// 内容盒是头部内容的可见边界：越出区带会被相邻区带压掉，不对称则说明
    /// 又混进了"为某个悬浮控件让位"的隐形预留——块内角标已于 2026-09-21 删除
    /// （决策 `2026-09-21-reminders-source-into-settings`），这里把它锁住。
    @Test(arguments: RemindersMetricsTests.sizes)
    func topContentRectSitsInsideTopBand(size: CGSize) {
        let layout = RemindersMetrics.layout(for: size)
        let inset = RemindersMetrics.padding(for: layout.state)
        #expect(layout.topBand.contains(layout.topContentRect), "\(size) 内容盒越出顶部区带")
        #expect(layout.topContentRect.minX == inset)
        #expect(layout.topBand.maxX - layout.topContentRect.maxX == inset)
    }

    /// 宽态顶行装下徽章与「大计数 + 名称」同盒：区带高 48、内容盒高 28，
    /// 列表底边直达块底（footer 上移后列表净增 48pt 的几何锁）。
    @Test func wideHeaderBandHoldsBadgeAndCount() {
        let layout = RemindersMetrics.layout(for: CGSize(width: 336, height: 162))
        #expect(layout.state == .wide)
        #expect(layout.topBand.height == 48)
        #expect(layout.topContentRect.height == 28)
        #expect(layout.topContentRect.minX == 10)
        #expect(layout.listBand.minY == layout.topBand.maxY)
        #expect(layout.listBand.maxY == 162)
    }

    /// 宽态徽章贴着顶部内容盒左缘，且完整装得下。
    @Test func wideBadgeSitsAtLeadingEdge() {
        let size = CGSize(width: 300, height: 240)
        let layout = RemindersMetrics.layout(for: size)
        #expect(layout.state == .wide)
        let badge = CGRect(
            x: layout.topContentRect.minX,
            y: layout.topContentRect.minY,
            width: RemindersMetrics.badgeDiameter,
            height: RemindersMetrics.badgeDiameter)
        #expect(badge.maxX <= layout.topContentRect.maxX)
    }

    /// 撤销条放在底部内边距里，且不越出内容盒。
    @Test(arguments: RemindersMetricsTests.sizes)
    func undoBarFitsInsideBlock(size: CGSize) {
        let bar = RemindersMetrics.undoBarRect(in: size)
        #expect(CGRect(origin: .zero, size: size).contains(bar), "\(size) 下撤销条越界：\(bar)")
    }

    /// 宽度不足时区带高度不能被压成负数（探针会因零/负高度被静默跳过，
    /// 那样门禁与几何单测就都在空转）。
    @Test func degenerateSizesNeverProduceNegativeBands() {
        let tiny = CGSize(width: 80, height: 40)
        let layout = RemindersMetrics.layout(for: tiny)
        #expect(layout.state == .narrow)
        #expect(layout.topBand.height > 0)
        #expect(layout.listBand.height >= 0)
    }
}
