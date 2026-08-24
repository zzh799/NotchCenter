import AppKit
import NotchCenterKit
import SwiftUI

/// ScratchpadPlugin（官方文件暂存插件，由 NotchNotes 的 FileShelfStore/FileShelfView 移植而来）。
/// 提供一个紧凑块（点击弹出清空确认浮窗）与一个抽屉块（文件暂存区，只保存路径引用）。
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

/// 紧凑块：暂存图标 + 条目数量角标；点击/长按 = 弹出「清空暂存区」确认浮窗
/// （Kit 的 BlockPopover：单例互斥、点击外部关闭、收回抽屉时随之消失）。
private struct ScratchpadCompactView: View {
    let context: BlockContext
    @State private var itemCount = -1

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
        // 锚点追踪与手势分类统一走 Kit 触发器；点击与长按都弹同一确认浮窗。
        .blockPopoverTrigger(
            onTap: { frame in presentClearConfirmation(anchoredTo: frame) },
            onLongPress: { frame in presentClearConfirmation(anchoredTo: frame) }
        )
    }

    /// 仅在暂存区有内容时弹确认；空区点击无操作。不再先展开抽屉——
    /// 浮窗贴在本图标下方弹出（紧凑图标位于屏幕最顶端），独立于抽屉开合。
    private func presentClearConfirmation(anchoredTo frameInWindow: CGRect) {
        guard itemCount > 0, let store = ScratchpadModel.shared.store else { return }
        BlockPopover.shared.present(
            anchoredTo: frameInWindow,
            cardSize: ClearConfirmationPopoverContentView.cardSize,
            placement: .below
        ) {
            ClearConfirmationPopoverContentView(store: store)
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

/// 清空确认浮窗内容（窗口、外观与弹出动画由 Kit 的 BlockPopover 统一提供，
/// 这里只排布内容）。确认后清空全部暂存引用——只移除路径记录，原文件不受影响。
private struct ClearConfirmationPopoverContentView: View {
    @ObservedObject var store: ScratchpadStore

    /// 卡片尺寸（BlockPopover 需要定值；高度留足双行提示文案的余量）。
    static let cardSize = CGSize(width: 220, height: 184)

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.trash")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            Text(L("clear.confirm.title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            // 中英复数习惯不同：en 单数走独立键（无占位符），zh 两键同文。
            Group {
                if store.items.count == 1 {
                    Text(L("clear.confirm.message.one"))
                } else {
                    Text(LF("clear.confirm.message", store.items.count))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: { BlockPopover.shared.dismiss() }) {
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

                Button(action: clearAll) {
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
            }
        }
        .padding(14)
    }

    private func clearAll() {
        store.removeAll()
        // 抽屉块可能不在屏（收起态直接清空）：主动广播，紧凑角标立即刷新。
        NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
        BlockPopover.shared.dismiss()
    }
}