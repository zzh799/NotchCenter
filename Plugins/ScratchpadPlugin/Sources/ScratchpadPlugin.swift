import AppKit
import NotchCenterKit
import SwiftUI

/// ScratchpadPlugin（官方文件暂存插件，由 NotchNotes 的 FileShelfStore/FileShelfView 移植而来）。
/// 提供一个紧凑块（点击展开抽屉）与一个抽屉块（文件暂存区，只保存路径引用）。
@objc(ScratchpadPlugin) @MainActor public final class ScratchpadPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "scratchpad.compact",
            displayName: "Scratchpad",
            kind: .compact,
            makeView: { context in
                AnyView(ScratchpadCompactView(context: context))
            }
        ),
        NotchBlock(
            id: "scratchpad.shelf",
            displayName: "File Shelf",
            kind: .drawer,
            supportedSizes: [.medium, .large, .wide, .extraLarge],
            defaultSize: .large,
            makeView: { context in
                AnyView(ScratchpadShelfBlockView(context: context))
            }
        )
    ]

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        _ = ScratchpadModel.shared.resolve(stateStore: stateStore)
    }
}

/// 插件内共享模型：紧凑块与抽屉块共享同一 ScratchpadStore。
@MainActor
private final class ScratchpadModel {
    static let shared = ScratchpadModel()

    private(set) var store: ScratchpadStore?
    private(set) var workspaceState = ScratchpadWorkspaceState()

    func resolve(stateStore: StateStore) -> ScratchpadStore {
        if let store { return store }
        let newStore = ScratchpadStore(stateStore: stateStore)
        store = newStore
        return newStore
    }
}

/// 紧凑块：暂存图标 + 条目数量角标；点击由核心默认展开抽屉。
private struct ScratchpadCompactView: View {
    let context: BlockContext
    @StateObject private var workspaceState: ScratchpadWorkspaceState
    @State private var itemCount = -1

    init(context: BlockContext) {
        self.context = context
        _workspaceState = StateObject(wrappedValue: ScratchpadModel.shared.workspaceState)
    }

    var body: some View {
        // 跟随宿主分配的槽位尺寸（紧凑区为刘海高度带内的小槽位）。
        let slot = context.layoutInfo.frame.size
        return ZStack(alignment: .topTrailing) {
            Image(systemName: "tray")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: slot.width, height: slot.height)
                .contentShape(Rectangle())

            if itemCount > 0 {
                Text("\(itemCount)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.18)))
                    .offset(x: -2, y: 2)
            }
        }
        .onAppear {
            if let store = ScratchpadModel.shared.store {
                itemCount = store.items.count
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scratchpadItemsDidChange)) { _ in
            itemCount = ScratchpadModel.shared.store?.items.count ?? -1
        }
    }
}

extension Notification.Name {
    static let scratchpadItemsDidChange = Notification.Name("ScratchpadPlugin.itemsDidChange")
}

/// 抽屉块：几何自适应尺寸的文件暂存区。
private struct ScratchpadShelfBlockView: View {
    let context: BlockContext
    @StateObject private var store: ScratchpadStore
    @StateObject private var workspaceState: ScratchpadWorkspaceState

    init(context: BlockContext) {
        self.context = context
        _store = StateObject(wrappedValue: ScratchpadModel.shared.resolve(stateStore: context.stateStore))
        _workspaceState = StateObject(wrappedValue: ScratchpadModel.shared.workspaceState)
    }

    var body: some View {
        GeometryReader { proxy in
            FileShelfView(
                store: store,
                workspaceState: workspaceState,
                size: proxy.size
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
        }
        .onChange(of: store.items.count) { _, _ in
            NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
        }
    }
}