import AppKit
import NotchCenterKit
import SwiftUI

/// CaffeinatePlugin（官方防休眠插件，由 NotchNotes 的 SystemSleepGuard/AppSettingsStore 移植而来）。
/// 提供一个紧凑块（`.custom` 交互：点击直接切换防休眠）、设置界面与状态栏菜单项。
@objc(CaffeinatePlugin) @MainActor public final class CaffeinatePlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "caffeinate.toggle",
            displayName: "Keep Awake",
            kind: .compact,
            interaction: .custom,
            symbolName: "cup.and.saucer",
            makeView: { context in
                AnyView(KeepAwakeCompactView(context: context))
            }
        )
    ]

    public var menuItems: [PluginMenuItem] {
        [
            PluginMenuItem(
                id: "caffeinate.menu.toggle",
                title: store?.isKeepingAwake == true ? "Stop Keeping Mac Awake" : "Keep Mac Awake",
                systemImage: store?.isKeepingAwake == true ? "cup.and.saucer.fill" : "cup.and.saucer",
                action: { [weak self] in
                    self?.store?.toggleKeepAwake()
                }
            )
        ]
    }

    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? {
        { context in
            AnyView(KeepAwakeSettingsView(store: KeepAwakeModel.shared.resolve(stateStore: context.stateStore)))
        }
    }

    private var store: KeepAwakeStore?

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        store = KeepAwakeModel.shared.resolve(stateStore: stateStore)
    }

    public func pluginWasDisabled() {
        store?.stopKeepingAwake()
    }
}

/// 插件内共享模型：紧凑块与设置界面共享同一 KeepAwakeStore 实例。
@MainActor
private final class KeepAwakeModel {
    static let shared = KeepAwakeModel()

    private(set) var store: KeepAwakeStore?
    private var cachedStateStore: StateStore?

    func resolve(stateStore: StateStore) -> KeepAwakeStore {
        if let store { return store }
        let newStore = KeepAwakeStore(stateStore: stateStore)
        store = newStore
        cachedStateStore = stateStore
        return newStore
    }
}

/// 紧凑块视图：点击直接切换防休眠（interaction = .custom，不展开抽屉）。
private struct KeepAwakeCompactView: View {
    let context: BlockContext
    @StateObject private var store: KeepAwakeStore

    init(context: BlockContext) {
        self.context = context
        _store = StateObject(wrappedValue: KeepAwakeModel.shared.resolve(stateStore: context.stateStore))
    }

    var body: some View {
        // 跟随宿主分配的槽位尺寸（紧凑区为刘海高度带内的小槽位）。
        let slot = context.layoutInfo.frame.size
        return Button {
            store.toggleKeepAwake()
        } label: {
            ZStack {
                Image(systemName: store.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(store.isKeepingAwake ? 0.95 : 0.72))
            }
            .frame(width: slot.width, height: slot.height)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        store.isKeepingAwake
                            ? Color(red: 0.17, green: 0.3, blue: 0.2).opacity(0.5)
                            : .clear
                    )
            )
        }
        .buttonStyle(.plain)
        .help(store.isKeepingAwake ? "Stop keeping Mac awake" : "Keep Mac awake")
        .accessibilityLabel("Keep Mac awake")
        .accessibilityValue(store.isKeepingAwake ? "On" : "Off")
        .onChange(of: store.isKeepingAwake) { _, _ in
            // 状态变化后请求核心刷新紧凑区外观。
            context.hostController.refreshCompactDisplay()
        }
    }
}

/// 设置界面（嵌入插件管理窗口，文档 §4.7）。
private struct KeepAwakeSettingsView: View {
    @ObservedObject var store: KeepAwakeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { store.isKeepingAwake },
                set: { _ in store.toggleKeepAwake() }
            )) {
                Text("Keep Mac Awake")
                    .font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(store.isChangingKeepAwake)

            Text("Prevents the Mac from sleeping (including with the lid closed) until this plugin is turned off or NotchCenter quits. Requires administrator permission.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if let message = store.keepAwakeErrorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}