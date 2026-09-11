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

// MARK: - 装载期不得碰摄像头

/// 采集输入只在用户点「点击预览」时才建：`AVCaptureDeviceInput(device:)` 会拉起
/// 系统摄像头授权窗，装载期调用等于每次启动 App 弹一次（决策见 Agent Note
/// 2026-09-11-permission-lazy-trigger）。
@MainActor
final class CameraPluginAttachTests: XCTestCase {

    /// 只为 `attachServices` 存在的空宿主：权限通道有默认实现，这里补齐无默认的五个。
    private final class IdleHostController: HostController {
        func expandDrawer() {}
        func collapseDrawer() {}
        func enterEditMode() {}
        func exitEditMode() {}
        func refreshCompactDisplay() {}
    }

    func testAttachServicesDoesNotConfigureTheCaptureSession() {
        let stateStore = StateStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("camera-attach-\(UUID().uuidString)")
        )
        CameraPlugin().attachServices(stateStore: stateStore, hostController: IdleHostController())

        XCTAssertFalse(
            CameraStore.shared.isConfigured,
            "插件装载期不得配置采集会话：建采集输入会弹系统授权窗"
        )
        XCTAssertFalse(CameraStore.shared.isRunning, "装载不等于开始采集")
    }
}
