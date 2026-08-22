import AppKit
import NotchCenterKit
import SwiftUI

/// NotesPlugin（官方笔记插件，由 NotchNotes 的笔记功能移植而来）。
/// 提供紧凑块（展开抽屉）与抽屉笔记本块（多标签 Markdown 编辑器）。
@objc(NotesPlugin) @MainActor public final class NotesPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "notes.compact",
            displayName: "Notes",
            kind: .compact,
            makeView: { context in
                AnyView(NotesCompactView(context: context))
            }
        ),
        NotchBlock(
            id: "notes.notebook",
            displayName: "Notebook",
            kind: .drawer,
            supportedSizes: [.large, .extraLarge],
            defaultSize: .extraLarge,
            makeView: { context in
                AnyView(NotesBlockView(
                    store: NotesModel.shared.resolve(stateStore: context.stateStore),
                    imageStore: NotesModel.shared.imageStore!,
                    editorInteractionState: NotesModel.shared.editorState(for: context.placementID),
                    placementID: context.placementID
                ))
            }
        )
    ]

    public var settingsView: (@MainActor (PluginSettingsContext) -> AnyView)? {
        { context in
            AnyView(NotesSettingsView(
                store: NotesModel.shared.resolve(stateStore: context.stateStore),
                editorInteractionState: NotesModel.shared.editorInteractionState
            ))
        }
    }

    public var menuItems: [PluginMenuItem] {
        [
            PluginMenuItem(
                id: "notes.menu.new",
                title: "New Note",
                systemImage: "square.and.pencil",
                action: { [weak self] in
                    self?.createNewNote()
                }
            )
        ]
    }

    private weak var hostController: (any HostController)?

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.hostController = hostController
        _ = NotesModel.shared.resolve(stateStore: stateStore)
    }

    private func createNewNote() {
        guard let store = NotesModel.shared.store else { return }
        store.addTab()
        hostController?.expandDrawer()
    }
}

/// 插件内共享模型：多个块视图共享同一 NotesStore / NotesImageStore（数据同步）；
/// 每个放置实例（placementID）显示自己的标签页与编辑器交互状态，
/// 标签页选择经 StateStore 持久化（重启后仍保持，文档 §4.3 多实例语义）。
@MainActor
final class NotesModel {
    static let shared = NotesModel()

    private(set) var store: NotesStore?
    private(set) var imageStore: NotesImageStore?
    /// 注入的插件状态存储（持久化每个放置实例的标签页选择）。
    private var stateStore: StateStore?
    /// 默认编辑器交互状态（设置界面/菜单等无放置上下文的入口使用）。
    let editorInteractionState = EditorInteractionState()
    /// placementID → 该实例当前显示的标签页。
    private var activeTabByPlacement: [String: UUID] = [:]
    /// placementID → 该实例的编辑器交互状态（多实例互不串扰）。
    private var editorStateByPlacement: [String: EditorInteractionState] = [:]

    func resolve(stateStore: StateStore) -> NotesStore {
        self.stateStore = stateStore
        if store == nil {
            store = NotesStore(stateStore: stateStore)
            imageStore = try? NotesImageStore(stateStore: stateStore)
        }
        return store!
    }

    /// 某放置实例当前显示的标签页；优先取内存记录，其次从持久化恢复，
    /// 均无时由调用方回退到全局当前标签页。
    func activeTab(for placementID: String) -> UUID? {
        if let cached = activeTabByPlacement[placementID] {
            return cached
        }
        guard let stateStore,
              let restored: UUID = stateStore.object(UUID.self, forKey: Self.activeTabKey(placementID)) else {
            return nil
        }
        activeTabByPlacement[placementID] = restored
        return restored
    }

    /// 记录某放置实例的标签页选择并持久化。
    func rememberActiveTab(_ tabID: UUID, for placementID: String) {
        activeTabByPlacement[placementID] = tabID
        try? stateStore?.setObject(tabID, forKey: Self.activeTabKey(placementID))
    }

    /// 每个放置实例独立的编辑器交互状态。
    func editorState(for placementID: String) -> EditorInteractionState {
        if let state = editorStateByPlacement[placementID] {
            return state
        }
        let state = EditorInteractionState()
        editorStateByPlacement[placementID] = state
        return state
    }

    private static func activeTabKey(_ placementID: String) -> String {
        // placementID 为宿主生成的 UUID 字符串，仅含合法键字符。
        "activeTab." + placementID
    }
}

/// 紧凑块：笔记图标；点击由核心默认展开抽屉。
private struct NotesCompactView: View {
    let context: BlockContext

    var body: some View {
        // 跟随宿主分配的槽位尺寸（紧凑区为刘海高度带内的小槽位）。
        let slot = context.layoutInfo.frame.size
        return Image(systemName: "note.text")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: slot.width, height: slot.height)
            .contentShape(Rectangle())
            .help("Notes")
            .accessibilityLabel("Notes")
    }
}

/// 设置界面（嵌入插件管理窗口）：标签计数与新笔记入口。
private struct NotesSettingsView: View {
    @ObservedObject var store: NotesStore
    let editorInteractionState: EditorInteractionState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(store.tabs.count) note\(store.tabs.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))

            Text("Markdown notes with TextKit 2 rendering. Images are stored inside the plugin's data directory.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Button("New Note") {
                store.addTab()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}