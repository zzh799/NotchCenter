import SwiftUI

// MARK: - 抽屉块视图（服务名 + 开关 + 点击开网页 + 长按浮窗）

/// CalibrePlugin 的抽屉块：1×1 / 2×1 两种跨度（决策 11）。
/// - 点击开关以外区域 → 打开网页（探测端口优先，回退硬编码 URL）
/// - 长按（≥0.5s）→ 弹出独立 NSPanel 浮窗（决策 6）
struct CalibreServiceBlockView: View {
    @StateObject private var monitor: CalibreServiceMonitor

    init() {
        _monitor = StateObject(wrappedValue: CalibreServiceMonitor())
    }
    /// 块在宿主窗口坐标系中的 frame（GeometryReader 实时捕获），用于浮窗定位。
    @State private var frameInWindow: CGRect?
    /// 悬停高亮（DESIGN.md：悬停反馈 easeOut 0.10–0.13s）。
    @State private var isHovering = false
    /// 长按进行中：背景微亮提示浮窗即将弹出（GestureState，手势中断自动复位）。
    @GestureState private var isPressing = false

    var body: some View {
        baseContent
            .background(
                // NSHostingView 里 SwiftUI 的 .global 空间即宿主窗口坐标。
                // 块随抽屉动画/缩放移动时持续更新，长按弹出的锚点始终准确。
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frameInWindow = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            frameInWindow = newFrame
                        }
                }
            )
            .animation(.easeOut(duration: 0.16), value: monitor.message)
    }

    private var baseContent: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibre")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { monitor.isServiceOn },
                set: { _ in monitor.toggleRunning() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(monitor.isBusy)
        }
        .padding(.horizontal, 10)
        // 卡片背景占满组件（DESIGN.md §2.1）：近白半透明表面 + 发丝描边，
        // 悬停/长按微亮（§2.2 白色 alpha 层级）。frame 撑满外层容器提案的
        // 全部空间（DrawerBlockContainer 已按跨度定尺寸）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(isPressing ? 0.20 : 0.09), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isPressing)
        // 手势顺序：长按优先于点击；整卡（含背景区）都可长按弹浮窗，
        // 点击（非开关区）打开网页。开关自身消费点击不触发网页跳转。
        .simultaneousGesture(longPressGesture)
        .onTapGesture {
            if !isPressing {
                monitor.openWeb()
            }
        }
    }

    private var cardFill: Color {
        if isPressing { return Color.white.opacity(0.055) }
        if isHovering { return Color.white.opacity(0.04) }
        return Color.white.opacity(0.025)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
    }

    private var dotColor: Color {
        switch monitor.status.state {
        case .managed:
            return .green
        case .loadedNotRunning:
            return .yellow
        case .unmanagedExternal:
            return .orange
        case .portConflict:
            return .red
        case .stopped:
            return .gray
        }
    }

    private var subtitle: String {
        // busy 时直接把 Starting… / Stopping… 显示在状态位上，不单独占一行。
        if monitor.isBusy { return busyText }
        switch monitor.status.state {
        case .managed: return "Running · port \(monitor.status.port.map(String.init) ?? "—")"
        case .loadedNotRunning: return "Loaded, not running"
        case .unmanagedExternal: return "⚠️ Unmanaged process"
        case .portConflict(let n): return "⚠️ \(n) instances listening"
        case .stopped: return "Stopped"
        }
    }

    private var busyText: String {
        monitor.isServiceOn ? "Stopping…" : "Starting…"
    }

    // MARK: 长按手势

    /// 纯 LongPressGesture：按住满 0.5s 的瞬间即触发浮窗，**无需等鼠标
    /// 释放**。不能用 sequenced(before: DragGesture)——onEnded 会推迟到
    /// 第二阶段（拖拽）结束，浮窗变成松手后才弹出。挂在整卡上（含背景区）。
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                showPopover()
            }
            // 按下即点亮按压态；手势失败（提前松手/滚动）自动复位。
            .updating($isPressing) { _, state, _ in state = true }
    }

    private func showPopover() {
        guard let frameInWindow else { return }
        CalibrePopoverController.shared.present(
            monitor: monitor,
            frameInWindow: frameInWindow
        )
    }
}
