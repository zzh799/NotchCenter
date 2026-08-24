#if DEBUG
import AppKit
import Foundation

// MARK: - 目录条拖动自动化探针（仅 DEBUG 构建）

extension NotchPanelController {
    /// `NOTCHCENTER_DRAGSCROLL_AUTO=1`（配 NOTCHCENTER_SMOKE_TEST=1 与
    /// NOTCHCENTER_DRAGSCROLL_LOG=1）：展开抽屉 → 进入编辑模式 → 合成鼠标
    /// 在目录条上栏按住横向拖动，观察探针命中/手势事件/clipView 落点。
    /// 用于复现"目录条拖不动"。
    func runDragScrollAutoDiagnostic() {
        guard let pair = activePair ?? pairs.first else { return }
        expand(animated: false, activate: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startEditMode()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            self.driveSyntheticCatalogDrag(on: pair)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            self.capturePanelsForDebug(suffix: "_dragscroll")
            NSApp.terminate(nil)
        }
    }

    /// 在目录条上栏（Compact 行）合成按住左移的拖动。先 mouseMoved 停留
    /// 让光标轮询翻转 ignoresMouseEvents（跳变事件会被穿透丢掉），再
    /// 按下/逐帧拖动/抬起；每帧 15pt、共 8 帧，总位移 120pt。
    private func driveSyntheticCatalogDrag(on pair: ScreenPanelPair) {
        NSApp.activate(ignoringOtherApps: true)
        let frame = pair.drawerPanel.frame
        // 可见面板在固定满宽窗口内水平居中（DrawerPanelView L95-98 同一几何）。
        let visibleWidth = uiState.drawerWindowSize.width
        let visibleMinX = frame.minX + (frame.width - visibleWidth) / 2
        // 下栏（Drawer 行）行中心：紧凑带 + 顶栏 + 目录条上内边距 +
        // 上栏整行 + 行距 + 半行高（下栏按插件分组,内容必然溢出视口）。
        let vy = pair.layout.compactHeight
            + NotchGridMetrics.drawerTopBarHeight
            + 7
            + AddBlockArea.rowHeight
            + 6
            + AddBlockArea.rowHeight / 2
        var location = NSPoint(x: visibleMinX + 40, y: frame.maxY - vy)
        NSLog(
            "dragscroll-auto: start=%@ visibleMinX=%.1f drawerFrame=%@",
            NSStringFromPoint(location),
            visibleMinX,
            NSStringFromRect(frame)
        )

        func send(_ type: CGEventType, at point: NSPoint) {
            let primaryFrame = debugPrimaryScreenFrame()
            let cgLocation = CGPoint(x: point.x, y: primaryFrame.maxY - point.y)
            let source = CGEventSource(stateID: .combinedSessionState)
            CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: cgLocation,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }

        send(.mouseMoved, at: location)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            send(.leftMouseDown, at: location)
        }
        let steps = 8
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + 0.15 * Double(step)) {
                location.x -= 15
                send(.leftMouseDragged, at: location)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + 0.15 * Double(steps) + 0.2) {
            send(.leftMouseUp, at: location)
            NSLog("dragscroll-auto: released at %@", NSStringFromPoint(location))
        }
    }
}
#endif
