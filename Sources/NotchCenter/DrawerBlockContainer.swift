import AppKit
import SwiftUI

/// 抽屉块容器：稳定身份 + 块视图 + 编辑模式（文档 §5.5）。
/// - 拖动整块移动：拖动中实时预览（被占用块向下推挤自动重排），松手提交；
/// - 右下角握把拖动调整尺寸，缩放过程中组件左上角保持不动；
/// - 移除按钮跟随块一起移动。
struct DrawerBlockContainer: View {
    let element: DrawerElement
    let isEditing: Bool
    let isDragging: Bool
    /// 缩放预览目标（由父视图持有；nil 表示未在缩放）。
    let previewColumns: Int?
    let previewRows: Int?
    let onResizeChanged: (CGSize) -> Void
    let onResizeCommit: () -> Void
    let onRemove: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    @State private var dragOffset: CGSize = .zero

    private let cornerRadius: CGFloat = 12

    var body: some View {
        let columns = previewColumns ?? element.placement.widthColumns
        let rows = previewRows ?? element.placement.heightRows
        let width = NotchGridMetrics.contentWidth(columns: columns)
        let height = NotchGridMetrics.contentHeight(rows: rows)
        // 缩放预览补偿：容器被外层按旧尺寸居中定位，内部变大会以中心对称扩张。
        // 把增长量的一半平移回来，使组件左上角始终锚定在原点（原点不随缩放改变）。
        let deltaWidth = width - NotchGridMetrics.contentWidth(columns: element.placement.widthColumns)
        let deltaHeight = height - NotchGridMetrics.contentHeight(rows: element.placement.heightRows)

        // 预览尺寸必须显式套在内容上（含所有 overlay），否则块永远按外层
        // 提案的原始尺寸渲染，补偿偏移会退化成纯位移（上移/下移半行的来源）。
        return element.view
            .frame(width: width, height: height)
            .background(isEditing ? Color.white.opacity(0.03) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if isEditing {
                    // 编辑模式高亮组件边缘。
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            .white.opacity(isDragging || isResizing ? 0.75 : 0.4),
                            lineWidth: isDragging || isResizing ? 1.5 : 1
                        )
                }
            }
            // 编辑模式交互层：屏蔽块内容自身手势（如文本选中），
            // 让拖动/缩放在所有块上行为一致。所有层都用 overlay——
            // 尺寸严格等于内容本身，不会被外层的旧尺寸 proposal 撑大
            // （此前用 ZStack + 弹性子视图，缩小到 1 行时位置会上偏半行）。
            .overlay {
                if isEditing {
                    Color.clear.contentShape(Rectangle())
                }
            }
            .overlay(alignment: .topTrailing) {
                if isEditing {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Remove block")
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isEditing {
                    // 右下角缩放握把：唯一的调整尺寸入口，向右下拖动扩大、
                    // 左上角原点保持不动，松手在支持的尺寸等级间吸附。
                    resizeHandle
                }
            }
            .contentShape(Rectangle())
            .offset(x: deltaWidth / 2, y: deltaHeight / 2)
            .offset(dragOffset)
            .gesture(
                isEditing && !isResizing
                    ? DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            dragOffset = value.translation
                            onDragChanged(value.translation)
                        }
                        .onEnded { value in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                dragOffset = .zero
                            }
                            onDragEnded(value.translation)
                        }
                    : nil
            )
    }

    private var isResizing: Bool {
        previewColumns != nil || previewRows != nil
    }

    // MARK: 编辑控件（跟随块移动）

    @State private var isResizeHandleHovering = false

    /// 右下角缩放握把：对角双箭头图标 + 圆形底衬，悬停/拖动中增亮放大。
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(isResizing ? 0.95 : 0.7))
            .frame(width: 22, height: 22)
            .background {
                Circle()
                    .fill(.white.opacity(isResizing ? 0.28 : 0.14))
                    .overlay {
                        Circle()
                            .stroke(
                                .white.opacity(isResizing ? 0.55 : 0.25),
                                lineWidth: 1
                            )
                    }
            }
            .scaleEffect(isResizing ? 1.12 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isResizing)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .padding(5)
            .contentShape(Rectangle())
            .onHover { isResizeHandleHovering = $0 }
            .background {
                if isResizeHandleHovering, !isResizing {
                    Circle()
                        .fill(.white.opacity(0.08))
                        .padding(2)
                }
            }
            .highPriorityGesture(resizeGesture)
            .help("Drag to resize")
    }

    /// 缩放手势：基于位移增量的目标格数。**平移量必须在稳定坐标系度量**
    /// （`.global` 锚定窗口，拖拽期间窗口不动）：默认的 `.local` 空间挂在
    /// 握把上，预览每长一格，握把连同其 local 空间整体平移一格，translation
    /// 瞬间反跳一整格——死区无法吸收，形成“增长 → 平移量清零 → 缩回 →
    /// 恢复”的逐事件自激振荡（原大小/目标大小逐像素切换）。复刻复现与
    /// 日志见 `ResizeProbe`（NOTCHCENTER_RESIZE_PROBE=1）。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                onResizeChanged(value.translation)
            }
            .onEnded { _ in
                onResizeCommit()
            }
    }
}
