import XCTest
import NotchCenterKit

/// NotchCenterPluginServices 钩子分发回归：钩子必须是协议**要求**（extension 只放
/// 默认实现）。若退化为纯 extension 成员，宿主经存在类型 `any NotchCenterPluginServices`
/// 调用时走静态分发，遵守类里的同名重写永远不会被执行——pluginWasDisabled 曾因此
/// 失效（Dsh/Calibre/Caffeinate/OpenCode 的停止逻辑从未触发）。
@MainActor
final class PluginServicesHookTests: XCTestCase {
    private final class HookedPlugin: NotchCenterPluginServices {
        var disabledCount = 0
        var removedPlacements: [String] = []

        func attachServices(stateStore: StateStore, hostController: any HostController) {}

        func pluginWasDisabled() {
            disabledCount += 1
        }

        func placementWasRemoved(blockID: String, placementID: String) {
            removedPlacements.append(placementID)
        }
    }

    /// 未重写任何钩子的最小遵守者：必须能拿到默认空实现且不崩溃。
    private final class PlainPlugin: NotchCenterPluginServices {
        func attachServices(stateStore: StateStore, hostController: any HostController) {}
    }

    func testOverridesAreReachedThroughExistential() {
        let hooked: any NotchCenterPluginServices = HookedPlugin()
        hooked.pluginWasDisabled()
        hooked.placementWasRemoved(blockID: "opencode.usage", placementID: "P1")

        let observer = hooked as? HookedPlugin
        XCTAssertEqual(observer?.disabledCount, 1, "重写必须经存在类型被调用（协议要求，而非 extension 默认实现）")
        XCTAssertEqual(observer?.removedPlacements, ["P1"])
    }

    func testDefaultsApplyForMinimalConformers() {
        let plain: any NotchCenterPluginServices = PlainPlugin()
        plain.pluginWasDisabled()
        plain.placementWasRemoved(blockID: "x", placementID: "y")
    }
}
