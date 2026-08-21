import SwiftUI

// MARK: - 插件入口协议（文档 §4.1 / §4.7 / §4.8）

/// 插件主类必须遵守的协议。身份信息来自 bundle 的 Info.plist（文档 §4.1），
/// 协议不重复要求 pluginID 等属性。
@MainActor
public protocol NotchCenterPlugin: AnyObject {
    /// 插件提供的块类型清单（静态，宿主在实例化前即可读取）。
    static var blocks: [NotchBlock] { get }
    init()
}

extension NotchCenterPlugin {
    /// 插件设置界面（文档 §4.7）。返回 nil 时插件管理窗口只显示元数据。
    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? { nil }

    /// 状态栏菜单贡献（文档 §4.8），最多 3 项。
    public var menuItems: [PluginMenuItem] { [] }
}

/// 可选服务钩子：宿主在实例化、启用/禁用插件后调用，用于注入作用域
/// `StateStore` 与 `HostController`（文档 §4.5）。无法注入时插件仍可运行。
@MainActor
public protocol NotchCenterPluginServices: AnyObject {
    /// 插件实例获得作用域存储与宿主控制器（菜单项等非视图入口需要它）。
    func attachServices(stateStore: StateStore, hostController: any HostController)
}

extension NotchCenterPluginServices {
    /// 插件被禁用时宿主调用（默认空实现）。禁止在此卸载 bundle（文档 §3.4）。
    public func pluginWasDisabled() {}
}

// MARK: - 菜单项（文档 §4.8）

@MainActor
public struct PluginMenuItem: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let action: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}