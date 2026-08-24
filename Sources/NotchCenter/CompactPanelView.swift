import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 紧凑区面板（文档 §5.2）

/// 紧凑面板元素：一个槽位及其块视图。
struct CompactElement: Identifiable {
    let slotIndex: Int
    let reference: CompactSlotReference?
    let block: NotchBlock?
    let view: AnyView?
    let frame: CGRect

    var id: Int { slotIndex }
}

struct CompactActions {
    let onRemoveBlock: (Int) -> Void
    let onTapBackground: () -> Void
    let onExpand: () -> Void
}

struct CompactPanelView: View {
    @ObservedObject var ui: PanelUIState
    /// 本面板所在屏幕的刘海/回退几何（每屏一份：外接屏回退与内建屏实测
    /// 刘海的宽度/槽位布局不同，不能共享主屏几何，否则非主屏条带偏心、
    /// 图标相对物理刘海错位）。
    var layout: NotchLayout
    let actions: CompactActions
    /// 是否自绘黑色底衬（独立热区窗口为 true；嵌入抽屉岛顶时为 false，
    /// 由抽屉统一背景提供，避免叠加描边/阴影）。
    var showsBand = true

    @State private var isHovering = false

    private let cornerRadius: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let isEditing = ui.isEditing
            // 条带宽度随当前紧凑图标数动态伸缩（视图侧按 uiState 的数量计算，
            // layout 只携带屏幕相关的刘海/高度部分）。
            let strip = layout.compactStrip(slotCount: ui.compactCount)
            let panelHeight = proxy.size.height

            // .top 对齐让黑色带在窗口内水平居中（其余元素均为绝对定位），
            // 与抽屉遮罩的中心对称展开、刘海位置保持一致。
            ZStack(alignment: .top) {
                // 整条黑色填充带：横跨左右面板并覆盖刘海区域，
                // 与刘海融为一体（灵动岛观感，文档 §5.2）。
                if showsBand {
                    TopAttachedRoundedShape(radius: cornerRadius)
                        .fill(
                            Color(red: 0.02, green: 0.02, blue: 0.025)
                                .opacity(isHovering ? 0.99 : 0.96)
                        )
                        .overlay {
                            TopAttachedRoundedShape(radius: cornerRadius)
                                .stroke(.white.opacity(isHovering ? 0.15 : 0.09), lineWidth: 1)
                        }
                        .shadow(
                            color: .black.opacity(isHovering ? 0.32 : 0.18),
                            radius: 12,
                            y: 5
                        )
                        .frame(width: strip.rightPanelX + strip.rightPanelWidth, height: panelHeight)
                }

                // click 模式下的悬停指示条（位于刘海中央）。
                if ui.showsClickModeHint, isHovering, !isEditing {
                    Capsule()
                        .fill(.white.opacity(0.72))
                        .frame(width: 48, height: 2)
                        .shadow(color: .white.opacity(0.32), radius: 4)
                        .position(x: strip.notchCenterX, y: 7)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }

                // 点击热区：整帧可交互，点击空白处展开抽屉（块视图在上层优先响应）。
                Color.black.opacity(0.0001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: actions.onTapBackground)

                ForEach(ui.compactElements) { element in
                    if let view = element.view {
                        let rect = strip.slotRect(at: element.slotIndex) ?? .zero
                        CompactBlockContainer(
                            element: element,
                            view: view,
                            isEditing: isEditing,
                            onRemove: { actions.onRemoveBlock(element.slotIndex) },
                            onExpand: actions.onExpand
                        )
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// 紧凑块容器：槽位内的块视图 + 默认点击展开（文档 §6.2）+ 编辑模式移除。
private struct CompactBlockContainer: View {
    let element: CompactElement
    let view: AnyView
    let isEditing: Bool
    let onRemove: () -> Void
    let onExpand: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            group
                .frame(width: NotchGeometry.compactSlotSize.width, height: NotchGeometry.compactSlotSize.height)

            if isEditing {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -2)
                .help(L("panel.help.removeBlock"))
            }
        }
    }

    @ViewBuilder
    private var group: some View {
        if element.block?.interaction == .expandDrawer {
            // 默认交互：点击展开抽屉（文档 §6.2）。
            view
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)
        } else {
            // .custom 交互由插件视图自行处理；核心不拦截点击。
            view
        }
    }
}
