import Foundation
import NotchCenterKit

/// 面板 UI 状态（ObservableObject）：由控制器更新、SwiftUI 视图直接观察。
///
/// 面板内容不再通过重新赋值 `NSHostingView.rootView` 刷新——在透明无边框的
/// `NSPanel` 上该路径不能保证立即重绘（表现为按钮图标等要等下次窗口操作才更新），
/// 改为 `@Published` 驱动 SwiftUI 自身的刷新管线。宿主视图只在创建时设置一次 root。
@MainActor
final class PanelUIState: ObservableObject {
    @Published var isPinned = false
    @Published var isEditing = false

    /// 可见面板尺寸（参考 codex-island 的 model.size：唯一动画真源）：
    /// 收起 = 紧凑带尺寸（宽=带、高=0 内容），展开 = 完整抽屉。一切尺寸
    /// 变化都在 withAnimation 里发生，容器 frame 直接绑定它做 spring 变形
    /// ——窗口 frame 永不参与动画（固定满高窗口）。
    @Published var drawerWindowSize: CGSize = .zero

    /// 抽屉是否展开（内容存在性与命中测试开关）。
    @Published var isDrawerExpanded = false

    /// 紧凑区元素（随屏幕切换/布局编辑变化）。紧凑带几何（刘海尺寸、
    /// 槽位布局）不在这里——它按屏幕各异，由各面板以 `layout` 参数持有
    /// （热区/抽屉视图用所属 pair 的几何，不共享主屏几何）。
    @Published var compactElements: [CompactElement] = []
    /// 当前紧凑图标数：紧凑带宽度随其动态伸缩（视图侧槽位几何 =
    /// layout.compactStrip(slotCount: compactCount)）。控制器在每次内容
    /// 重建时同步。
    @Published var compactCount = 0
    @Published var showsClickModeHint = false

    /// 抽屉网格内容与 AddBlock 目录条（编辑模式）。
    /// 可见面板尺寸见上方 `drawerWindowSize`（唯一动画真源）。
    @Published var drawerContentSize: CGSize = .zero
    /// 格网内容最左列（列双向扩大：左侧拖出时可为负）：块渲染横坐标 =
    /// (originColumn − 该值) × 步长，使左扩时内容整体右移、面板绕刘海对称增宽。
    @Published var drawerGridLeftColumn = 0
    @Published var drawerElements: [DrawerElement] = []
    @Published var catalogPlugins: [CatalogPluginGroup] = []

    /// 从设置面板拖拽组件时的落点预览（抽屉网格虚线占位 / 快速区插入指示）。
    /// 仅在拖拽会话期间非空，由 `BlockDragCoordinator` 经控制器写入。
    @Published var dropPreview: DropPreview?

    struct DropPreview: Equatable {
        let zone: BlockDragCoordinator.DropZone
        /// 被拖的是快捷按钮（紧凑块）：快速区画插入指示，不画网格占位。
        let isCompact: Bool
        let title: String
        /// 光标横坐标（紧凑带内容坐标）：插入指示线据此跟随光标——快速区为空
        /// （没有槽位可参照）时，指示线不能只画在刘海中心。
        let compactPointerX: CGFloat?
        /// 编辑模式内部重排时被拖图标的数组下标（从设置面板拖入为 nil）。
        /// 非空时视图按“插入后的屏幕顺序”给每个图标算显示槽位——
        /// 拖动过程中其余图标平滑让位。
        let draggingSlotIndex: Int?

        init(
            zone: BlockDragCoordinator.DropZone,
            isCompact: Bool,
            title: String,
            compactPointerX: CGFloat? = nil,
            draggingSlotIndex: Int? = nil
        ) {
            self.zone = zone
            self.isCompact = isCompact
            self.title = title
            self.compactPointerX = compactPointerX
            self.draggingSlotIndex = draggingSlotIndex
        }

        /// 拖动目标是否与另一份预览一致（忽略逐帧变化的光标坐标）：
        /// 仅目标变化时才带动画更新，否则每帧都会重启动画。
        func matchesTarget(of other: DropPreview) -> Bool {
            zone == other.zone
                && isCompact == other.isCompact
                && draggingSlotIndex == other.draggingSlotIndex
        }
    }
}
