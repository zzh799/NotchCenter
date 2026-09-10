import AppKit
import NotchCenterKit
import SwiftUI

/// 抽屉块容器：稳定身份 + 块视图 + 编辑模式（文档 §5.5）。
/// - 拖动整块移动：拖动中实时预览（被占用块向下推挤自动重排），松手提交；
/// - 右下角握把拖动调整尺寸，缩放过程中组件左上角保持不动；
/// - 左上角设置按钮（插件提供设置界面时，经 SettingPopover 弹出）+ 右上角
///   移除按钮 + 右下角缩放握把，均跟随块一起移动；
/// - **设置按钮**只要块有设置界面，指针悬停即出现（不再要求编辑模式，设置是
///   高频可达入口）；**移除与缩放握把**仍收在"编辑模式 + 悬停"里（布局类操作
///   归编辑模式，保住"编辑模式 = 可以动布局"这个既有心智）；
/// - 整页块（`isPage`）不可拖动——它恒占满整页，没有"位置"可言；
/// - 设置 / 移除 / 缩放握把共用组件默认圆形按钮样式（Kit `IconCircleBadge`）。
struct DrawerBlockContainer: View {
    let element: DrawerElement
    let isEditing: Bool
    let isDragging: Bool
    /// 插件是否提供设置界面（设置齿轮按钮的显隐条件）。
    let hasSettings: Bool
    /// 是否整页块（独占整页）：不可拖动。
    let isPage: Bool
    /// 滑动中暂停手势。
    var isSwipeActive: Bool = false
    /// 缩放预览目标（由父视图持有；nil 表示未在缩放）。
    let previewColumns: Int?
    let previewRows: Int?
    let onResizeChanged: (CGSize) -> Void
    let onResizeCommit: () -> Void
    let onRemove: () -> Void
    /// 弹出插件设置浮窗（参数为块当前全局 frame，作为 SettingPopover 锚点）。
    let onShowSettings: (CGRect) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    /// 块当前全局 frame（窗口坐标，不含拖拽位移）：设置浮窗的锚定矩形。
    @State private var globalFrame: CGRect = .zero

    @State private var dragOffset: CGSize = .zero
    /// 指针是否悬停在本块上：编辑角标的显示条件（角标恒落在块矩形内）。
    @State private var isHovering = false

    var body: some View {
        let columns = previewColumns ?? element.placement.widthColumns
        let rows = previewRows ?? element.placement.heightRows
        let metrics = GridMetrics.current
        let width = metrics.width(columns: columns)
        let height = metrics.height(rows: rows)
        // 缩放预览补偿：容器被外层按旧尺寸居中定位，内部变大会以中心对称扩张。
        // 把增长量的一半平移回来，使组件左上角始终锚定在原点（原点不随缩放改变）。
        let compensation = ResizeCompensation.offset(
            from: GridSpan(
                columns: element.placement.widthColumns,
                rows: element.placement.heightRows
            ),
            to: GridSpan(columns: columns, rows: rows),
            metrics: metrics
        )

        // 预览尺寸必须显式套在内容上（含所有 overlay），否则块永远按外层
        // 提案的原始尺寸渲染，补偿偏移会退化成纯位移（上移/下移半行的来源）。
        return element.view
            .frame(width: width, height: height)
            .background(isEditing ? NotchTokens.Surface.fill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous))
            // 锚定矩形捕获：挂在 clip 之后、offset 之前——量的是块的逻辑
            // 位置（不含拖拽/缩放补偿位移），齿轮点击时上报给设置浮窗。
            .background {
                GlobalFrameReader { globalFrame = $0 }
            }
            // 编辑模式压暗层：透明黑盖住块内容，弱化内容细节、衬托其上的
            // 白色描边与编辑角标。圆角与 clipShape 对齐，避免方角黑块露出
            // 圆角外。同时仍是手势屏蔽层：屏蔽块内容自身手势（如文本选中），
            // 让拖动/缩放在所有块上行为一致。所有层都用 overlay 而非 ZStack：
            // overlay 尺寸严格等于内容本身，不会被外层旧尺寸的 proposal 撑大
            // （否则缩小到 1 行时位置会上偏半行）。
            .overlay {
                if isEditing {
                    RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .contentShape(Rectangle())
                }
            }
            .overlay {
                if isEditing {
                    // 编辑模式高亮组件边缘（绘制在压暗层之上，保持清晰）。
                    RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous)
                        .stroke(
                            (isDragging || isResizing ? NotchTokens.Foreground.secondary : NotchTokens.Foreground.disabled),
                            lineWidth: isDragging || isResizing ? 1.5 : 1
                        )
                }
            }
            .overlay(alignment: .topLeading) {
                if showsSettingsControl && hasSettings {
                    // 左上角设置按钮：经 SettingPopover 展示插件设置。
                    IconCircleButton(
                        systemImage: "gearshape",
                        helpText: L("panel.help.pluginSettings")
                    ) {
                        onShowSettings(globalFrame)
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsEditControls {
                    IconCircleButton(
                        systemImage: "xmark",
                        helpText: L("panel.help.removeBlock")
                    ) {
                        onRemove()
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsEditControls {
                    // 右下角缩放握把：唯一的调整尺寸入口，向右下拖动扩大、
                    // 左上角原点保持不动，松手在支持的尺寸等级间吸附。
                    resizeHandle
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: showsSettingsControl)
            .animation(.easeOut(duration: 0.12), value: showsEditControls)
            .offset(compensation)
            .offset(dragOffset)
            .gesture(
                // 整页块不可拖动：它恒占满整页、没有"位置"，唯一能调的几何是
                // 跨度（右下握把）。引擎侧的 moveDrawerBlock 也有同一道守卫。
                isEditing && !isResizing && !isSwipeActive && !isPage
                    ? DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            dragOffset = value.translation
                            onDragChanged(value.translation)
                        }
                        .onEnded { value in
                            withAnimation(DrawerAnimation.spring) {
                                dragOffset = .zero
                            }
                            onDragEnded(value.translation)
                        }
                    : nil
            )
            // 缩放预览跨度变化（新行/新列）时容器尺寸 spring 变形：
            // 与面板扩大/其余块推挤同一动画（同帧完成，不等松手）。
            .animation(
                DrawerAnimation.spring,
                value: ResizePreviewState(columns: previewColumns, rows: previewRows)
            )
    }

    /// 缩放预览状态的等值封装（供 .animation(value:) 比较）。
    private struct ResizePreviewState: Equatable {
        let columns: Int?
        let rows: Int?
    }

    private var isResizing: Bool {
        previewColumns != nil || previewRows != nil
    }

    /// 设置齿轮的显隐：只要有设置界面，指针悬停（或手势进行中）即出现。
    /// **不再要求编辑模式**——设置是高频可达入口，藏在编辑模式后面反直觉；
    /// 布局类操作（移除 / 缩放）仍留在编辑模式，见 `showsEditControls`。
    private var showsSettingsControl: Bool {
        hasSettings && (isHovering || isDragging || isResizing)
    }

    /// 移除与缩放握把的显隐：编辑模式下随指针悬停。
    /// 手势进行中强制保持：拖动时被拖块会落到相邻块之下（ZStack 次序不变、
    /// 不抬升 z），相邻块抢走 hover；缩放时预览尺寸按格吸附、滞后于光标，
    /// 向外拖的那一瞬指针会落在块矩形之外——任一情况都会让角标
    /// 在手势半路凭空消失。
    private var showsEditControls: Bool {
        isEditing && (isHovering || isDragging || isResizing)
    }

    // MARK: 编辑控件（跟随块移动）

    @State private var isResizeHandleHovering = false

    /// 右下角缩放握把：对角双箭头图标（组件默认圆形按钮样式），
    /// 悬停 / 拖动中增亮，拖动中放大。
    private var resizeHandle: some View {
        IconCircleBadge(
            systemImage: "arrow.up.left.and.arrow.down.right",
            isHighlighted: isResizing || isResizeHandleHovering
        )
        .scaleEffect(isResizing ? 1.12 : 1)
        // 缩放握把拾起弹入：原自造 0.24/0.72 收敛至抽屉几何 spring 族。
        .animation(NotchTokens.Motion.expand, value: isResizing)
        .padding(5)
        .contentShape(Rectangle())
        .onHover { isResizeHandleHovering = $0 }
        .highPriorityGesture(resizeGesture)
        .help(L("panel.help.resize"))
    }

    /// 缩放手势：基于位移增量的目标格数。**平移量必须在稳定坐标系度量**
    /// （`.global` 锚定窗口，拖拽期间窗口不动）：默认的 `.local` 空间挂在
    /// 握把上，预览每长一格，握把连同其 local 空间整体平移一格，translation
    /// 瞬间反跳一整格——死区无法吸收，形成“增长 → 平移量清零 → 缩回 →
    /// 恢复”的逐事件自激振荡（原大小/目标大小逐像素切换）。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard !isSwipeActive else { return }
                onResizeChanged(value.translation)
            }
            .onEnded { _ in
                guard !isSwipeActive else { return }
                onResizeCommit()
            }
    }
}
