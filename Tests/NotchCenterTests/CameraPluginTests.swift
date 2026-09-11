import XCTest
@testable import CameraPlugin
import NotchCenterKit

// MARK: - 摄像头授权状态映射

@MainActor
final class CameraAuthorizationTests: XCTestCase {

    func testCurrentAuthorizationIsOneOfTheFourStates() {
        // 不注入、不请求：只验证映射函数返回的是合法枚举值，绝不触发系统授权窗。
        let status = CameraStore.currentAuthorization()
        XCTAssertTrue(
            [PermissionStatus.authorized, .denied, .restricted, .notDetermined].contains(status)
        )
    }

    func testStoreStartsWithoutASessionRunning() {
        let store = CameraStore.shared
        // 单例初始态：绝不自动开启摄像头。
        XCTAssertFalse(store.isRunning, "插件不应在没有用户操作时自动打开摄像头")
    }
}
