#if DEBUG
import AppKit
import SwiftUI

// MARK: - 缩放管线诊断复现页（仅 DEBUG 构建）

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
#endif
