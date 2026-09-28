import XCTest
import NotchCenterKit

// MARK: - 系统权限清单与引导（纯逻辑；绝不触发真实授权弹窗）

/// 权限清单与状态推导：URL 构造、用途键映射、四态语义。
///
/// **隔离纪律**：本套件只碰 Kit 的纯类型与注入的假实现。绝不调用
/// `PermissionRequesting.request`（会弹系统授权窗）、不查询真实 TCC 状态、
/// 不开系统设置。
final class PermissionTests: XCTestCase {

    // MARK: 跳转 URL（纯函数）

    func testEveryPermissionBuildsItsOwnPrivacyPaneURL() {
        // 逐项断言 pane 名——写错一个 pane 只是"跳到系统设置首页"，
        // 用户会以为按钮坏了，所以这里必须逐条钉死。
        let expected: [SystemPermission: String] = [
            .calendar: "Privacy_Calendars",
            .reminders: "Privacy_Reminders",
            .camera: "Privacy_Camera",
            .screenRecording: "Privacy_ScreenCapture",
            .accessibility: "Privacy_Accessibility",
            .location: "Privacy_LocationServices",
            .photos: "Privacy_Photos",
        ]
        XCTAssertEqual(expected.count, SystemPermission.allCases.count, "清单新增权限时必须同步本用例")
        for (permission, pane) in expected {
            XCTAssertEqual(
                SystemSettingsURL.string(for: permission),
                "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            )
        }
    }

    func testSettingsURLsAreValidAndDistinct() {
        let urls = SystemPermission.allCases.map { SystemSettingsURL.url(for: $0) }
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "x-apple.systempreferences" })
        XCTAssertEqual(Set(urls.map(\.absoluteString)).count, SystemPermission.allCases.count)
    }

    // MARK: 清单元数据一致性

    func testUsageDescriptionKeysMatchTheInfoPlistWhitelist() {
        // 屏幕录制与辅助功能的 TCC 不读用途字符串，必须为 nil；其余各项必须有键。
        let withoutKey: Set<SystemPermission> = [.screenRecording, .accessibility]
        for permission in SystemPermission.allCases {
            if withoutKey.contains(permission) {
                XCTAssertNil(permission.usageDescriptionKey, "\(permission) 的 TCC 不读用途字符串")
            } else {
                XCTAssertNotNil(permission.usageDescriptionKey, "\(permission) 必须声明用途字符串键")
            }
        }
        XCTAssertEqual(
            SystemPermission.calendar.usageDescriptionKey, "NSCalendarsFullAccessUsageDescription")
        XCTAssertEqual(
            SystemPermission.reminders.usageDescriptionKey, "NSRemindersFullAccessUsageDescription")
        XCTAssertEqual(SystemPermission.camera.usageDescriptionKey, "NSCameraUsageDescription")
        XCTAssertEqual(SystemPermission.location.usageDescriptionKey, "NSLocationUsageDescription")
        XCTAssertEqual(
            SystemPermission.photos.usageDescriptionKey, "NSPhotoLibraryUsageDescription")
    }

    func testRelaunchRequirementOnlyForScreenRecordingAndAccessibility() {
        // 屏幕录制走 replayd 缓存、辅助功能有进程级 AX 缓存，两者授权后都要重启。
        XCTAssertTrue(SystemPermission.screenRecording.requiresRelaunch)
        XCTAssertTrue(SystemPermission.accessibility.requiresRelaunch)
        for permission in [SystemPermission.calendar, .reminders, .camera, .location, .photos] {
            XCTAssertFalse(permission.requiresRelaunch)
        }
    }

    func testEveryPermissionHasSymbolAndStableRawValue() {
        for permission in SystemPermission.allCases {
            XCTAssertFalse(permission.symbolName.isEmpty)
            // rawValue 是本地化键的一部分（`permission.name.<rawValue>`），
            // 也是持久化键，改动会静默丢本地化，这里钉住。
            XCTAssertEqual(SystemPermission(rawValue: permission.rawValue), permission)
        }
        XCTAssertEqual(
            Set(SystemPermission.allCases.map(\.rawValue)),
            [
                "calendar", "reminders", "camera", "screenRecording", "accessibility", "location",
                "photos",
            ]
        )
    }

    // MARK: 状态语义

    func testStatusUsabilityAndRequestability() {
        XCTAssertTrue(PermissionStatus.authorized.isUsable)
        XCTAssertFalse(PermissionStatus.notDetermined.isUsable)
        XCTAssertFalse(PermissionStatus.denied.isUsable)
        XCTAssertFalse(PermissionStatus.restricted.isUsable)

        // 只有"还没问过"才值得再弹系统窗；已拒绝/受限必须走系统设置。
        XCTAssertTrue(PermissionStatus.notDetermined.canRequest)
        XCTAssertFalse(PermissionStatus.denied.canRequest)
        XCTAssertFalse(PermissionStatus.restricted.canRequest)
        XCTAssertFalse(PermissionStatus.authorized.canRequest)
    }

    func testStatusRoundTripsThroughRawValue() {
        for status in [PermissionStatus.notDetermined, .authorized, .denied, .restricted] {
            XCTAssertEqual(PermissionStatus(rawValue: status.rawValue), status)
        }
    }
}

// MARK: - 假实现驱动的降级分支

/// 假状态提供者：把四态各测一遍，验证"插件据状态决定呈现"的纯决策函数。
@MainActor
private final class FakeStatusProvider: PermissionStatusProviding {
    private let statuses: [SystemPermission: PermissionStatus]
    private(set) var queried: [SystemPermission] = []

    init(_ statuses: [SystemPermission: PermissionStatus]) {
        self.statuses = statuses
    }

    func status(of permission: SystemPermission) -> PermissionStatus {
        queried.append(permission)
        return statuses[permission] ?? .notDetermined
    }
}

/// 权限降级决策：把"给定状态该显示什么"抽成纯函数，与视图解耦以便单测。
enum PermissionDegradeDecision: Equatable {
    /// 权限可用：正常呈现数据。
    case showContent
    /// 未请求：显示引导 + 「授权」按钮（点了才弹系统窗）。
    case promptRequest
    /// 已拒绝 / 受限：显示引导 + 「去系统设置」按钮（系统不会再弹窗）。
    case promptSettings(restricted: Bool)
}

func permissionDegradeDecision(for status: PermissionStatus) -> PermissionDegradeDecision {
    switch status {
    case .authorized: return .showContent
    case .notDetermined: return .promptRequest
    case .denied: return .promptSettings(restricted: false)
    case .restricted: return .promptSettings(restricted: true)
    }
}

@MainActor
final class PermissionDegradeTests: XCTestCase {

    func testEachStatusMapsToItsDegradedPresentation() {
        XCTAssertEqual(permissionDegradeDecision(for: .authorized), .showContent)
        XCTAssertEqual(permissionDegradeDecision(for: .notDetermined), .promptRequest)
        XCTAssertEqual(permissionDegradeDecision(for: .denied), .promptSettings(restricted: false))
        XCTAssertEqual(permissionDegradeDecision(for: .restricted), .promptSettings(restricted: true))
    }

    func testNoStatusEverMeansPageFailure() {
        // 纪律：任何非授权态都只是"换个呈现"，不存在"整页报错"这个分支。
        for status in [PermissionStatus.notDetermined, .authorized, .denied, .restricted] {
            XCTAssertNotNil(permissionDegradeDecision(for: status))
        }
    }

    func testFakeProviderFeedsStatusAndRecordsQueries() {
        let provider = FakeStatusProvider([.camera: .denied, .calendar: .authorized])
        XCTAssertEqual(provider.status(of: .camera), .denied)
        XCTAssertEqual(provider.status(of: .calendar), .authorized)
        // 未登记项按"未请求"处理，天然走引导态而不是当成已授权。
        XCTAssertEqual(provider.status(of: .location), .notDetermined)
        XCTAssertEqual(provider.queried, [.camera, .calendar, .location])
    }
}

// MARK: - HostController 权限通道必须经存在类型分发

/// 与 `PluginServicesHookTests` 同族的回归：`permissionStatus(of:)` 与
/// `presentPermissions(_:)` 必须是协议**要求**（extension 只放默认实现）。
/// 若退化为纯 extension 成员，宿主经 `any HostController` 调用时走静态分发，
/// 遵守类的重写永远不会执行——权限弹窗会静默失效。
@MainActor
final class HostControllerPermissionChannelTests: XCTestCase {

    private final class RecordingHost: HostController {
        var presentedFocus: [[SystemPermission]] = []
        var statuses: [SystemPermission: PermissionStatus] = [:]

        func expandDrawer() {}
        func collapseDrawer() {}
        func enterEditMode() {}
        func exitEditMode() {}
        func refreshCompactDisplay() {}

        func permissionStatus(of permission: SystemPermission) -> PermissionStatus {
            statuses[permission] ?? .notDetermined
        }

        func presentPermissions(_ focus: [SystemPermission]) {
            presentedFocus.append(focus)
        }
    }

    /// 最小遵守者：不重写权限成员，必须拿到默认实现（未请求 / 静默忽略）而非崩溃。
    private final class PlainHost: HostController {
        func expandDrawer() {}
        func collapseDrawer() {}
        func enterEditMode() {}
        func exitEditMode() {}
        func refreshCompactDisplay() {}
    }

    func testOverridesAreReachedThroughExistential() {
        let host: any HostController = RecordingHost()
        host.presentPermissions([.calendar, .reminders])
        host.presentPermissions([])

        let recorder = host as? RecordingHost
        XCTAssertEqual(
            recorder?.presentedFocus,
            [[.calendar, .reminders], []],
            "presentPermissions 必须经协议要求分发到遵守类实现")
    }

    func testStatusOverrideIsReachedThroughExistential() {
        let recorder = RecordingHost()
        recorder.statuses = [.camera: .authorized]
        let host: any HostController = recorder
        XCTAssertEqual(host.permissionStatus(of: .camera), .authorized)
    }

    func testDefaultsAreSafeForMinimalConformers() {
        let host: any HostController = PlainHost()
        // 默认按"未请求"上报：插件走引导态，而不是把没权限当有权限用。
        XCTAssertEqual(host.permissionStatus(of: .calendar), .notDetermined)
        // 默认不弹窗（静默忽略，不崩）。
        host.presentPermissions([.camera])
    }
}
