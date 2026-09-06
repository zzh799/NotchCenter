import AppKit
import NotchCenterKit
import SwiftUI

/// NotesPlugin（官方笔记插件，由 NotchNotes 的笔记功能移植而来）。
/// 「新建笔记」一键入口统一为**快捷按钮**（`notes.compact`，快速区与按钮盒
/// 均可放；宿主统一标准样式渲染）；抽屉笔记本块（多标签 Markdown 编辑器）
/// 仍以组件块提供。
@objc(NotesPlugin) @MainActor public final class NotesPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "notes.notebook",
            displayName: L("notes.block.notebook"),
            kind: .drawer,
            supportedSizes: [.large, .extraLarge],
            defaultSize: .extraLarge,
            // 自由跨度：允许竖向加高（2/4 列 × 3-4 行）。编辑模式向下扩大时
            // 推挤下方块、面板按需增高——没有这些跨度时纵向拖动无法生效
            //（nearest 永远回到 2 行高的档位）。
            supportedGridSpans: [
                GridSpan(columns: 2, rows: 3),
                GridSpan(columns: 2, rows: 4),
                GridSpan(columns: 4, rows: 3),
                GridSpan(columns: 4, rows: 4),
            ],
            symbolName: "book",
            makeView: { context in
                AnyView(NotesBlockView(
                    store: NotesModel.shared.resolve(stateStore: context.stateStore),
                    imageStore: NotesModel.shared.imageStore!,
                    editorInteractionState: NotesModel.shared.editorState(for: context.placementID),
                    placementID: context.placementID,
                    gridRow: context.layoutInfo.originRow ?? 0,
                    gridHeightRows: context.layoutInfo.heightRows ?? 1,
                    isPreview: context.layoutInfo.isPreview
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
                title: L("notes.newNote"),
                systemImage: "square.and.pencil",
                action: { [weak self] in
                    self?.createNewNote()
                }
            )
        ]
    }

    // MARK: 快捷动作（Quick Action，可被快捷按钮盒收纳）

    private var quickActionCache: [QuickAction]?

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        // 前身即默认进带的 `notes.compact` 紧凑块：语义完全一致
        // （新建笔记 + 展开抽屉 + 焦点落到新笔记）。
        let action = QuickAction(
            id: "notes.compact",
            displayName: L("notes.newNote"),
            systemImage: "note.text",
            kind: .action,
            defaultInStrip: true,
            execute: { [weak self] in
                self?.createNewNote()
            }
        )
        quickActionCache = [action]
        return quickActionCache!
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
        // 在最上方的笔记本放置实例中新建并把焦点挂起到该实例的编辑器；
        // 无放置实例时退化为仅新建（数据层生效）。
        if let hostController {
            NotesModel.shared.createNoteInTopmostPlacement(hostController: hostController)
        } else {
            NotesModel.shared.store?.addTab()
        }
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
    /// placementID → 该实例在抽屉网格中的纵向位置（originRow / heightRows），
    /// 由各放置实例视图自行登记，用于定位“最上方”的笔记本块。
    private var placementGridRows: [String: GridPosition] = [:]

    struct GridPosition {
        let row: Int
        let heightRows: Int
    }

    /// 视图登记自己在抽屉网格中的位置（onAppear / 布局变化时调用）。
    func registerPlacement(_ placementID: String, row: Int, heightRows: Int) {
        placementGridRows[placementID] = GridPosition(row: row, heightRows: heightRows)
    }

    func unregisterPlacement(_ placementID: String) {
        placementGridRows.removeValue(forKey: placementID)
    }

    /// 最上方的放置实例（originRow 最小；同行取更高的块）。无登记时回退 nil。
    func topmostPlacementID() -> String? {
        placementGridRows
            .sorted { lhs, rhs in
                lhs.value.row == rhs.value.row
                    ? lhs.value.heightRows > rhs.value.heightRows
                    : lhs.value.row < rhs.value.row
            }
            .first?
            .key
    }

    /// 紧凑图标点击入口：在最上方的笔记本放置实例中新建笔记并请求焦点，
    /// 焦点经 `scheduleDeferredFocus` 挂起，等抽屉展开、编辑器视图 bind 时生效。
    func createNoteFromCompactIcon(hostController: any HostController) {
        createNoteInTopmostPlacement(hostController: hostController)
    }

    func createNoteInTopmostPlacement(hostController: any HostController) {
        guard let store else { return }
        let newTabID = store.addTab()

        // 无任何放置的笔记本块时仍新建（数据层生效），仅无法定向焦点。
        guard let placementID = topmostPlacementID() else { return }

        rememberActiveTab(newTabID, for: placementID)
        editorState(for: placementID).scheduleDeferredFocus()
        hostController.expandDrawer()
    }
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

/// 紧凑块：笔记图标；点击 = 新建笔记 + 展开抽屉 + 焦点落到新笔记（.custom 交互）。
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
            .onTapGesture {
                NotesModel.shared.createNoteFromCompactIcon(hostController: context.hostController)
            }
            .help(L("notes.newNote"))
            .accessibilityLabel(L("notes.newNote"))
    }
}

/// 设置界面（嵌入插件管理窗口）：标签计数与新笔记入口。
private struct NotesSettingsView: View {
    @ObservedObject var store: NotesStore
    let editorInteractionState: EditorInteractionState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 中英文单复数形式不同，分键处理；中文两键同文。
            Text(store.tabs.count == 1
                 ? LF("notes.count.one", store.tabs.count)
                 : LF("notes.count.other", store.tabs.count))
                .font(.system(size: 12, weight: .semibold))

            Text(L("notes.settings.description"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Button(L("notes.newNote")) {
                store.addTab()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}