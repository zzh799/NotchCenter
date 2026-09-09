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
    /// 插件是否提供设置界面（编辑模式右上角齿轮按钮的显隐条件）。
    let hasSettings: Bool

    /// 身份用放置实例（placementID）而不是槽位下标：重排时 SwiftUI 才能识别
    /// “同一个图标换了位置”并做平滑移动，而不是当作槽位内容更新。
    var id: String { reference?.placementID ?? "slot-\(slotIndex)" }
}

struct CompactActions {
    let onRemoveBlock: (Int) -> Void
    /// 编辑模式设置按钮：(pluginID, placementID, 图标全局 frame)，经 SettingPopover
    /// 展示设置——优先块实例级视图，回退插件级（见 NotchPanelContent.showPluginSettings）。
    let onShowSettings: (String, String, CGRect) -> Void
    let onTapBackground: () -> Void
    let onExpand: () -> Void
    /// 编辑模式拖动重排预览：(被拖图标数组下标, 屏幕插入位置, 光标内容坐标 x)；
    /// 结束传 (nil, nil, nil) 清空。屏幕位置语义见 `CompactSlotOrder`。
    let onReorderPreview: (Int?, Int?, CGFloat?) -> Void
    /// 编辑模式拖动重排提交：(被拖图标数组下标, 屏幕插入位置)。
    let onReorderCommit: (Int, Int) -> Void
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

    var body: some View {
        GeometryReader { proxy in
            let isEditing = ui.isEditing
            // 条带宽度随当前紧凑图标数与活动摘要带宽动态伸缩：视图取数只经
            // PanelUIState 的 `compactStrip(layout:slotCount:)`（可见性/让位
            // 在 `effectiveSummary*Width` 一处判定，layout 只携带屏幕相关的
            // 刘海/高度部分），不直读引擎、不自行拼接摘要宽度。
            let strip = ui.compactStrip(layout: layout, slotCount: ui.compactCount)
            let panelHeight = proxy.size.height

            // .top 对齐让黑色带在窗口内水平居中（其余元素均为绝对定位），
            // 与抽屉遮罩的中心对称展开、刘海位置保持一致。
            ZStack(alignment: .top) {
                // 整条黑色填充带：横跨左右面板并覆盖刘海区域，
                // 与刘海融为一体（灵动岛观感，文档 §5.2）。
                if showsBand {
                    TopAttachedRoundedShape(radius: NotchTokens.Radius.panelCompact)
                        .fill(
                            // Surface.drawer 自带 0.98 不透明度：常态再乘 0.98 ≈ 原 0.96，悬停回满档
                            // （≈ 展开抽屉底色，展开瞬间无跳变）。
                            NotchTokens.Surface.drawer.opacity(isHovering ? 1 : 0.98)
                        )
                        .overlay {
                            // 外描边统一发丝线档（悬停 0.15 与原常态 0.09 就近收敛 drawerEdge）。
                            TopAttachedRoundedShape(radius: NotchTokens.Radius.panelCompact)
                                .stroke(NotchTokens.Hairline.drawerEdge, lineWidth: 1)
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
                    // 点击模式悬停指示条（DESIGN §9.1 白 0.72，就近收敛 Foreground.secondary）。
                    Capsule()
                        .fill(NotchTokens.Foreground.secondary)
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
                        // 显示槽位：内部重排预览期间按“插入后的屏幕顺序”取位，
                        // 其余图标随拖动平滑让位（被拖项钉在原始槽位，落点由
                        // 插入指示线表达）；无预览时用真实数组下标。
                        // 回调用的是真实 slotIndex（数组下标），不受预览影响。
                        let displayIndex = displaySlotIndex(
                            for: element,
                            strip: strip
                        )
                        let rect = strip.slotRect(at: displayIndex) ?? .zero
                        CompactBlockContainer(
                            element: element,
                            view: view,
                            isEditing: isEditing,
                            strip: strip,
                            slotRect: rect,
                            onRemove: { actions.onRemoveBlock(element.slotIndex) },
                            onShowSettings: { anchorFrame in
                                guard let reference = element.reference else { return }
                                actions.onShowSettings(reference.pluginID, reference.placementID, anchorFrame)
                            },
                            onExpand: actions.onExpand,
                            onReorderPreview: actions.onReorderPreview,
                            onReorderCommit: actions.onReorderCommit
                        )
                        .position(x: rect.midX, y: rect.midY)
                        // 被拖项浮到最上层，防止让位滑动的邻居图标盖住它。
                        .zIndex(ui.dropPreview?.draggingSlotIndex == element.slotIndex ? 1 : 0)
                    }
                }

                // 从设置面板拖入快捷按钮时的插入指示：一条贴在插入点
                // 左侧的竖线（追加到末尾时贴在最后一个图标右侧）。
                if let preview = ui.dropPreview, preview.isCompact,
                   case let .compact(index) = preview.zone {
                    Capsule(style: .continuous)
                        .fill(NotchTokens.Foreground.hover)
                        .frame(width: 2.5, height: 20)
                        .shadow(color: .white.opacity(0.4), radius: 4)
                        .position(
                            x: insertionX(
                                index: index,
                                strip: strip,
                                pointerX: preview.compactPointerX
                            ),
                            y: panelHeight / 2
                        )
                        .allowsHitTesting(false)
                }

                // 活动摘要芯片层：最新在左、次新在右，贴刘海两侧（几何与
                // 可见性已判定，见 `summaryChipLayer`）。放最上层：芯片点击
                // 穿透到空白热区（与整条黑色带同一展开语义），不挡图标。
                summaryChipLayer(strip: strip)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    /// 内部重排预览中，某图标应显示在的槽位（数组下标）。
    ///
    /// 被拖项始终钉在原始槽位：松手前不把它预览移到目标位置（目标落点
    /// 由跟随光标的插入指示线表达），它只通过 `dragOffset` 跟手移动。
    /// 其余图标复用引擎同一套 `CompactSlotOrder` 算法：把当前屏幕顺序
    /// 序列里的被拖项移到目标屏幕位置，再按映射换算各自的新数组下标——
    /// 预览与松手提交必然一致（所见即所得）。
    private func displaySlotIndex(
        for element: CompactElement,
        strip: CompactStripLayout
    ) -> Int {
        guard let preview = ui.dropPreview,
              preview.isCompact,
              let from = preview.draggingSlotIndex,
              case let .compact(screenPosition) = preview.zone
        else {
            return element.slotIndex
        }
        // 被拖项基座不动：避免基座跳槽与 dragOffset 叠加造成漂移，
        // 也避免让位预览把被拖图标“摆”到目标槽上。
        if element.slotIndex == from { return element.slotIndex }
        guard let reordered = CompactSlotOrder.reordered(
            ui.compactElements.map(\.reference),
            from: from,
            to: screenPosition
        ) else {
            return element.slotIndex
        }
        // 找到该图标在重排后数组中的新下标（以 placementID 匹配，跳过空位）。
        let identity = element.reference?.placementID
        let newIndex = reordered.firstIndex { candidate in
            guard let identity else { return false }
            return candidate?.placementID == identity
        }
        guard let newIndex else { return element.slotIndex }
        return min(max(newIndex, 0), strip.slotCount - 1)
    }

    /// 插入指示线的横坐标（窗口内容坐标，左上原点）。
    /// 槽位按添加顺序**左右均衡交替**排布（偶数索引在左、奇数在右），
    /// 所以索引 i 的位置就是 `slotRect(at: i)`，不必按屏幕顺序换算。
    /// `pointerX` 为光标横坐标（同上坐标系）：快速区为空、或光标落在紧凑带
    /// 之外时用它跟随光标（钳制在带内，保证指示线可见）。
    private func insertionX(
        index: Int,
        strip: CompactStripLayout,
        pointerX: CGFloat?
    ) -> CGFloat {
        let gap: CGFloat = 3
        let bandWidth = strip.windowWidth
        if let pointerX {
            return min(max(pointerX, gap), max(bandWidth - gap, gap))
        }
        if index >= 0, index < strip.slotCount, let rect = strip.slotRect(at: index) {
            return rect.minX - gap
        }
        // 追加到末尾：贴在最后一个图标右侧。
        let last = strip.slotCount - 1
        if last >= 0, let rect = strip.slotRect(at: last) {
            return rect.maxX + gap
        }
        // 还没有任何图标：贴刘海中心（快速区为空时带宽只剩刘海）。
        return strip.notchCenterX
    }

    // MARK: - 活动摘要芯片（Agent Note 2026-09-03-compact-area-activity-summary）

    /// 活动摘要芯片层：按 `PanelUIState.visibleSummaryPair`（最新在左、
    /// 次新在右；抽屉展开期间让位 = 空）渲染左右各至多一颗芯片，几何照
    /// `strip.leftSummaryRect` / `rightSummaryRect` 摆放。
    ///
    /// 过渡纪律：出现/更新/移除动画一律发生在窗口**内容内**（transition +
    /// animation 由 SwiftUI 在既有宿主视图内完成）；带宽变化时窗口 frame
    /// 的伸缩由控制器 `syncSummaryGeometryMirrors` 非动画重摆，不走这里。
    @ViewBuilder
    private func summaryChipLayer(strip: CompactStripLayout) -> some View {
        let pair = ui.visibleSummaryPair
        if let summary = pair.left, let rect = strip.leftSummaryRect {
            SummaryChipView(summary: summary)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                // 分支身份稳定（不随 summary.id 重置）：出现/消失走 transition，
                // 同侧换摘要（更新）原地换内容、进度条随动画平滑跟进。
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
                .animation(.easeOut(duration: 0.18), value: ui.activitySummaries)
        }
        if let summary = pair.right, let rect = strip.rightSummaryRect {
            SummaryChipView(summary: summary)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
                .animation(.easeOut(duration: 0.18), value: ui.activitySummaries)
        }
    }
}

/// 紧凑块容器：槽位内的块视图 + 默认点击展开（文档 §6.2）+ 编辑模式移除、
/// 设置与**拖动重排**（横向换位，插入指示线复用于紧凑带层级）。
private struct CompactBlockContainer: View {
    let element: CompactElement
    let view: AnyView
    let isEditing: Bool
    /// 紧凑带布局与自身槽位矩形：把拖动手势的局部坐标换算成带内内容坐标。
    let strip: CompactStripLayout
    let slotRect: CGRect
    let onRemove: () -> Void
    /// 弹出插件设置浮窗（参数为图标当前全局 frame，作为 SettingPopover 锚点）。
    let onShowSettings: (CGRect) -> Void
    let onExpand: () -> Void
    let onReorderPreview: (Int?, Int?, CGFloat?) -> Void
    let onReorderCommit: (Int, Int) -> Void

    /// 图标当前全局 frame（窗口坐标）：设置浮窗的锚定矩形。
    @State private var globalFrame: CGRect = .zero
    /// 拖动位移（横向）：拖动中图标跟手，松手回零。
    /// 基座被 `displaySlotIndex` 钉在原始槽位、不随预览跳变，因此该全量
    /// 位移可直接叠加在基座上，渲染位置恒等于指针落点，不会漂移。
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// 悬停高亮：槽位底衬微亮（白 0.08，低于顶栏激活态高亮档）。
    @State private var isHovering = false

    var body: some View {
        group
            .frame(width: NotchGeometry.compactSlotSize.width, height: NotchGeometry.compactSlotSize.height)
            .background {
                ZStack {
                    // 悬停高亮底衬：28×28 槽位圆角矩形。
                    RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                        .fill(NotchTokens.Surface.track.opacity(isHovering ? 1 : 0))
                    GlobalFrameReader { globalFrame = $0 }
                }
            }
            // 悬浮提示：插件块的用户可见名称（block 为 nil 时不提示）。
            .help(element.block?.displayName ?? "")
            // 手势屏蔽层：图标自身（点击展开、插件自定义手势）在编辑模式下不响应，
            // 只保留角标按钮与容器的拖动重排——与抽屉块的压暗遮罩同一语义。
            .overlay {
                if isEditing {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                }
            }
            // 角标悬停图标才显示（与分页胶囊同一交互）。两条子层都走 overlay：
            // 挂在 ZStack 里两颗角标（25pt 宽）会把容器撑宽，角标一出现图标就横移。
            // 角标恒落在槽位框内——悬停热区就是这个框，探出框外的后果见
            // `DrawerPagePillLayout.rowHeight`。
            .overlay(alignment: .topTrailing) {
                if isEditing && isHovering {
                    HStack(spacing: 1) {
                        // 先设置后移除，保持移除按钮贴最外侧角落。
                        if element.hasSettings {
                            EditGlyphButton(
                                systemImage: "gearshape.fill",
                                helpText: L("panel.help.pluginSettings")
                            ) {
                                onShowSettings(globalFrame)
                            }
                        }
                        EditGlyphButton(
                            systemImage: "xmark.circle.fill",
                            helpText: L("panel.help.removeBlock"),
                            action: onRemove
                        )
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
            // 拖动中整体跟手（角标一起走），并轻微放大表示“已拿起”。
            .offset(x: dragOffset)
            .scaleEffect(isDragging ? 1.08 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.45 : 0), radius: 6, y: 2)
            // 编辑模式挂拖动手势：mask 必须是 `.all`——`.gesture` 会连带排除子视图手势，
            // 角标按钮就点不动了（图标自身内容由上面的屏蔽层挡，不靠 mask）。
            // 非编辑模式 `.subviews` 等价于不添加（保留子视图自身的点击）。
            .gesture(reorderGesture, including: isEditing ? .all : .subviews)
    }

    /// 编辑模式拖动重排：位移换算成带内内容坐标 → 屏幕插入位置 → 实时让位
    /// 预览（其余图标动画移到目标槽位），松手提交换位。
    /// 纵向位移忽略（快速区只有横向次序）。
    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDragging { isDragging = true }
                dragOffset = value.translation.width
                let contentX = contentX(for: value)
                onReorderPreview(
                    element.slotIndex,
                    strip.screenInsertionIndex(atContentX: contentX),
                    contentX
                )
            }
            .onEnded { value in
                let contentX = contentX(for: value)
                let target = strip.screenInsertionIndex(atContentX: contentX)
                withAnimation(NotchTokens.Motion.expand) {
                    dragOffset = 0
                    isDragging = false
                }
                // 先提交（内容重建到新顺序）再清预览：若先清预览，视图会先
                // 跳回旧顺序的位置、再动画到新位置——出现一次可见的回弹。
                onReorderCommit(element.slotIndex, target)
                onReorderPreview(nil, nil, nil)
            }
    }

    /// 手势位置 → 紧凑带内容坐标：按下点在槽位内的位置 + 累计位移。
    /// 用 `startLocation` 而非 `location`：后者随视图位移漂移。
    /// 基座被钉在原始槽位（不随预览跳变），`slotRect.minX` 即稳定基准，
    /// 插入位置判定不会随之抖动。
    private func contentX(for value: DragGesture.Value) -> CGFloat {
        slotRect.minX + value.startLocation.x + value.translation.width
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

// MARK: - 活动摘要芯片外观

/// 单颗活动摘要芯片（刘海紧凑带内、贴刘海一侧）：胶囊底衬上一行
/// 「(符号) 主文案 副文案」+ 底部迷你进度条。
///
/// - 宽高由调用方按 `SummaryChipMetrics.estimatedWidth` 估算的带几何给出
///   （`leftSummaryRect` / `rightSummaryRect`），文案超宽在芯片内截断——
///   估算已留余量（宁宽勿裁），截断只是兜底。
/// - 纯展示：`allowsHitTesting(false)`，点击穿透到下层空白热区（整条
///   黑色带点击 = 展开抽屉的统一语义），副文案优先于主文案截断。
/// - 外观常量与宿主宽度估算共享 `SummaryChipMetrics`（单一来源）。
private struct SummaryChipView: View {
    let summary: ActivitySummary

    var body: some View {
        ZStack {
            // 底衬：半透明胶囊，与紧凑带图标的高亮底衬同族（低饱和白）。
            Capsule(style: .continuous)
                .fill(NotchTokens.Surface.track)
            Capsule(style: .continuous)
                .stroke(NotchTokens.Hairline.drawerEdge, lineWidth: 1)

            HStack(spacing: SummaryChipMetrics.symbolTextGap) {
                if let symbolName = summary.symbolName {
                    Image(systemName: symbolName)
                        .font(NotchTokens.Text.system(13, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.hover)
                        .frame(width: SummaryChipMetrics.symbolWidth)
                }
                Text(summary.title)
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle = summary.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(NotchTokens.Text.system(11, weight: .regular))
                        .foregroundStyle(NotchTokens.Foreground.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                }
            }
            .padding(.horizontal, 7)
        }
        // 迷你进度条：芯片底部一条沿刘海方向的细进度（0…1），
        // 无进度概念的摘要不渲染（GeometryReader 贪婪占宽，先 padding
        // 收内宽、再 frame 定高、后 padding 抬离底缘）。
        .overlay(alignment: .bottom) {
            if summary.progress != nil {
                SummaryProgressBar(progress: summary.progress ?? 0)
                    .padding(.horizontal, 3)
                    .frame(height: 2)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .help(summaryTitleAndSubtitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryTitleAndSubtitle)
    }

    private var summaryTitleAndSubtitle: String {
        if let subtitle = summary.subtitle, !subtitle.isEmpty {
            return "\(summary.title) · \(subtitle)"
        }
        return summary.title
    }
}

/// 芯片底部迷你进度条：静止轨 + 按进度填充的圆头条（轨道同色系低饱和，
/// 填充略亮，避免在黑色带/胶囊底衬上抢眼）。
private struct SummaryProgressBar: View {
    /// 原始进度（0…1，调用方已保证非 nil）。
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(NotchTokens.Surface.track)
                Capsule(style: .continuous)
                    .fill(NotchTokens.Foreground.hover)
                    // 进度 0 时宽度也为 0（轨道仍在，看不出"已完成"的错觉）；
                    // 微小进度至少 1.5pt 可见。
                    .frame(width: trackWidth == 0 ? 0 : max(trackWidth * clamped, clamped > 0 ? 1.5 : 0))
            }
            .frame(width: trackWidth)
        }
    }
}

/// 捕获修饰视图当前的全局 frame（SwiftUI .global = 宿主窗口坐标，左上原点），
/// 布局变化即回调。设置浮窗锚定矩形用：紧凑图标与抽屉块容器各自挂在内容上，
/// 点击齿轮时上报最新 frame 给 SettingPopover。
struct GlobalFrameReader: View {
    let onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in onChange(frame) }
        }
    }
}

// MARK: - 快速区快捷按钮单元格（统一标准样式）

/// 快速区里的统一快捷按钮：宿主标准外观（`QuickActionTile`）+ 点击执行动作。
/// 开关类经 `@ObservedObject` 观察 `isActive` 实时点亮；重动作经图标下方垂出的
/// 确认浮窗二次确认；悬停提示显示动作名（与旧紧凑块 help 同款体验）。
struct QuickActionStripCell: View {
    @ObservedObject var action: QuickAction
    let slotSize: CGSize
    /// 图标在宿主窗口坐标系中的 frame（`GlobalFrameReader` 实时捕获），
    /// 确认浮窗的锚点。
    @State private var tileFrame: CGRect?

    var body: some View {
        Button {
            if action.requiresConfirmation {
                presentConfirmation()
            } else {
                action.execute()
            }
        } label: {
            QuickActionTile(
                systemImage: action.systemImage,
                isActive: action.kind == .toggle && action.isActive,
                symbolSize: 13,
                sideLength: min(slotSize.width, slotSize.height)
            )
        }
        .buttonStyle(.plain)
        // 紧凑面板是 canBecomeKey 的 NSPanel：点击后按钮成为 first responder
        // 会画系统蓝色焦点环，禁用（与既有紧凑块视图同一处理）。
        .focusable(false)
        .focusEffectDisabled(true)
        .help(action.displayName)
        .accessibilityLabel(action.displayName)
        .background {
            GlobalFrameReader { frame in tileFrame = frame }
        }
    }

    /// 重动作确认浮窗：贴图标下方弹出（与齿轮设置浮窗同一 BlockPopover 管线，
    /// `.below` 摆放）。不用 confirmationDialog——模态弹窗抢焦点，鼠标移过去
    /// 宿主就会收起条带，确认根本完不成。
    private func presentConfirmation() {
        guard let tileFrame else { return }
        BlockPopover.shared.present(
            anchoredTo: tileFrame,
            cardSize: CGSize(width: 240, height: 104),
            placement: .below
        ) {
            InlineConfirmPanel(
                title: action.displayName,
                message: L("quick.confirm.body"),
                confirmTitle: L("quick.confirm.run"),
                cancelTitle: L("common.cancel"),
                onConfirm: {
                    action.execute()
                    BlockPopover.shared.dismiss()
                },
                onCancel: { BlockPopover.shared.dismiss() }
            )
        }
    }
}
