import CoreGraphics
import XCTest
@testable import NotchCenterKit

/// 打包期最小尺寸遮挡校验的纯几何判定回归：越界 / 自叠 / 贴边容差 / 退化输入。
/// 不渲染、不依赖窗口；与 `BlockMinSizeVerificationTests`（官方插件门禁）解耦——
/// 前者测判定器本身，后者测插件声明。
final class BlockSizeVerifierTests: XCTestCase {
    private let content = CGSize(width: 300, height: 240) // 常见 minSize 内容盒

    func testEmptyProbesProduceNoViolations() {
        XCTAssertTrue(BlockSizeVerifier.violations(probes: [], contentSize: content).isEmpty)
    }

    func testProbeFullyInsideContentPasses() {
        let probes = [
            BlockProbe(id: "header", rect: CGRect(x: 8, y: 8, width: 284, height: 40)),
            BlockProbe(id: "content", rect: CGRect(x: 8, y: 56, width: 284, height: 176)),
        ]
        XCTAssertTrue(BlockSizeVerifier.violations(probes: probes, contentSize: content).isEmpty)
    }

    func testProbeTouchingEdgeIsNotOutOfBounds() {
        // 贴边（minX==0 / maxY==height）仍完整可见：不算越界。
        let probes = [
            BlockProbe(id: "edge", rect: CGRect(x: 0, y: 0, width: 300, height: 240)),
        ]
        XCTAssertTrue(BlockSizeVerifier.violations(probes: probes, contentSize: content).isEmpty)
    }

    func testProbeExtendingBeyondRightEdgeViolates() {
        let probes = [
            BlockProbe(id: "overflow", rect: CGRect(x: 290, y: 0, width: 20, height: 40)),
        ]
        let violations = BlockSizeVerifier.violations(probes: probes, contentSize: content)
        XCTAssertEqual(violations.count, 1)
        guard case .probeOutsideContent(let id, let rect, let size) = violations[0] else {
            return XCTFail("应为 probeOutsideContent")
        }
        XCTAssertEqual(id, "overflow")
        XCTAssertEqual(rect.maxX, 310)
        XCTAssertEqual(size, content)
    }

    func testProbeExtendingBeyondBottomEdgeViolates() {
        let probes = [
            BlockProbe(id: "underflow", rect: CGRect(x: 0, y: 220, width: 40, height: 60)),
        ]
        let violations = BlockSizeVerifier.violations(probes: probes, contentSize: content)
        XCTAssertEqual(violations.count, 1)
        guard case .probeOutsideContent(let id, _, _) = violations[0] else {
            return XCTFail("应为 probeOutsideContent")
        }
        XCTAssertEqual(id, "underflow")
    }

    func testOverlappingProbesViolate() {
        let probes = [
            BlockProbe(id: "a", rect: CGRect(x: 0, y: 0, width: 200, height: 100)),
            BlockProbe(id: "b", rect: CGRect(x: 100, y: 50, width: 200, height: 100)),
        ]
        let violations = BlockSizeVerifier.violations(probes: probes, contentSize: content)
        XCTAssertEqual(violations.count, 1)
        guard case .probesOverlap(let first, let second, let intersection) = violations[0] else {
            return XCTFail("应为 probesOverlap")
        }
        XCTAssertEqual(first, "a")
        XCTAssertEqual(second, "b")
        XCTAssertEqual(intersection, CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    func testEdgeTouchingProbesDoNotViolate() {
        // 只在边上相接（交集高度 0）不构成遮挡。
        let probes = [
            BlockProbe(id: "top", rect: CGRect(x: 0, y: 0, width: 300, height: 100)),
            BlockProbe(id: "bottom", rect: CGRect(x: 0, y: 100, width: 300, height: 140)),
        ]
        XCTAssertTrue(BlockSizeVerifier.violations(probes: probes, contentSize: content).isEmpty)
    }

    func testDegenerateZeroSizeProbesAreIgnored() {
        // 零尺寸矩形无可见区可言：不越界（点在盒内）、不相交。
        let probes = [
            BlockProbe(id: "point", rect: CGRect(x: 299, y: 239, width: 0, height: 0)),
            BlockProbe(id: "point2", rect: CGRect(x: 200, y: 100, width: 0, height: 0)),
        ]
        XCTAssertTrue(BlockSizeVerifier.violations(probes: probes, contentSize: content).isEmpty)
    }

    func testZeroContentBoxYieldsNoViolations() {
        let probes = [BlockProbe(id: "a", rect: CGRect(x: 0, y: 0, width: 10, height: 10))]
        XCTAssertTrue(BlockSizeVerifier.violations(probes: probes, contentSize: .zero).isEmpty)
    }

    func testMultipleViolationsAreAllReportedInDeclarationOrder() {
        let probes = [
            BlockProbe(id: "a", rect: CGRect(x: 0, y: 0, width: 200, height: 200)),
            BlockProbe(id: "b", rect: CGRect(x: 150, y: 150, width: 300, height: 100)), // 越界 + 与 a 叠
            BlockProbe(id: "c", rect: CGRect(x: 250, y: 0, width: 100, height: 50)),   // 越界
        ]
        let violations = BlockSizeVerifier.violations(probes: probes, contentSize: content)
        // 越界先行（b、c 按声明序），重叠随后（a-b）。
        XCTAssertEqual(violations.count, 3)
        guard case .probeOutsideContent(let firstID, _, _) = violations[0],
              case .probeOutsideContent(let secondID, _, _) = violations[1],
              case .probesOverlap(let overlapA, let overlapB, _) = violations[2]
        else {
            return XCTFail("违规类别/顺序不符：\(violations)")
        }
        XCTAssertEqual(firstID, "b")
        XCTAssertEqual(secondID, "c")
        XCTAssertEqual(overlapA, "a")
        XCTAssertEqual(overlapB, "b")
    }
}
