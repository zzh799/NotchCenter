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

    /// 被拖动的块（设置面板构造，只描述身份与默认跨度，不含视图）。
    struct Payload: Equatable {
        let pluginID: String
        let blockID: String
        let kind: BlockKind
        let displayName: String
        let symbolName: String?
        /// 抽屉块的默认跨度；紧凑块为 1×1（落点高亮不使用）。
        /// 用 `GridSpan` 而非元组：元组不参与 `Equatable` 自动合成。
        let span: GridSpan

        var isCompact: Bool { kind == .compact }
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

    /// 幂等起手：`DragGesture.onChanged` 每帧都会调用，只有第一次生效。
    func beginIfNeeded(_ payload: Payload) {
        guard self.payload == nil else {
            updatePointer()
            return
        }
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
    }

    /// 松手：有效落点即落位；无效落点静默取消。
    func commit() {
        guard let payload, let controller else {
            teardown()
            return
        }
        if let zone {
            controller.performBlockDrop(payload, to: zone)
        }
        teardown()
    }

    /// 主动取消（Escape / 会话异常）。
    func cancel() {
        teardown()
    }

    private func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
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
            matching: [.leftMouseDragged, .mouseMoved, .leftMouseUp]
        ) { [weak self] event in
            if event.type == .leftMouseUp {
                MainActor.assumeIsolated { self?.commit() }
            } else {
                MainActor.assumeIsolated { self?.updatePointer() }
            }
            return event
        }
    }

    // MARK: 跟随光标的预览浮窗

    private func showPreview() {
        if previewPanel == nil {
            previewPanel = DragPreviewPanel(state: previewState)
        }
        previewPanel?.orderFrontRegardless()
    }

    private func hidePreview() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }

    /// 浮窗挂在光标右下（偏移避免压住指针热点）。
    private func positionPreview(at location: NSPoint) {
        let offset = NSPoint(x: 14, y: -34)
        previewPanel?.setFrameOrigin(
            NSPoint(x: location.x + offset.x, y: location.y + offset.y)
        )
    }
}

// MARK: - 预览浮窗

/// 拖拽期间跟随光标的小标签：块名 + 有效性着色（无效落点为红色调）。
/// 无边框、不接收鼠标（`ignoresMouseEvents`），层级高于抽屉与设置面板。
@MainActor
private final class DragPreviewPanel: NSPanel {
    init(state: DragPreviewState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: DragPreviewChip(state: state))
    }
}

private final class DragPreviewState: ObservableObject {
    @Published var title = ""
    @Published var symbolName: String?
    @Published var isValid = true

    func update(payload: BlockDragCoordinator.Payload, isValid: Bool) {
        title = payload.displayName
        symbolName = payload.symbolName
        self.isValid = isValid
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
