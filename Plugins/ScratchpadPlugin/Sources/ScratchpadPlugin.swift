import AppKit
import NotchCenterKit
import SwiftUI

/// ScratchpadPlugin（官方文件暂存插件，由 NotchNotes 的 FileShelfStore/FileShelfView 移植而来）。
/// 提供一个紧凑块（点击展开抽屉）与一个抽屉块（文件暂存区，只保存路径引用）。
@objc(ScratchpadPlugin) @MainActor public final class ScratchpadPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: "scratchpad.compact",
            displayName: L("block.compact.name"),
            kind: .compact,
            // 自定义交互：点击 = 确认后清空暂存区。
            interaction: .custom,
            symbolName: "tray",
            makeView: { context in
                AnyView(ScratchpadCompactView(context: context))
            }
        ),
        NotchBlock(
            id: "scratchpad.shelf",
            displayName: L("block.shelf.name"),
            kind: .drawer,
            supportedSizes: [.medium, .large, .wide, .extraLarge],
            defaultSize: .large,
            // 自由跨度：网格上限内的所有组合（1×1 到 4×4）都支持。
            supportedGridSpans: Set(
                (1...4).flatMap { columns in
                    (1...4).map { rows in
                        GridSpan(columns: columns, rows: rows)
                    }
                }
            ),
            symbolName: "tray.full",
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

/// 紧凑块：暂存图标 + 条目数量角标；点击 = 确认后清空暂存区（.custom 交互）。
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
        .contentShape(Rectangle())
        .onTapGesture {
            // 仅在暂存区有内容时请求确认；空区点击无操作。
            guard itemCount > 0 else { return }
            workspaceState.isClearConfirmationPending = true
            // 抽屉收起时先展开，确认浮层显示在抽屉块内。
            context.hostController.expandDrawer()
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
            .overlay {
                if workspaceState.isClearConfirmationPending {
                    ClearConfirmationOverlay(
                        itemCount: store.items.count,
                        onConfirm: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                store.removeAll()
                                workspaceState.isClearConfirmationPending = false
                            }
                        },
                        onCancel: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                workspaceState.isClearConfirmationPending = false
                            }
                        }
                    )
                }
            }
        }
        .onAppear {
            NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
        }
        .onChange(of: store.items.count) { _, _ in
            NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
        }
    }
}

/// 清空确认浮层：显示在抽屉块可视区域内（不弹独立窗口——面板会随鼠标
/// 移开收起，独立弹窗层级/激活状态都不可靠）。半透明遮罩 + 居中卡片，
/// 视觉遵循 DESIGN.md 深色语言。
private struct ClearConfirmationOverlay: View {
    let itemCount: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 12) {
                Image(systemName: "tray.and.trash")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))

                Text(L("clear.confirm.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                // 中英复数习惯不同：en 单数走独立键（无占位符），zh 两键同文。
                if itemCount == 1 {
                    Text(L("clear.confirm.message.one"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(LF("clear.confirm.message", itemCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button(action: onCancel) {
                        Text(L("common.cancel"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Button(action: onConfirm) {
                        Text(L("clear.confirm.removeAll"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.red.opacity(0.75))
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.105))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .padding(16)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }
}