import SwiftUI

// MARK: - 插件入口协议（文档 §4.1 / §4.7 / §4.8）

/// 插件主类必须遵守的协议。身份信息来自 bundle 的 Info.plist（文档 §4.1），
/// 协议不重复要求 pluginID 等属性。
@MainActor
public protocol NotchCenterPlugin: AnyObject {
    /// 插件提供的块类型清单（静态，宿主在实例化前即可读取）。
    static var blocks: [NotchBlock] { get }
    /// 插件设置界面（文档 §4.7）。返回 nil 时插件管理窗口只显示元数据。
    ///
    /// 注意：必须是协议**要求**（而非仅 extension 默认实现）。宿主通过存在类型
    /// `any NotchCenterPlugin` 访问，Swift 只按 witness table 分发；若是纯 extension
    /// 成员，遵守类里声明的同名属性永远不会被调用（历史 bug：设置界面与菜单项全部静默失效）。
    var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? { get }
    /// 状态栏菜单贡献（文档 §4.8），最多 3 项。同上必须作为协议要求。
    var menuItems: [PluginMenuItem] { get }
    init()
}

extension NotchCenterPlugin {
    /// 默认无设置界面。
    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? { nil }

    /// 默认不贡献菜单项。
    public var menuItems: [PluginMenuItem] { [] }
}

/// 可选服务钩子：宿主在实例化、启用/禁用插件后调用，用于注入作用域
/// `StateStore` 与 `HostController`（文档 §4.5）。无法注入时插件仍可运行。
@MainActor
public protocol NotchCenterPluginServices: AnyObject {
    /// 插件实例获得作用域存储与宿主控制器（菜单项等非视图入口需要它）。
    func attachServices(stateStore: StateStore, hostController: any HostController)
    /// 插件被禁用时宿主调用。默认空实现。
    ///
    /// 注意：本方法与 placementWasRemoved 都必须保持为协议**要求**（extension
    /// 只提供默认实现）——宿主经存在类型 `any NotchCenterPluginServices` 调用，
    /// 纯 extension 成员走静态分发，遵守类里的同名重写永远不会被执行
    /// （pluginWasDisabled 曾因此失效：Dsh/Calibre/Caffeinate/OpenCode 的
    /// 停止逻辑从未被触发，与 settingsView 是同族历史坑）。
    func pluginWasDisabled()
    /// 一个放置实例被用户移除时宿主调用（抽屉块与紧凑图标两条删除路径都会
    /// 触发）。默认空实现；插件重写以清理该实例在 placementStore 里的持久化
    /// 数据，避免孤儿文件堆积；插件级共享数据不受影响。
    func placementWasRemoved(blockID: String, placementID: String)
}

extension NotchCenterPluginServices {
    /// 插件被禁用时宿主调用（默认空实现）。禁止在此卸载 bundle（文档 §3.4）。
    public func pluginWasDisabled() {}

    /// 放置实例被移除时的默认空实现。
    public func placementWasRemoved(blockID: String, placementID: String) {}
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