import XCTest
@testable import LidAngleDepthPlugin
import CoreGraphics
import simd

// MARK: - 合盖透视效果的纯计算部分
//
// 这些是移植代码里**唯一可无副作用单测**的部分:投影几何、模糊渐变、弹簧、
// 单应矩阵。它们决定了效果的观感,又完全不碰窗口/GPU/屏幕录制,因此是回归的
// 第一道防线(上游 Mac-Duo 没有测试,这里是本仓库补的)。

final class DepthGeometryTests: XCTestCase {

    private let screen = CGSize(width: 1512, height: 982)

    /// 盖子完全打开(start == current)时不该有任何透视:画面四角就是屏幕四角。
    func testCornersAtRestMatchTheScreen() {
        let geometry = DepthGeometry()
        let corners = geometry.corners(
            startAngle: 130, currentAngle: 130,
            viewingDistanceRatio: 2.7, recession: 2, screenSize: screen
        )
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[0].x, 0, accuracy: 0.001, "左下角 x 应为 0")
        XCTAssertEqual(corners[1].x, screen.width, accuracy: 0.001, "右下角 x 应为屏宽")
        XCTAssertEqual(corners[0].y, corners[1].y, accuracy: 0.001, "下边应保持水平")
    }

    /// 合盖初期(全开到约 90 度)画面可见高度必须持续收缩。
    ///
    /// 注意**不要**断言"一路单调到 0 度":投影高度在约 85 度触底、随后回升
    /// (画面转过 90 度开始背对玻璃,见 `testProjectionFoldsBackPastRightAngles`)。
    /// 直观上的"越来越扁"只在前半段成立。
    func testVerticalCompressionDecreasesThroughTheFirstHalfOfTheClose() {
        let geometry = DepthGeometry()
        func compression(at angle: Double) -> Double {
            geometry.verticalCompression(
                startAngle: 130, currentAngle: angle,
                viewingDistanceRatio: 2.7, recession: 1, screenSize: screen
            )
        }
        let open = compression(at: 130)
        let mid = compression(at: 100)
        let bottom = compression(at: 85)

        XCTAssertEqual(open, 1, accuracy: 0.01, "全开时压缩比应为 1")
        XCTAssertLessThan(mid, open, "合到 100 度应已可见压缩")
        XCTAssertLessThan(bottom, mid, "继续合到 85 度(触底处)压缩应更深")
        XCTAssertGreaterThanOrEqual(bottom, 0, "压缩比不得为负")
    }

    /// 转过约 85 度之后投影高度回升——这是画面在空间中转到背面的结果,
    /// 不是 bug。把这条钉住,免得后人"修"掉它。
    func testProjectionFoldsBackPastRightAngles() {
        let geometry = DepthGeometry()
        func compression(at angle: Double) -> Double {
            geometry.verticalCompression(
                startAngle: 130, currentAngle: angle,
                viewingDistanceRatio: 2.7, recession: 1, screenSize: screen
            )
        }
        let atRightAngle = compression(at: 85)
        let folded = compression(at: 60)
        XCTAssertGreaterThan(folded, atRightAngle, "转过 90 度后投影高度应回升")
    }

    /// 压缩比恒落在 0...1,任何输入都不例外(抽屉块用它画示意条,越界会导致版式错乱)。
    func testCompressionStaysInUnitRange() {
        let geometry = DepthGeometry()
        for start in stride(from: 20.0, through: 140.0, by: 20) {
            for current in stride(from: 0.0, through: 140.0, by: 10) {
                let value = geometry.verticalCompression(
                    startAngle: start, currentAngle: current,
                    viewingDistanceRatio: 6, recession: 3, screenSize: screen
                )
                XCTAssertTrue(
                    (0...1).contains(value),
                    "start \(start) current \(current) 的压缩比越界:\(value)"
                )
            }
        }
    }

    /// 零尺寸屏幕不得除零崩溃(显示器热插拔的中间态会出现)。
    func testZeroSizedScreenIsSafe() {
        let geometry = DepthGeometry()
        let value = geometry.verticalCompression(
            startAngle: 130, currentAngle: 90,
            viewingDistanceRatio: 2.7, recession: 1, screenSize: .zero
        )
        XCTAssertEqual(value, 1)
    }

    /// 透视后退比为 0 时画面不转,压缩只来自眼睛位置的变化。
    func testZeroRecessionDegeneratesGracefully() {
        let geometry = DepthGeometry()
        let corners = geometry.corners(
            startAngle: 130, currentAngle: 40,
            viewingDistanceRatio: 2.7, recession: 0, screenSize: screen
        )
        XCTAssertEqual(corners.count, 4)
        for corner in corners {
            XCTAssertTrue(corner.x.isFinite && corner.y.isFinite, "不得出现 NaN/Inf")
        }
    }
}

// MARK: - 模糊与变暗渐变

final class BlurGradientTests: XCTestCase {

    func testProgressIsClampedAndMonotonic() {
        let gradient = BlurGradient()
        // 行程两端:0 表示还没开始(强度 0),1 表示满强度。
        XCTAssertEqual(gradient.blurStrength(progress: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(gradient.blurStrength(progress: 1), 1, accuracy: 1e-9)
        // 越界的 progress 必须被夹住,而不是外插出负值或 >1。
        XCTAssertEqual(gradient.blurStrength(progress: -5), 0, accuracy: 1e-9)
        XCTAssertEqual(gradient.blurStrength(progress: 5), 1, accuracy: 1e-9)

        var previous = -1.0
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            let value = gradient.blurStrength(progress: step)
            XCTAssertGreaterThanOrEqual(value, previous, "模糊强度必须单调不减")
            previous = value
        }
    }

    /// 变暗曲线刻意比模糊曲线"起手快"(dimCurve 0.7 < blurCurve 1.6):同样的行程下
    /// 变暗先到,画面先暗下去再糊开。
    func testDimmingLeadsBlurring() {
        let gradient = BlurGradient()
        let progress = 0.25
        XCTAssertGreaterThan(
            gradient.dimStrength(progress: progress),
            gradient.blurStrength(progress: progress)
        )
    }

    /// 铰链边的下限必须是 0...1 的比例,不能把远端强度放大到超过满值。
    func testHingeFloorIsAFraction() {
        let gradient = BlurGradient()
        XCTAssertTrue((0...1).contains(gradient.dimHingeFloor))
    }
}

// MARK: - 临界阻尼弹簧

final class CriticallyDampedSpringTests: XCTestCase {

    /// 弹簧必须**收敛**到目标,且不越过目标太多(临界阻尼的定义)。
    func testSpringConvergesWithoutOvershootingMuch() {
        var spring = CriticallyDampedSpring(value: 130)
        let target = 40.0
        var maxOvershootBelow = 130.0
        for _ in 0..<600 {
            spring.advance(to: target, dt: 1.0 / 60)
            maxOvershootBelow = min(maxOvershootBelow, spring.value)
        }
        XCTAssertEqual(spring.value, target, accuracy: 0.5, "应稳定收敛到目标")
        XCTAssertGreaterThan(maxOvershootBelow, target - 5, "临界阻尼不应明显过冲")
    }

    /// `reset` 把值钉住并清速度——合盖动作开始的瞬间用它避免从上一次的尾巴起步。
    func testResetClearsVelocity() {
        var spring = CriticallyDampedSpring(value: 130)
        for _ in 0..<10 { spring.advance(to: 40, dt: 1.0 / 60) }
        XCTAssertNotEqual(spring.velocity, 0)
        spring.reset(to: 90)
        XCTAssertEqual(spring.value, 90)
        XCTAssertEqual(spring.velocity, 0)
    }

    /// 调用方把 dt 夹在 1/20 以内(半隐式欧拉的稳定条件),这个范围内不得发散。
    func testStableAtTheClampedMaximumStep() {
        var spring = CriticallyDampedSpring(value: 0)
        for _ in 0..<200 { spring.advance(to: 130, dt: 1.0 / 20) }
        XCTAssertTrue(spring.value.isFinite, "夹住的 dt 下不得发散")
        XCTAssertEqual(spring.value, 130, accuracy: 1)
    }
}

// MARK: - 单应矩阵

final class HomographyTests: XCTestCase {

    /// 目标就是原矩形时,矩阵应当是恒等映射(把四角各自映回自己)。
    func testIdentityWhenCornersMatchTheRectangle() {
        let width = 200.0, height = 100.0
        let matrix = Homography.matrix(width: width, height: height, to: [
            SIMD2(0, 0), SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height),
        ])
        for point in [SIMD2(0.0, 0.0), SIMD2(width, height), SIMD2(50.0, 25.0)] {
            let mapped = matrix * SIMD3(point.x, point.y, 1)
            XCTAssertEqual(mapped.x / mapped.z, point.x, accuracy: 0.01)
            XCTAssertEqual(mapped.y / mapped.z, point.y, accuracy: 0.01)
        }
    }

    /// 每个角都必须映到它声明的目标角上——这是投影正确性的直接检验。
    func testCornersMapToTheirTargets() {
        let corners = [
            SIMD2(20.0, 10.0), SIMD2(180.0, 5.0), SIMD2(150.0, 90.0), SIMD2(30.0, 95.0),
        ]
        let matrix = Homography.matrix(width: 200, height: 100, to: corners)
        let sources = [SIMD2(0.0, 0.0), SIMD2(200.0, 0.0), SIMD2(200.0, 100.0), SIMD2(0.0, 100.0)]
        for (source, target) in zip(sources, corners) {
            let mapped = matrix * SIMD3(source.x, source.y, 1)
            XCTAssertEqual(mapped.x / mapped.z, target.x, accuracy: 0.01)
            XCTAssertEqual(mapped.y / mapped.z, target.y, accuracy: 0.01)
        }
    }
}

// MARK: - 画面四角投影

final class DepthProjectionTests: XCTestCase {

    /// `DepthProjection` 必须与 `DepthGeometry` 同源:抽屉块的示意条与真实效果
    /// 用同一个投影,两者不一致会让"预览"骗人。
    func testMatchesTheUnderlyingGeometry() {
        let size = CGSize(width: 1512, height: 982)
        let tuning = DepthTuning()
        let projected = DepthProjection.corners(
            startAngle: 90, currentAngle: 55, tuning: tuning, screenSize: size
        )
        let expected = DepthGeometry().corners(
            startAngle: 90, currentAngle: 55,
            viewingDistanceRatio: tuning.viewingDistance,
            recession: tuning.recession,
            screenSize: size
        )
        XCTAssertEqual(projected.count, expected.count)
        for (lhs, rhs) in zip(projected, expected) {
            XCTAssertEqual(lhs.x, rhs.x, accuracy: 1e-9)
            XCTAssertEqual(lhs.y, rhs.y, accuracy: 1e-9)
        }
    }
}

// MARK: - 调节参数的出厂值

final class DepthTuningTests: XCTestCase {

    /// 出厂值必须与上游 Mac-Duo 的 `DepthTuning` 一致,否则开箱观感就与原版不同。
    func testFactoryDefaultsMatchUpstream() {
        let tuning = DepthTuning()
        XCTAssertEqual(tuning.viewingDistance, 2.7)
        XCTAssertEqual(tuning.recession, 2)
        XCTAssertEqual(tuning.blurEvenness, 0.4)
        XCTAssertEqual(tuning.dimReach, 0.7)
        XCTAssertEqual(tuning.maxBlurRadius, 55)
        XCTAssertEqual(tuning.maxDim, 0.4)
    }
}

// MARK: - 屏幕录制权限门（未授权不得触发系统授权窗）

/// `SCShareableContent` / `startCapture` 在未授权时被调用就会替用户拉起系统授权窗；
/// 装载期预热抓帧正是"每次打开 App 弹一次权限"的来源。门禁可注入，单测不碰真实 TCC。
@MainActor
final class ScreenCapturePermissionGateTests: XCTestCase {

    func testStreamerDoesNotStartWithoutPermission() {
        let streamer = ScreenStreamer(permissionCheck: { false })
        streamer.start()
        XCTAssertFalse(streamer.isStarted, "未授权时 start() 必须是空操作")
        XCTAssertNil(streamer.screen)
    }

    func testStreamerSkipsWarmUpWithoutPermission() async {
        let streamer = ScreenStreamer(permissionCheck: { false })
        await streamer.warmFilter()
        XCTAssertFalse(streamer.isStarted, "预热同样不得启动抓取")
    }

    func testSnapshotterDoesNotPrewarmWithoutPermission() {
        let snapshotter = ScreenSnapshotter(permissionCheck: { false })
        snapshotter.beginPrewarm()
        XCTAssertFalse(snapshotter.isPrewarming, "未授权时不该开预热定时器")
        XCTAssertFalse(snapshotter.hasPermission)
    }
}
