import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 活动岛面板（插件活动状态的常驻小岛，文档 §4.10）

/// 活动岛布局常量。窗口固定尺寸（内容在其内自行 spring 变形，窗口 frame
/// 不参与动画——与抽屉同一教训：窗口跟随内容会裁剪 spring 变形中的内容、
/// 面板偏离屏幕中线）；透明区靠命中测试 + `ignoresMouseEvents` 双机制穿透。
@MainActor
enum ActivityIslandLayout {
    /// 岛窗口宽度（容纳展开态上限，多岛堆叠共用此宽度）。
    static let windowWidth: CGFloat = 460
    /// 岛窗口高度（容纳多岛堆叠的余量上限）。
    static let windowHeight: CGFloat = 320
    /// 岛顶与刘海底缘的间隙（岛从刘海下方"长出"的视觉分离）。
    static let topGap: CGFloat = 6
    /// 多岛堆叠间距。
    static let islandSpacing: CGFloat = 8
    /// 岛内容与底衬边距。
    static let islandPadding: CGFloat = 10
    /// 岛圆角（岛不贴屏幕顶缘，四角全圆，与刘海下方的紧凑带分离）。
    static let islandCornerRadius: CGFloat = 18
}

/// 固定尺寸活动岛窗口的宿主视图：窗口比当前内容大的部分永远是透明区，
/// 命中测试只放行「顶缘起、水平居中」的可见矩形，其余穿透到下层应用。
/// 与 DrawerHostingView 的差异：岛在窗口内水平居中且宽度可变，穿透判定
/// 同时检查横向；可见尺寸由 SwiftUI 侧经 `PanelUIState.islandVisibleSize`
/// 提供（含动画中间帧，逐帧回写，命中区域跟随内容变形）。
@MainActor
class IslandHostingView<Content: View>: FirstMouseHostingView<Content> {
    /// 当前可见内容尺寸。
    var visibleSizeProvider: (() -> CGSize)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard let visible = visibleSizeProvider?(),
              visible.width > 0.5, visible.height > 0.5 else {
            return nil
        }
        // hitTest 的 point 是父视图（窗口）坐标、y 自底向上：可见内容贴窗口顶缘。
        guard point.y >= bounds.height - visible.height else { return nil }
        // 内容水平居中：窗口比内容宽的部分同样穿透。
        let minX = (bounds.width - visible.width) / 2
        guard point.x >= minX, point.x <= minX + visible.width else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// 活动岛底衬（统一外观：近黑半透明 + 发丝描边 + 阴影，与抽屉同族质感）。
struct ActivityIslandChrome<IslandContent: View>: View {
    @ViewBuilder var content: () -> IslandContent

    var body: some View {
        content()
            .padding(ActivityIslandLayout.islandPadding)
            .background {
                RoundedRectangle(cornerRadius: ActivityIslandLayout.islandCornerRadius, style: .continuous)
                    .fill(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.97))
                    .overlay {
                        RoundedRectangle(cornerRadius: ActivityIslandLayout.islandCornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            }
    }
}

/// 回写自身尺寸（区别于 GlobalFrameReader 的 frame）：活动岛命中区域跟随
/// 内容的紧凑/展开变形与进出动画逐帧变化。
struct IslandSizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size) }
                .onChange(of: proxy.size) { _, size in onChange(size) }
        }
    }
}

/// 活动岛面板内容：把 `ui.activityIslands` 按提交顺序堆叠在刘海下方。
/// 抽屉展开期间整体让位（内容清空 → 可见尺寸归零 → 命中/光标跟踪全部穿透），
/// 收起后原位长回。窗口常驻（有活动岛时），视觉进出全部是窗口内动画。
struct ActivityIslandPanelView: View {
    @ObservedObject var ui: PanelUIState
    /// 可见内容尺寸回写（写入 PanelUIState.islandVisibleSize，窗口命中测试读取）。
    let onVisibleSizeChange: (CGSize) -> Void

    var body: some View {
        let islands = ui.isDrawerExpanded ? [] : ui.activityIslands
        VStack(spacing: ActivityIslandLayout.islandSpacing) {
            ForEach(islands) { island in
                // 岛内容自定尺寸（插件契约：不超过 maxSize）；不要套
                // maxWidth 容器——flexible frame 会把底衬撑满整个窗口宽。
                ActivityIslandChrome {
                    island.view
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .padding(.top, ActivityIslandLayout.topGap)
        .background {
            IslandSizeReader { size in onVisibleSizeChange(size) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: islands.map(\.id))
    }
}

// MARK: - 控制器：窗口几何与 HostController 活动岛实现

extension NotchPanelController {
    /// 活动岛窗口 frame：顶缘贴刘海底缘、绕屏幕中线居中、固定尺寸。
    func islandPanelFrame(for pair: ScreenPanelPair) -> NSRect {
        NotchGeometry.topCenteredFrame(
            for: NSSize(
                width: ActivityIslandLayout.windowWidth,
                height: ActivityIslandLayout.windowHeight
            ),
            topY: pair.screenFrame.maxY - pair.layout.compactHeight,
            in: pair.screenFrame
        )
    }

    /// 活动岛可见矩形（屏幕坐标）：无活动岛、抽屉展开（岛让位）或内容尚未
    /// 布局（尺寸为零）时为 nil，窗口完全穿透。
    func visibleIslandFrame(for pair: ScreenPanelPair) -> NSRect? {
        guard !uiState.activityIslands.isEmpty, !uiState.isDrawerExpanded else { return nil }
        let size = uiState.islandVisibleSize
        guard size.width > 0.5, size.height > 0.5 else { return nil }
        return NotchGeometry.topCenteredFrame(
            for: size,
            topY: pair.screenFrame.maxY - pair.layout.compactHeight,
            in: pair.screenFrame
        )
    }

    /// 同步单个屏幕的活动岛窗口：始终重摆 frame（屏宽变化时窗口随之居中），
    /// 有活动岛时上线、无活动岛时收回（退出动画期间的重复 orderOut 无副作用）。
    func syncIslandPanel(_ pair: ScreenPanelPair) {
        pair.islandPanel.setFrame(islandPanelFrame(for: pair), display: true)
        if uiState.activityIslands.isEmpty {
            if pair.islandPanel.isVisible {
                pair.islandPanel.orderOut(nil)
            }
        } else if !pair.islandPanel.isVisible {
            // 先假设光标不在岛上（首个轮询帧即按实际位置翻转），避免窗口
            // 上线瞬间在透明区拦住点击。
            pair.islandPanel.ignoresMouseEvents = true
            pair.islandPanel.orderFrontRegardless()
        }
    }

    /// 活动岛窗口与抽屉同款双机制穿透：光标在可见岛矩形内才接收事件
    /// （hitTest 穿透必要但不充分，窗口级开关缺一不可）。
    func updateIslandMouseEvents(cursor: NSPoint) {
        for pair in pairs {
            let inside = visibleIslandFrame(for: pair)?.contains(cursor) ?? false
            if pair.islandPanel.ignoresMouseEvents == inside {
                pair.islandPanel.ignoresMouseEvents = !inside
            }
        }
    }
}

// HostController 协议实现（活动岛）。
extension NotchPanelController {
    func showActivityIsland(_ content: ActivityIslandContent) {
        uiState.activityIslands.removeAll { $0.id == content.id }
        uiState.activityIslands.append(content)
        for pair in pairs {
            syncIslandPanel(pair)
        }
    }

    func removeActivityIsland(id: String) {
        guard uiState.activityIslands.contains(where: { $0.id == id }) else { return }
        uiState.activityIslands.removeAll { $0.id == id }
        guard uiState.activityIslands.isEmpty else { return }
        // 等内容退出动画播完再收窗口（收起动画中岛仍可见）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, self.uiState.activityIslands.isEmpty else { return }
            for pair in self.pairs {
                pair.islandPanel.orderOut(nil)
            }
            self.uiState.islandVisibleSize = .zero
        }
    }
}
