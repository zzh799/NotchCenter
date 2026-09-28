import AppKit
import NotchCenterKit
import SwiftUI

/// NotesPlugin（官方笔记插件，由 NotchNotes 的笔记功能移植而来）。
/// 「新建笔记」一键入口统一为**快捷按钮**（`notes.compact`，快速区与按钮盒
/// 均可放；宿主统一标准样式渲染）；抽屉笔记本块（多标签 Markdown 编辑器）
/// 仍以组件块提供。
///
/// 本插件**不提供设置界面**：笔记块的设置项只有「条数 + 新建入口」这类无配置
/// 价值的展示，而宿主左侧齿轮与块内控件是重复入口（用户裁定撤掉）。不声明
/// `settingsView` 即无齿轮、无 `SettingPopover` 入口。
@objc(NotesPlugin) @MainActor public final class NotesPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// 块 id（放置清理钩子按它过滤）。
    static let notebookBlockID = "notes.notebook"

    /// 打包期最小尺寸遮挡校验探针（Kit BlockProbe；几何区带镜像 NotebookBlockView /
    /// MarkdownEditorViews 的布局常量——改动布局时同步这里）。
    /// 区带意图：顶部分页条 34pt（toolbarHeight）+ 间隔 8（editorSpacing）+
    /// 文本区下限 120pt（editorHeight clamp）+ 底栏 38+1（toolbar + separator）。
    /// 竖轴总和 201 必须 ≤ minSize.height；违规说明块缩到比自身结构还矮，会向
    /// 邻居溢出（宿主卡片不裁切）。
    /// 右上角悬浮的新建角标**不单列探针**：它 34pt 见方、恒落在分页条那条带内
    /// （规则与理由见 `docs/agents/插件开发约定.md`「块内悬浮角标不单列 BlockProbe」）。
    private static func notesLayoutProbes(for size: CGSize) -> [BlockProbe] {
        let pagerHeight: CGFloat = 34
        let spacing: CGFloat = 8
        let textMinimumHeight: CGFloat = 120
        let footerHeight: CGFloat = 39
        return [
            BlockProbe(
                id: "notes.pager",
                rect: CGRect(x: 0, y: 0, width: size.width, height: pagerHeight)),
            BlockProbe(
                id: "notes.textArea",
                rect: CGRect(
                    x: 0, y: pagerHeight + spacing,
                    width: size.width, height: textMinimumHeight)),
            BlockProbe(
                id: "notes.footer",
                rect: CGRect(
                    x: 0, y: max(size.height - footerHeight, pagerHeight + spacing + textMinimumHeight),
                    width: size.width, height: footerHeight)),
        ]
    }

    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: NotesPlugin.notebookBlockID,
            displayName: L("notes.block.notebook"),
            kind: .drawer,
            minSize: BlockPixelSize(width: 300, height: 240),
            maxSize: BlockPixelSize(width: 600, height: 480),
            // 推荐 4×2（默认档）；允许矩形盒内任意整数跨（含竖向加高 2/4 列 ×
            // 3-4 行）。编辑模式向下扩大时推挤下方块、面板按需增高。
            recommendedSize: BlockPixelSize(width: 600, height: 240),
            symbolName: "book",
            probes: { info in
                notesLayoutProbes(for: info.frame.size)
            },
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

    // MARK: 快捷动作

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
    /// 宿主退出通知观察者：退无可退时兜底落盘（越晚越好，插件无法预知退出）。
    private var terminateObserver: NSObjectProtocol?

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.hostController = hostController
        _ = NotesModel.shared.resolve(stateStore: stateStore)
        installTerminateObserverIfNeeded()
    }

    /// 注册退出兜底落盘（幂等：重复注入不重复注册）。
    private func installTerminateObserverIfNeeded() {
        guard terminateObserver == nil else { return }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NotesModel.shared.flushAll()
            }
        }
    }

    /// 插件被禁用：立即落盘，并移除退出观察者（避免重复注册）。
    public func pluginWasDisabled() {
        NotesModel.shared.flushAll()
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    /// 一个笔记本放置实例被用户移除：丢弃该实例的内存状态与持久化的标签页选择。
    public func placementWasRemoved(blockID: String, placementID: String) {
        guard blockID == Self.notebookBlockID else { return }
        NotesModel.shared.forgetPlacement(placementID)
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

    /// 立即落盘当前笔记快照（插件禁用或宿主退出时由 NotesPlugin 调用）。
    func flushAll() {
        store?.flush()
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

    /// 放置实例被移除：清掉该实例的内存状态（编辑器交互状态、标签页记忆、网格登记）
    /// 与持久键 `activeTab.<placementID>`，避免删实例后留下孤儿。
    func forgetPlacement(_ placementID: String) {
        editorStateByPlacement.removeValue(forKey: placementID)
        activeTabByPlacement.removeValue(forKey: placementID)
        placementGridRows.removeValue(forKey: placementID)
        stateStore?.removeValue(forKey: Self.activeTabKey(placementID))
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
        let slot = context.layoutInfo.frame.size
        return Image(systemName: "note.text")
            .font(NotchTokens.Text.system(13, weight: .medium))
            .foregroundStyle(NotchTokens.Foreground.secondary)
            .frame(width: slot.width, height: slot.height)
            .contentShape(Rectangle())
            .onTapGesture {
                NotesModel.shared.createNoteFromCompactIcon(hostController: context.hostController)
            }
            .help(L("notes.newNote"))
            .accessibilityLabel(L("notes.newNote"))
    }
}
