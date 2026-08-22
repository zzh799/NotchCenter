import XCTest
@testable import NotchCenter

/// 缩放握把死区量化回归：旧实现把位移 round() 成整数档位、再用
/// “候选距离 + 1”做迟滞余量——整数 L1 距离下“≥ 1 更远”等价于
/// “更近即切换”，实际没有死区。鼠标在半格边界附近 ±1px 抖动时
/// round() 在相邻档位间翻转，预览随之在原尺寸与目标尺寸间闪烁
/// （密集跨度块如 File Shelf 尤其明显）。量化必须换档即越过
/// 边界 ± band 的稳定带。
final class ResizeHysteresisTests: XCTestCase {
    func testDeadBandHoldsCurrentOnBothSidesOfBoundary() {
        // 半格边界（2.5）两侧的死区（±band）内保持当前档位
        // （2.32/2.68 恰在理论边界上，会因浮点表示误差翻转，取安全余量）。
        XCTAssertEqual(ResizeHysteresis.quantized(2.34, current: 2), 2)
        XCTAssertEqual(ResizeHysteresis.quantized(2.66, current: 2), 2)
        XCTAssertEqual(ResizeHysteresis.quantized(2.34, current: 3), 3)
        XCTAssertEqual(ResizeHysteresis.quantized(2.66, current: 3), 3)
    }

    func testBoundaryJitterDoesNotToggle() {
        // 从低档出发的边界抖动：不升档。
        var low = 2
        for continuous in [2.5, 2.6, 2.5, 2.45, 2.55, 2.6] {
            low = ResizeHysteresis.quantized(continuous, current: low)
        }
        XCTAssertEqual(low, 2)

        // 从高档出发的同一段抖动：也不降档。
        var high = 3
        for continuous in [2.5, 2.4, 2.5, 2.45, 2.4] {
            high = ResizeHysteresis.quantized(continuous, current: high)
        }
        XCTAssertEqual(high, 3)
    }

    func testSwitchesBeyondDeadBand() {
        // 越过死区即换档；大幅拖动一次跨多档落到最近整数。
        XCTAssertEqual(ResizeHysteresis.quantized(2.7, current: 2), 3)
        XCTAssertEqual(ResizeHysteresis.quantized(2.3, current: 3), 2)
        XCTAssertEqual(ResizeHysteresis.quantized(4.6, current: 2), 4)
        XCTAssertEqual(ResizeHysteresis.quantized(1.4, current: 4), 2)
    }

    func testPressStartsAtCurrentSize() {
        // 按下瞬间位移为零或极小：不产生任何尺寸变化。
        XCTAssertEqual(ResizeHysteresis.quantized(2.0, current: 2), 2)
        XCTAssertEqual(ResizeHysteresis.quantized(2.1, current: 2), 2)
        XCTAssertEqual(ResizeHysteresis.quantized(1.9, current: 2), 2)
    }

    func testPreviewPipelineDoesNotFlickerAfterCrossing() {
        // 复现管线（密集跨度，量化结果即预览）：拖过边界升到 3 档后，
        // 在边界附近往返抖动。旧实现在 2.5 处会翻回 2、再翻回 3 循环闪烁；
        // 死区量化后稳定在 3。
        var preview = 2
        var history: [Int] = []
        for continuous in [2.75, 2.6, 2.5, 2.62, 2.55, 2.65, 2.5, 2.58, 2.6] {
            let raw = ResizeHysteresis.quantized(continuous, current: preview)
            preview = min(max(raw, 1), 4)
            history.append(preview)
        }
        XCTAssertEqual(history, Array(repeating: 3, count: history.count))
    }

    func testLocalSpaceFeedbackAlternatesWhileGlobalStaysMonotone() {
        // 坐标系反馈回路模型（修复“逐像素在原大小/目标大小切换”的根因）：
        // 缩放手势默认在握把的 .local 空间度量平移量，而预览每长一列，
        // 握把连同其 local 空间右移一个步长 → translation 瞬间 -step
        // → 预览缩回 → 握把移回 → translation 恢复……逐事件自激振荡。
        // 死区量化无法吸收整格扰动；修复是把手势移到稳定坐标系
        // （.global，见 DrawerBlockContainer.resizeGesture）。
        let step = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing

        func run(localSpace: Bool) -> [Int] {
            var preview = 2
            var history: [Int] = []
            // 鼠标匀速前进（100pt → 130pt，每事件 +1pt），越过升档死区边缘；
            // local 模型里 translation 受“预览档位 × 步长”的反向扰动。
            for screenDelta in stride(from: 100.0, through: 130.0, by: 1.0) {
                let translation = screenDelta - (localSpace ? CGFloat(preview - 2) * step : 0)
                let continuous = 2 + translation / step
                preview = ResizeHysteresis.quantized(continuous, current: preview)
                history.append(preview)
            }
            return history
        }

        let local = run(localSpace: true)
        let global = run(localSpace: false)

        // local：越过边界后 3↔2 逐事件交替（自激振荡，出现回落）。
        XCTAssertEqual(local[10], 2)
        XCTAssertEqual(local[11], 3)
        XCTAssertEqual(local[12], 2)
        XCTAssertEqual(local[13], 3)
        XCTAssertTrue(zip(local, local.dropFirst()).contains { $0 > $1 })

        // global：单调升到 3 后稳定（只升不回落）。
        XCTAssertEqual(global[11], 3)
        XCTAssertTrue(global[11...].allSatisfy { $0 == 3 })
        XCTAssertTrue(zip(global, global.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
