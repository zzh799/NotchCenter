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

    /// 抽屉揭示进度（0 = 刘海尺寸，1 = 完整抽屉）：驱动“从刘海展开”的
    /// 灵动岛式变形动画（窗口尺寸不变，视图内遮罩插值缩放）。
    @Published var revealProgress: CGFloat = 0

    /// 抽屉是否展开（用于内容命中测试开关）。
    @Published var isDrawerExpanded = false

    /// 紧凑区布局与元素（随屏幕切换/布局编辑变化）。
    @Published var compactLayout: NotchLayout
    @Published var compactElements: [CompactElement] = []
    @Published var compactCatalog: [CompactCatalogItem] = []
    @Published var canAddCompact = true
    @Published var showsClickModeHint = false

    /// 抽屉网格内容与目录侧边栏。
    @Published var drawerContentSize: CGSize = .zero
    @Published var drawerWindowSize: CGSize = .zero
    @Published var drawerElements: [DrawerElement] = []
    @Published var catalogPlugins: [CatalogPluginGroup] = []

    init(compactLayout: NotchLayout) {
        self.compactLayout = compactLayout
    }
}
