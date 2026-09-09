import AppKit
import Combine
import NotchCenterKit
import SwiftUI

/// CaffeinatePlugin（官方防休眠插件，由 NotchNotes 的 SystemSleepGuard/AppSettingsStore 移植而来）。
/// 一键入口统一为**快捷按钮**（`quickActions` 的 `caffeinate.toggle`，快速区与
/// 快捷按钮盒均可放）；另有设置界面与状态栏菜单项。不再注册自带视图的紧凑块
/// ——宿主以统一标准样式渲染该按钮（文档 §4.11）。
@objc(CaffeinatePlugin) @MainActor public final class CaffeinatePlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = []

    public var menuItems: [PluginMenuItem] {
        [
            PluginMenuItem(
                id: "caffeinate.menu.toggle",
                title: store?.isKeepingAwake == true ? L("caffeinate.menu.stop") : L("caffeinate.menu.start"),
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

    // MARK: 快捷动作

    private var quickActionCache: [QuickAction]?
    private var quickActionCancellables: Set<AnyCancellable> = []

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        guard let store else { return [] } // attachServices 前无 store；宿主不在该窗口期读取。
        let toggle = QuickAction(
            id: "caffeinate.toggle",
            displayName: L("quick.toggle.name"),
            systemImage: "cup.and.saucer",
            kind: .toggle,
            isActive: store.isKeepingAwake,
            // 前身正是默认进带的紧凑块：首启布局里仍放入快速区（宿主据此补种）。
            defaultInStrip: true,
            execute: { [weak store] in
                store?.toggleKeepAwake()
            }
        )
        // 开关态同步：store 状态变化 → 盒内按钮点亮/熄灭（同一份状态）。
        store.$isKeepingAwake
            .sink { [weak toggle] isOn in
                toggle?.isActive = isOn
            }
            .store(in: &quickActionCancellables)
        let actions = [toggle]
        quickActionCache = actions
        return actions
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

/// 激活态底衬（防休眠开启时的深绿底）——插件自有状态语义色，白色层级
/// 未覆盖，收敛为本地调色板（豁免登记见 docs/agent-notes/archive/2026-09-08-UI规范整改追踪.md）。
private enum CaffeinatePalette {
    static let activeFill = Color(red: 0.17, green: 0.3, blue: 0.2).opacity(0.5)
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
        let slot = context.layoutInfo.frame.size
        return Button {
            store.toggleKeepAwake()
        } label: {
            ZStack {
                Image(systemName: store.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(NotchTokens.Text.system( 13, weight: .medium))
                    .foregroundStyle(store.isKeepingAwake ? NotchTokens.Foreground.selected : NotchTokens.Foreground.secondary)
            }
            .frame(width: slot.width, height: slot.height)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                    .fill(
                        store.isKeepingAwake
                            ? CaffeinatePalette.activeFill
                            : .clear
                    )
            )
        }
        .buttonStyle(.plain)
        // 紧凑面板是 canBecomeKey 的 NSPanel，点击后按钮成为 first responder 会画系统蓝色焦点环。
        // （`.focusEffect(_:)` 是 iOS 专属；macOS 用 focusEffectDisabled。）
        .focusable(false)
        .focusEffectDisabled(true)
        .help(store.isKeepingAwake ? L("caffeinate.help.stop") : L("caffeinate.help.start"))
        .accessibilityLabel(L("caffeinate.a11y.keepAwake"))
        .accessibilityValue(store.isKeepingAwake ? L("caffeinate.a11y.on") : L("caffeinate.a11y.off"))
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
                Text(L("caffeinate.settings.title"))
                    .font(NotchTokens.Text.system( 12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(store.isChangingKeepAwake)

            Text(L("caffeinate.settings.description"))
                .font(NotchTokens.Text.system( 11))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let message = store.keepAwakeErrorMessage {
                Text(message)
                    .font(NotchTokens.Text.system( 11))
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}