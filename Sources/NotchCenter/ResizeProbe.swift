#if DEBUG
import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 缩放管线诊断（仅 DEBUG 构建）

/// 真实管线的日志开关：`NOTCHCENTER_RESIZE_LOG=1` 时把每个缩放事件
/// （translation → continuous → preview）打到控制台，供拖拽时观察。
enum ResizeProbeLog {
    static let isEnabled = ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_LOG"] == "1"

    static func resizeEvent(
        translation: CGSize,
        continuousColumns: CGFloat,
        continuousRows: CGFloat,
        preview: GridSpan
    ) {
        guard isEnabled else { return }
        NSLog(
            "resize t=(%+.1f, %+.1f) continuous=(%.2f, %.2f) preview=%dx%d",
            translation.width,
            translation.height,
            continuousColumns,
            continuousRows,
            preview.columns,
            preview.rows
        )
    }
}

/// 缩放握把管线诊断页：`NOTCHCENTER_RESIZE_PROBE=1` 启动。
/// 1:1 复刻 `DrawerBlockContainer` 的结构——外层按 placement 定位、
/// 内容按预览跨度重设尺寸、半增量偏移补偿锚定左上角、右下角握把
/// `highPriorityGesture`。可切换手势坐标系对照：
/// - `.local`（复现 bug）：预览增长 → 握把连同其 local 空间平移一格 →
///   translation 瞬间反跳一格 → 缩回 → 恢复……逐事件自激振荡，
///   在原大小/目标大小间逐像素切换；
/// - `.global`（修复后）：平移量锚定窗口，只跟真实鼠标位移。
/// 每个事件把 translation → continuous → raw → preview 输出到控制台与页面日志。
@MainActor
final class ResizeProbeWindowController {
    static let shared = ResizeProbeWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Resize Probe"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResizeProbeView())
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ResizeProbeView: View {
    @State private var usesLocalSpace = false
    @State private var previewColumns = 2
    @State private var logLines: [String] = []

    /// 固定 placement 2×1（只演示列方向缩放，机制对行方向同理）。
    private let placementColumns = 2
    private let placementRows = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Coordinate space", selection: $usesLocalSpace) {
                Text("global (fixed)").tag(false)
                Text("local (reproduces flicker)").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 380)

            Text("Drag the bottom-right handle slowly across one cell width; watch the log below (also NSLog).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            grid

            HStack {
                Button("Reset") {
                    previewColumns = placementColumns
                    append("reset preview=\(previewColumns)×\(placementRows)")
                }
                Button("Clear log") { logLines.removeAll() }
                Spacer()
                Text("preview: \(previewColumns)×\(placementRows)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logLines.suffix(300).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 200)
            .background(.quaternary.opacity(0.3))
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 600)
    }

    /// 复刻 grid 中的定位：外框按 placement、.position 居中（ oversized 内容
    /// 在 frame 内居中后由容器内偏移补偿，与真实实现完全一致）。
    private var grid: some View {
        ZStack(alignment: .topLeading) {
            block
                .frame(
                    width: NotchGridMetrics.contentWidth(columns: placementColumns),
                    height: NotchGridMetrics.contentHeight(rows: placementRows)
                )
                .position(
                    x: NotchGridMetrics.contentWidth(columns: placementColumns) / 2,
                    y: NotchGridMetrics.contentHeight(rows: placementRows) / 2
                )
        }
        .frame(
            width: NotchGridMetrics.contentWidth(columns: 4),
            height: NotchGridMetrics.contentHeight(rows: placementRows) + 32
        )
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 复刻容器内部：内容按预览跨度设尺寸 + 半增量偏移（左上角锚定）+ 握把。
    private var block: some View {
        let previewWidth = NotchGridMetrics.contentWidth(columns: previewColumns)
        let placementWidth = NotchGridMetrics.contentWidth(columns: placementColumns)
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))
            Text("\(previewColumns)×\(placementRows)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(
            width: previewWidth,
            height: NotchGridMetrics.contentHeight(rows: placementRows)
        )
        .offset(x: (previewWidth - placementWidth) / 2)
        .overlay(alignment: .bottomTrailing) {
            handle
                .padding(5)
        }
    }

    private var handle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(0.14)))
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(
                    minimumDistance: 1,
                    coordinateSpace: usesLocalSpace ? .local : .global
                )
                .onChanged { value in
                    handleDrag(value.translation)
                }
                .onEnded { _ in
                    append("commit preview=\(previewColumns)×\(placementRows)")
                }
            )
    }

    /// 与 `handleResizeTranslate` 相同的管线：连续值 → 死区量化 → 预览。
    private func handleDrag(_ translation: CGSize) {
        let step = NotchGridMetrics.cellWidth + NotchGridMetrics.spacing
        let continuous = CGFloat(placementColumns) + translation.width / step
        let raw = ResizeHysteresis.quantized(continuous, current: previewColumns)
        append(
            String(
                format: "t=%+7.1f continuous=%.2f raw=%d preview %d→%d",
                translation.width,
                continuous,
                raw,
                previewColumns,
                raw
            )
        )
        previewColumns = raw
    }

    private func append(_ line: String) {
        NSLog("resize-probe %@", line)
        logLines.append(line)
        if logLines.count > 600 {
            logLines.removeFirst(logLines.count - 600)
        }
    }
}

// MARK: - 自动化缩放复现（向自身事件队列合成鼠标事件，无需辅助功能权限）

extension NotchPanelController {
    /// `NOTCHCENTER_RESIZE_AUTO=1`：展开抽屉 → 进入编辑模式 → 合成鼠标
    /// 按下/拖动/抬起驱动真实缩放握把，逐步打印候选跨度、推挤结果与
    /// 窗口尺寸；配合 `NOTCHCENTER_RESIZE_LOG=1` 观察完整管线，
    /// 中途与提交后各截一张图。用于复现“扩大时下方不推挤/面板不增高”。
    func runResizeAutoDiagnostic() {
        guard let pair = activePair ?? pairs.first else { return }
        expand(animated: false, activate: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startEditMode()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            self.dumpResizeDiagnosticState(tag: "before-drag")
            // 真实用户点击会经 onMouseEvent 激活应用并置 key；手势系统对
            // 非激活窗口可能忽略事件，诊断序列显式对齐该状态。
            NSApp.activate(ignoringOtherApps: true)
            pair.drawerPanel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.driveSyntheticResize(on: pair)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            self.capturePanelsForDebug(suffix: "_resizecommit")
            self.dumpResizeDiagnosticState(tag: "after-commit")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            NSApp.terminate(nil)
        }
    }

    private func dumpResizeDiagnosticState(tag: String) {
        let blocks = uiState.drawerElements
            .map { "\($0.placement.blockID)@\($0.placement.originColumn),\($0.placement.originRow) \($0.placement.widthColumns)x\($0.placement.heightRows)" }
            .joined(separator: " | ")
        NSLog(
            "resize-auto[%@] uiWindowSize=%@ drawerFrame=%@",
            tag,
            NSStringFromSize(uiState.drawerWindowSize),
            NSStringFromRect(activePair?.drawerPanel.frame ?? .zero)
        )
        NSLog("resize-auto[%@] blocks=%@", tag, blocks)
    }

    private func driveSyntheticResize(on pair: ScreenPanelPair) {
        // 目标块：NOTCHCENTER_RESIZE_TARGET 指定（默认 Notebook）。
        let targetBlockID = ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_TARGET"]
            ?? "notes.notebook"
        guard let element = uiState.drawerElements.first(where: { $0.placement.blockID == targetBlockID })
            ?? uiState.drawerElements.first else {
            NSLog("resize-auto: no drawer element found")
            return
        }
        let p = element.placement
        let addBlockHeight = AddBlockArea.height(for: uiState.catalogPlugins)
        // 握把中心：块右下角向内 (5 padding + 11 半径) ≈ 16pt。
        let vx = NotchGridMetrics.contentPadding
            + CGFloat(p.originColumn) * (NotchGridMetrics.cellWidth + NotchGridMetrics.spacing)
            + NotchGridMetrics.contentWidth(columns: p.widthColumns) - 16
        let vy = pair.layout.compactSize.height
            + NotchGridMetrics.drawerTopBarHeight
            + addBlockHeight
            + CGFloat(p.originRow) * (NotchGridMetrics.cellHeight + NotchGridMetrics.spacing)
            + NotchGridMetrics.contentHeight(rows: p.heightRows) - 16
        let frame = pair.drawerPanel.frame
        var location = NSPoint(x: frame.minX + vx, y: frame.maxY - vy)
        NSLog(
            "resize-auto: target=%@ handle=%@ drawerFrame=%@",
            p.blockID,
            NSStringFromPoint(location),
            NSStringFromRect(frame)
        )

        func send(_ type: NSEvent.EventType, eventNumber: Int) {
            // SwiftUI 手势不认无 CGEvent 底衬的纯 NSEvent；经 CGEventPostToPid
            // 投递给自身进程（无需辅助功能权限），由窗口服务器按光标位置
            // 正常路由到本应用窗口。CG 全局坐标以上主屏左上为原点（y 向下），
            // AppKit 全局坐标以其左下为原点（y 向上）。
            let primaryFrame = NSScreen.screens.first { $0.frame.origin == .zero }?.frame
                ?? NSScreen.main?.frame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let cgLocation = CGPoint(x: location.x, y: primaryFrame.maxY - location.y)
            let mouseType: CGEventType = switch type {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseDragged: .leftMouseDragged
            default: .leftMouseUp
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: mouseType,
                mouseCursorPosition: cgLocation,
                mouseButton: .left
            )
            event?.post(tap: .cghidEventTap)
        }

        // 拖动 (42, 132)：垂直方向一格 → 目标跨度 2x2，应推挤下方块并增高窗口。
        let steps = 6
        let perStep = CGSize(width: 42.0 / 6.0, height: 132.0 / 6.0)
        send(.leftMouseDown, eventNumber: 1)
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(step)) {
                location.x += perStep.width
                location.y -= perStep.height
                send(.leftMouseDragged, eventNumber: step + 1)
                NSLog("resize-auto: dragged -> %@", NSStringFromPoint(location))
                // 每步后即刻观察：预览期间窗口是否已增高（uiWindowSize 领先于提交）。
                self.dumpResizeDiagnosticState(tag: "step\(step)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(steps) + 0.25) {
            self.capturePanelsForDebug(suffix: "_resizepreup")
            send(.leftMouseUp, eventNumber: steps + 2)
            NSLog("resize-auto: mouse up")
        }
    }
}
#endif
