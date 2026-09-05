import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 跨窗口拖拽（设置面板 → 抽屉 / 快速区）

/// 把设置面板「组件」页里的块拖到抽屉网格或紧凑区（快速区）。
///
/// 为什么不走系统 `NSItemProvider` Drag & Drop：抽屉是一个常驻、命中测试
/// 可穿透（`ignoresMouseEvents`）的无边框 `NSPanel`，透明区的 drop 目标无法
/// 稳定命中，且 SwiftUI 的 `onDrop` 需要目标视图持续在窗口层级里可命中。
/// 这里改为**自建拖拽会话**：发起端用 `DragGesture` 起手（AppKit 会把后续
/// `mouseDragged` 继续派发给最初按下鼠标的窗口，拖出窗口也不中断），
/// 会话期间用本地事件监听跟踪光标，由控制器按屏幕坐标做落点命中测试，
/// 松手时直接调布局引擎落位。
@MainActor
final class BlockDragCoordinator: ObservableObject {
    static let shared = BlockDragCoordinator()

    /// 跟手浮窗要渲染的内容：真实块视图 + 1:1 像素尺寸。
    ///
    /// 独立于 `Payload` 的相等语义之外：`AnyView` 不参与 `Equatable` 自动
    /// 合成，见 `Payload.==`。由设置面板在构造 payload 时一次性打包。
    struct DragPreviewContent {
        let view: AnyView
        /// 1:1 像素尺寸（抽屉块按默认跨度的格网尺寸，紧凑块按槽位尺寸）。
        let size: CGSize
    }

    /// 被拖动的块（设置面板构造）。
    struct Payload: Equatable {
        let pluginID: String
        let blockID: String
        let kind: BlockKind
        let displayName: String
        let symbolName: String?
        /// 抽屉块的默认跨度；紧凑块为 1×1（落点高亮不使用）。
        /// 用 `GridSpan` 而非元组：元组不参与 `Equatable` 自动合成。
        let span: GridSpan
        /// 跟手浮窗内容：真实组件视图 + 1:1 尺寸。
        /// 为 nil 时浮窗回退到名称胶囊、落位不做飞行。
        let preview: DragPreviewContent?

        var isCompact: Bool { kind == .compact }

        /// 显式初始化器（`preview` 带默认值）：`let` 属性即使声明了默认值
        /// 也不会进入自动成员初始化器，而探针构造 payload 时不提供视图。
        init(
            pluginID: String,
            blockID: String,
            kind: BlockKind,
            displayName: String,
            symbolName: String?,
            span: GridSpan,
            preview: DragPreviewContent? = nil
        ) {
            self.pluginID = pluginID
            self.blockID = blockID
            self.kind = kind
            self.displayName = displayName
            self.symbolName = symbolName
            self.span = span
            self.preview = preview
        }

        /// 手写相等：只比身份，忽略 `preview`。
        /// `AnyView` 不可比较，且「哪张卡片在拖」只应取决于身份——
        /// 视图每次重建 catalog 都是新实例，若参与比较会让卡片的高亮
        /// （`SettingsPages` 的 `.opacity(payload == item.payload)`）失效。
        static func == (lhs: Payload, rhs: Payload) -> Bool {
            lhs.pluginID == rhs.pluginID
                && lhs.blockID == rhs.blockID
                && lhs.kind == rhs.kind
                && lhs.displayName == rhs.displayName
                && lhs.symbolName == rhs.symbolName
                && lhs.span == rhs.span
        }
    }

    /// 落点：抽屉格网（列/行/跨度）或快速区插入索引。
    enum DropZone: Equatable {
        case drawer(column: Int, row: Int, columns: Int, rows: Int)
        case compact(index: Int)
    }

    // MARK: 会话状态（供 UI 观察）

    @Published private(set) var payload: Payload?
    @Published private(set) var zone: DropZone?

    var isDragging: Bool { payload != nil }

    /// 面板控制器（落点命中与落位执行方）：由控制器自身在初始化时注入。
    weak var controller: NotchPanelController?

    private var monitor: Any?
    private var previewPanel: DragPreviewPanel?
    private var previewState = DragPreviewState()

    private init() {}

    // MARK: 会话

    /// Escape 的键码（`installMonitor` 用它取消会话）。
    private static let escapeKeyCode: UInt16 = 53

    /// 幂等起手：`DragGesture.onChanged` 每帧都会调用，只有第一次生效。
    func beginIfNeeded(_ payload: Payload) {
        guard self.payload == nil else {
            updatePointer()
            return
        }
        // 上一次落位可能还在飞（浮窗未落定、上一块仍隐形）：先强制收尾，
        // 否则新会话与旧飞行的 handoff 会互相踩 `landingPlacementID`。
        DragPreviewLanding.shared.cancel()
        self.payload = payload
        previewState.update(payload: payload, isValid: false)
        // 会话期间彻底锁住设置面板的移动：窗口一旦进入拖动循环就会吞掉
        // mouseDragged，落点会停在旧位置（表现：“拖了但没放上去”）。
        setSettingsWindowMovable(false)
        showPreview()
        installMonitor()
        updatePointer()
    }

    /// 按当前光标位置刷新落点与预览浮窗（幂等，可高频调用）。
    func updatePointer() {
        updatePointer(at: NSEvent.mouseLocation)
    }

    /// 指定屏幕坐标刷新落点（`updatePointer()` 的注入版本，自动化探针用）。
    func updatePointer(at location: NSPoint) {
        guard let payload else { return }
        zone = controller?.dropZone(at: location, for: payload)
        previewState.update(payload: payload, isValid: zone != nil)
        positionPreview(at: location)
        controller?.updateDropPreview(payload: payload, zone: zone, pointer: location)
        updateCapsuleDwell(at: location, payload: payload)
    }

    /// 松手：有效落点即落位；无效落点静默取消。
    ///
    /// 有效落位且载荷带真实视图时，浮窗不立即消失——它 spring 飞向占位框
    /// 位置，落定后交接给真实块（见 `DragPreviewLanding`）。会话本身的
    /// 清理（事件监听、设置面板窗口锁、落点状态）**照常立即执行**，
    /// 浮窗的生命周期独立移交给协调器，因此飞行期间就能开始下一次拖拽。
    func commit() {
        // 上一次落位可能还在飞（上一块仍隐形）：先收尾，避免本次会话与旧
        // 飞行的 handoff 争抢 `landingPlacementID`。（`fly()` 内部也会
        // cancel，这里补上的是「本次走无飞行分支」的情况。）
        DragPreviewLanding.shared.cancel()
        guard let payload, let controller else {
            teardown()
            return
        }
        let zone = self.zone
        // 摘走浮窗：`teardown()` 里的 `hidePreview()` 会立刻收掉它，
        // 而落位飞行需要它活到动画结束。
        let panel = previewPanel
        previewPanel = nil
        // 起飞点必须在 teardown 之前取（此后 previewPanel 已置 nil）。
        let from = panel?.contentScreenRect()
        // 无真实视图的载荷（自动化探针）不做飞行，行为与改动前一致。
        let canFly = payload.preview != nil
        var landedID: String?

        if let zone {
            controller.performBlockDrop(payload, to: zone) { placementID in
                // 早于 refreshAfterEdit：让重建出的元素以 opacity(0) 出生。
                controller.uiState.landingPlacementID = placementID
                landedID = placementID
            }
        }
        teardown()

        // 终点必须用**提交后**的几何算：面板宽度与最左列都可能因落位而变，
        // 用拖动时的旧几何会让终点偏离真实块几 pt 甚至一整格。
        let to = landedID.flatMap { controller.landingRect(placementID: $0) }
        guard let panel, let from, let to, canFly else {
            // 无飞行（探针 / 快速区 / 无视图 / 拿不到终点）：立即收场。
            panel?.orderOut(nil)
            controller.uiState.landingPlacementID = nil
            return
        }
        DragPreviewLanding.shared.fly(panel, from: from, to: to) {
            // 与浮窗消失同一次更新：真实块显形，1:1 同位置，交接不可见。
            controller.uiState.landingPlacementID = nil
        }
    }

    /// 主动取消（Escape / 会话异常）。
    /// 落位飞行**不**在这里收尾：它是上一次会话遗留的、与本次会话无关的
    /// 收尾动作，`DragPreviewLanding` 自己的超时与 `beginIfNeeded` /
    /// `commit()` 里的 `cancel()` 已保证它一定完成。
    func cancel() {
        teardown()
    }

    private func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        cancelCapsuleDwell()
        hidePreview()
        payload = nil
        zone = nil
        setSettingsWindowMovable(true)
        controller?.updateDropPreview(payload: nil, zone: nil)
    }

    /// 会话期间禁止设置面板被拖走（见 `beginIfNeeded` 的说明）。
    private func setSettingsWindowMovable(_ movable: Bool) {
        controller?.settingsWindowController?.window?.isMovable = movable
    }

    // MARK: 事件跟踪

    /// 光标跟踪兜底：`DragGesture` 的 `onChanged` 覆盖常规路径，但手势被
    /// 系统/窗口切换打断时会话会卡在最后位置；本地监听保证只要鼠标没松，
    /// 落点就持续更新，并在 `leftMouseUp` 时兜底提交。
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .mouseMoved, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            switch event.type {
            case .leftMouseUp:
                MainActor.assumeIsolated { self?.commit() }
            case .keyDown:
                // Escape 取消会话：不吞事件（`return event` 照常继续传递），
                // 只借道观察。没有这个分支时，拖到一半想反悔只能拖到面板外。
                if event.keyCode == BlockDragCoordinator.escapeKeyCode {
                    MainActor.assumeIsolated { self?.cancel() }
                }
            default:
                MainActor.assumeIsolated { self?.updatePointer() }
            }
            return event
        }
    }

    // MARK: 胶囊驻留切页（设置面板拖组件跨页）

    /// 诊断日志开关（`NOTCHCENTER_DRAG_PROBE_LOG=1`）：打印命中测试输入输出、
    /// 驻留状态迁移与切页守卫逐项结果（与 `NOTCHCENTER_SCROLL_PROBE_LOG` 同族）。
    static let dragProbeLogEnabled = DragProbeLog.enabled

    /// 驻留计时与到点复核共用 `CapsuleDwellTimer`；本路径的落位动作只有
    /// 切页。紧凑块不参与——它只进快速区，压上胶囊不起计时。
    private lazy var capsuleDwell = CapsuleDwellTimer(
        hitPage: { [weak self] point in
            self?.controller?.drawerPageCapsuleHitTest(at: point)
        }
    )

    private func updateCapsuleDwell(at location: NSPoint, payload: Payload) {
        guard !payload.isCompact else {
            capsuleDwell.cancel()
            return
        }
        capsuleDwell.update(
            at: location,
            activePage: controller?.uiState.drawerActivePage ?? 0,
            onFire: { [weak self] page in
                self?.controller?.switchDrawerPageForDrag(page)
            }
        )
    }

    private func cancelCapsuleDwell() {
        capsuleDwell.cancel()
    }

    /// 诊断用驻留状态摘要（探针转储，非发布路径）。
    var dragProbeDwellSummary: String {
        capsuleDwell.debugSummary
    }

    // MARK: 跟随光标的预览浮窗

    private func showPreview() {
        let panel = previewPanel ?? DragPreviewPanel(state: previewState)
        previewPanel = panel
        // 尺寸随载荷：1:1 真实组件尺寸；无视图（探针）回退到名称胶囊。
        panel.applyContentSize(previewState.contentSize)
        panel.orderFrontRegardless()
    }

    private func hidePreview() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }

    /// 浮窗以**光标为中心**：让「光标 ≡ 块中心 ≡ 落点格子中心」三者映射
    /// 一致——落点判定（`drawerDropZone`）本来就按光标所在格计算，居中后
    /// 用户瞄哪一格，浮窗就压在哪一格上。
    ///
    /// 不做抓握偏移补偿：源是设置面板里**缩放过**的缩略卡片，把抓握点
    /// 还原到 1:1 会引入 `1/scale` 倍的跳变。（抽屉内重排的源本身就是
    /// 1:1 真实块，走 `dragOffset` 路径，不经过这里。）
    private func positionPreview(at location: NSPoint) {
        guard let panel = previewPanel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
        )
    }
}

// MARK: - 分页胶囊驻留计时器（跨页拖拽两条路径共用）

/// 拖拽诊断日志开关（`NOTCHCENTER_DRAG_PROBE_LOG=1`）：命中/驻留/守卫
/// 各站点共用（与 `NOTCHCENTER_SCROLL_PROBE_LOG` 同族）。
enum DragProbeLog {
    static let enabled =
        ProcessInfo.processInfo.environment["NOTCHCENTER_DRAG_PROBE_LOG"] == "1"
}

/// 指针压在分页胶囊上驻留 0.5s 即回调——iOS 桌面把图标拖到屏幕边缘自动
/// 翻页的同款交互。设置目录拖拽（`BlockDragCoordinator`）与抽屉内重排
/// 拖拽（`DrawerInteractionState`）两条路径共用：命中与落位动作由构造处
/// 注入，本类型只管「压上 → 驻留 → 到点复核 → 回调一次」的时序。
///
/// 为什么用 Task 计时而不是逐事件判 deadline：驻留 = 指针**静止**压在
/// 胶囊上，此时没有任何鼠标事件流入，纯事件驱动永远不会到点。
@MainActor
final class CapsuleDwellTimer {
    /// 驻留时长：快扫而过（<0.5s）不切，停下即切。
    private let duration: Duration
    private let hitPage: (NSPoint) -> Int?
    private var task: Task<Void, Never>?
    /// 驻留目标页与最近一次指针位置（到点复核用：驻留期间指针可能有
    /// 轻微移动，事件间隔里也无人重算命中）。
    private var target: Int?
    private var pointer = NSPoint.zero

    init(
        duration: Duration = .milliseconds(500),
        hitPage: @escaping (NSPoint) -> Int?
    ) {
        self.duration = duration
        self.hitPage = hitPage
    }

    /// 诊断用驻留状态摘要（探针转储，非发布路径）。
    var debugSummary: String {
        "dwellPage=\(target.map(String.init) ?? "nil") taskPending=\(task != nil)"
    }

    /// 指针压上非激活页胶囊 → 起计时；移开 / 换目标 / 已在该页 → 取消或重启。
    /// 同一目标内的轻微移动只刷新复核点，**不重启计时**（否则手抖永远到不了点）。
    func update(at location: NSPoint, activePage: Int, onFire: @escaping (Int) -> Void) {
        let page = hitPage(location)
        guard let page, page != activePage else {
            cancel()
            return
        }
        guard page != target else {
            pointer = location
            return
        }
        if DragProbeLog.enabled {
            print("[drag-probe] dwell start: target=\(page) active=\(activePage) at=\(location)")
        }
        cancel()
        target = page
        pointer = location
        let duration = duration
        task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.fire(onFire)
        }
    }

    private func fire(_ onFire: (Int) -> Void) {
        guard let page = target else { return }
        // 一次性：无论是否成切，先摘掉目标页，避免残留状态跨进下一轮判定。
        cancel()
        // 到点复核：指针仍须压在同一颗胶囊上（驻留期间可能有轻微移动）。
        let recheck = hitPage(pointer)
        guard recheck == page else {
            if DragProbeLog.enabled {
                print("[drag-probe] dwell fire miss: target=\(page) recheck=\(recheck.map(String.init) ?? "nil")")
            }
            return
        }
        if DragProbeLog.enabled {
            print("[drag-probe] dwell fire: page=\(page)")
        }
        onFire(page)
    }

    func cancel() {
        task?.cancel()
        task = nil
        target = nil
    }
}

// MARK: - 预览浮窗

/// 拖拽期间跟随光标的浮窗：渲染**真实组件视图的 1:1 尺寸**；
/// 载荷无视图时回退到名称胶囊（自动化探针走这条路径）。
/// 无边框、不接收鼠标（`ignoresMouseEvents`），层级高于抽屉与设置面板。
///
/// 窗口级阴影（`hasShadow`）必须关掉：落位飞行时窗口 frame 会被撑成
/// 「起点 ∪ 终点」的大矩形，窗口级阴影会随之变成一个巨大黑影。阴影改由
/// SwiftUI 画在真实内容边缘（见 `DragPreviewRoot`）。
/// 非 `private`：落位飞行协调器 `DragPreviewLanding` 在另一个文件里持有它。
@MainActor
final class DragPreviewPanel: NSPanel {
    /// 无视图载荷（名称胶囊回退）的窗口尺寸。
    static let fallbackSize = CGSize(width: 200, height: 32)

    private let state: DragPreviewState

    /// `fileprivate`：`DragPreviewState` 仍是 fileprivate，而本类型为了让
    /// `DragPreviewLanding` 能持有已放开为 internal。
    fileprivate init(state: DragPreviewState) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: DragPreviewRoot(state: state))
    }

    /// 按载荷尺寸设定窗口大小（`.zero` 表示回退到名称胶囊的固有尺寸）。
    func applyContentSize(_ size: CGSize) {
        let target = size.width > 0 && size.height > 0 ? size : Self.fallbackSize
        var frame = self.frame
        frame.size = target
        setFrame(frame, display: true)
    }

    /// 跟手期间内容的屏幕矩形：窗口尺寸恒等于内容尺寸，故就是窗口 frame。
    /// **仅在 `beginLanding` 之前有效**——飞行期间窗口被撑成
    ///「起点 ∪ 终点」的大矩形，frame 不再等于内容矩形。
    func contentScreenRect() -> CGRect { frame }

    /// 落位飞行：窗口 frame 一次性撑成「起点 ∪ 终点」的大矩形，内容用
    /// SwiftUI 偏移 spring 飞过去。
    ///
    /// 不用 `animator().setFrame` / `NSAnimationContext`：它们只吃
    /// `CAMediaTimingFunction`，表达不了 SwiftUI 的
    /// `spring(response:dampingFraction:)`，会与抽屉里其余位移动画
    /// （统一走 `DrawerAnimation.spring`）曲线不一致。窗口本身透明、
    /// `ignoresMouseEvents`、且无窗口级阴影，撑大没有任何副作用。
    ///
    /// 坐标换算：SwiftUI 的 offset 空间原点在左上，Cocoa 在左下。
    /// 只需相对量，故纵向统一用 `maxY` 做基准（它在两侧都是"上边缘"）：
    /// ```
    /// offsetX = from.minX − union.minX
    /// offsetY = union.maxY − from.maxY
    /// ```
    func beginLanding(from: CGRect, to: CGRect) {
        let union = from.union(to)
        state.contentOffset = CGPoint(
            x: from.minX - union.minX,
            y: union.maxY - from.maxY
        )
        setFrame(union, display: true)
        // fullSizeContentView 下显式对齐内容视图，避免布局时机差异。
        contentView?.frame = NSRect(origin: .zero, size: union.size)
        withAnimation(DrawerAnimation.spring) {
            state.contentOffset = CGPoint(
                x: to.minX - union.minX,
                y: union.maxY - to.maxY
            )
        }
    }
}

@MainActor
private final class DragPreviewState: ObservableObject {
    @Published var title = ""
    @Published var symbolName: String?
    @Published var isValid = true
    /// 真实组件视图（nil → 回退到名称胶囊，探针路径）。
    @Published var content: AnyView?
    /// 真实组件的 1:1 像素尺寸（回退时为 `.zero`）。
    @Published var contentSize: CGSize = .zero
    /// 落位飞行期间，内容在「起点 ∪ 终点」大窗口内的偏移（左上原点）。
    /// 非飞行时恒为零——窗口 frame 就是内容本身的大小。
    @Published var contentOffset: CGPoint = .zero

    func update(payload: BlockDragCoordinator.Payload, isValid: Bool) {
        title = payload.displayName
        symbolName = payload.symbolName
        self.isValid = isValid
        if let preview = payload.preview {
            content = preview.view
            contentSize = preview.size
        } else {
            content = nil
            contentSize = .zero
        }
    }
}

/// 浮窗根视图：真实组件（1:1）或名称胶囊回退。
private struct DragPreviewRoot: View {
    @ObservedObject var state: DragPreviewState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let content = state.content {
                content
                    .frame(width: state.contentSize.width, height: state.contentSize.height)
                    // 阴影贴在真实内容边缘（窗口级阴影已关，见 DragPreviewPanel）。
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            } else {
                DragPreviewChip(state: state)
            }
        }
        .offset(x: state.contentOffset.x, y: state.contentOffset.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }
}

private struct DragPreviewChip: View {
    @ObservedObject var state: DragPreviewState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbolName ?? "square.grid.2x2")
                .font(.system(size: 11, weight: .semibold))
            Text(state.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Image(systemName: state.isValid ? "plus.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(state.isValid ? 0.92 : 0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.06, green: 0.06, blue: 0.07).opacity(0.96))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    (state.isValid ? Color.white : Color.red).opacity(0.22),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - 拖拽起手手势

// 拖拽源手势（长按 0.3s 序列起手）由各卡片视图自行组装，
// 见 SettingsPages.swift 的 ComponentCard。
