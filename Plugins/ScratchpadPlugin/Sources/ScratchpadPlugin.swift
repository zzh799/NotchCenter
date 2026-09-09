import AppKit
import NotchCenterKit
import SwiftUI

/// ScratchpadPlugin（官方文件暂存插件，由 NotchNotes 的 FileShelfStore/FileShelfView 移植而来）。
/// 提供一个紧凑块（点击弹出清空确认浮窗）与一个抽屉块（文件暂存区，只保存路径引用）。
/// 抽屉块支持同一块类型放置多个实例：每个实例的条目持久化在 Kit 的
/// placementStore（见 BlockContext.placementStore），互不干扰；
/// 旧版存在插件级的共享数据在首个新实例创建时自动迁入。紧凑块是全局
/// 聚合视图：角标 = 全部实例条目之和，点击 = 确认后清空所有实例。
@objc(ScratchpadPlugin) @MainActor public final class ScratchpadPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    /// 快捷动作 id：沿用旧紧凑块 id（旧布局槽位无需迁移即指向该动作）。
    private static let compactActionID = "scratchpad.compact"
    private static let shelfBlockID = "scratchpad.shelf"

    public static var blocks: [NotchBlock] = [
        NotchBlock(
            id: ScratchpadPlugin.shelfBlockID,
            displayName: L("block.shelf.name"),
            kind: .drawer,
            minSize: BlockPixelSize(width: 150, height: 120),
            maxSize: BlockPixelSize(width: 600, height: 480),
            // 推荐 2×2（默认档）；允许盒内任意整数跨——原先 1×1 到 4×4 的
            // 自由跨度集合即为全矩形盒，声明语义等价。
            recommendedSize: BlockPixelSize(width: 300, height: 240),
            // 横向文件架：内容溢出时滑动让路归文件架（宿主探针核实），
            // 空/未满放行切页。
            symbolName: "tray.full",
            probes: { info in
                // 打包期最小尺寸遮挡校验：整面自适应文件架（横向 ScrollView +
                // 纵向 padding 6；内容超高/超宽均内部滚动，结构上不溢出邻居），
                // 声明内容区为唯一探针——minSize 比 12pt 内边距还小时越界报警。
                let size = info.frame.size
                let inset: CGFloat = 6
                return [
                    BlockProbe(
                        id: "shelf.content",
                        rect: CGRect(
                            x: inset, y: inset,
                            width: max(size.width - inset * 2, 0),
                            height: max(size.height - inset * 2, 0))),
                ]
            },
            makeView: { context in
                AnyView(ScratchpadShelfBlockView(context: context))
            }
        )
    ]

    // MARK: 快捷动作

    private var quickActionCache: [QuickAction]?

    public var quickActions: [QuickAction] {
        if let quickActionCache { return quickActionCache }
        // 前身即默认进带的 `scratchpad.compact` 紧凑块：语义一致（有内容才弹
        // 确认，确认后清空全部实例的暂存引用——只移除路径记录，原文件不动）。
        let action = QuickAction(
            id: ScratchpadPlugin.compactActionID,
            displayName: L("block.compact.name"),
            systemImage: "tray",
            kind: .action,
            requiresConfirmation: true,
            defaultInStrip: true,
            execute: { [weak self] in
                self?.clearAllInstancesFromQuickAction()
            }
        )
        quickActionCache = [action]
        return quickActionCache!
    }

    private func clearAllInstancesFromQuickAction() {
        let registry = ScratchpadInstanceRegistry.shared
        guard registry.totalItemCount > 0 else { return }
        registry.removeAll()
        NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
    }

    public override init() {
        super.init()
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        ScratchpadInstanceRegistry.shared.attach(pluginStateStore: stateStore)
    }

    public func placementWasRemoved(blockID: String, placementID: String) {
        // 只清理该实例私有的暂存记录（只移除路径记录，原文件不受影响）。
        guard blockID == Self.shelfBlockID else { return }
        ScratchpadInstanceRegistry.shared.discard(placementID: placementID)
        NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
    }
}

/// 紧凑块：暂存图标 + 条目数量角标；点击/长按 = 弹出「清空暂存区」确认浮窗
/// （Kit 的 BlockPopover：单例互斥、点击外部关闭、收回抽屉时随之消失）。
private struct ScratchpadCompactView: View {
    let context: BlockContext
    @State private var itemCount = -1

    var body: some View {
        let slot = context.layoutInfo.frame.size
        return ZStack(alignment: .topTrailing) {
            Image(systemName: "tray")
                .font(NotchTokens.Text.system(13, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .frame(width: slot.width, height: slot.height)
                .contentShape(Rectangle())

            if itemCount > 0 {
                Text("\(itemCount)")
                    .font(NotchTokens.Text.system(8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.18)))
                    .offset(x: -2, y: 2)
            }
        }
        .onAppear {
            itemCount = ScratchpadInstanceRegistry.shared.totalItemCount
        }
        .onReceive(NotificationCenter.default.publisher(for: .scratchpadItemsDidChange)) { _ in
            itemCount = ScratchpadInstanceRegistry.shared.totalItemCount
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
        guard itemCount > 0 else { return }
        BlockPopover.shared.present(
            anchoredTo: frameInWindow,
            cardSize: ClearConfirmationPopoverContentView.cardSize,
            placement: .below
        ) {
            ClearConfirmationPopoverContentView(registry: .shared)
        }
    }
}

extension Notification.Name {
    static let scratchpadItemsDidChange = Notification.Name("ScratchpadPlugin.itemsDidChange")
}

/// 抽屉块：几何自适应尺寸的文件暂存区。每个放置实例持有独立条目
/// （注册表按 placementID 缓存唯一 ObservableObject，多屏副本观察同一对象）。
private struct ScratchpadShelfBlockView: View {
    let context: BlockContext
    @StateObject private var store: ScratchpadStore
    @StateObject private var workspaceState = ScratchpadWorkspaceState()

    init(context: BlockContext) {
        self.context = context
        _store = StateObject(wrappedValue: ScratchpadInstanceRegistry.shared.store(
            placementID: context.placementID,
            stateStore: context.stateStore
        ))
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
/// 这里只排布内容）。确认后清空全部实例的暂存引用——只移除路径记录，原文件不受影响。
private struct ClearConfirmationPopoverContentView: View {
    let registry: ScratchpadInstanceRegistry

    /// 卡片尺寸（BlockPopover 需要定值；高度留足双行提示文案的余量）。
    static let cardSize = CGSize(width: 220, height: 184)

    var body: some View {
        let totalCount = registry.totalItemCount
        VStack(spacing: 12) {
            Image(systemName: "tray.and.trash")
                .font(NotchTokens.Text.system(20, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.hover)

            Text(L("clear.confirm.title"))
                .font(NotchTokens.Text.system(13, weight: .semibold))
                .foregroundStyle(.white)

            // 中英复数习惯不同：en 单数走独立键（无占位符），zh 两键同文。
            Group {
                if totalCount == 1 {
                    Text(L("clear.confirm.message.one"))
                } else {
                    Text(LF("clear.confirm.message", totalCount))
                }
            }
            .font(NotchTokens.Text.system(11))
            .foregroundStyle(NotchTokens.Foreground.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: { BlockPopover.shared.dismiss() }) {
                    Text(L("common.cancel"))
                        .font(NotchTokens.Text.system(11, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)

                Button(action: clearAll) {
                    Text(L("clear.confirm.removeAll"))
                        .font(NotchTokens.Text.toolbarSmall)
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
        registry.removeAll()
        // 抽屉块可能不在屏（收起态直接清空）：主动广播，紧凑角标立即刷新。
        NotificationCenter.default.post(name: .scratchpadItemsDidChange, object: nil)
        BlockPopover.shared.dismiss()
    }
}