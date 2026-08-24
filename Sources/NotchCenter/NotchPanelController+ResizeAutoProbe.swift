#if DEBUG
import AppKit
import Foundation

// MARK: - 缩放自动化探针（合成鼠标驱动真实缩放握把，仅 DEBUG 构建）

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
        // 点击链路验证：向铅笔按钮注入真实点击，观察编辑切换是否发生。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            self.injectSyntheticClick(on: pair, atContentX: 608, contentYFromTop: 50)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            self.dumpResizeDiagnosticState(tag: "after-pencil-click")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            self.driveSyntheticResize(on: pair)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
            self.capturePanelsForDebug(suffix: "_resizecommit")
            self.dumpResizeDiagnosticState(tag: "after-commit")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            NSApp.terminate(nil)
        }
    }

    /// 注入单次点击（HID tap）。先注入 mouseMoved 停留 ~150ms 让 30Hz
    /// 光标轮询翻转 `ignoresMouseEvents`（真实用户是连续移入，合成事件
    /// 是跳变，直接点击会与轮询竞态被穿透丢掉），再按下/抬起。
    private func injectSyntheticClick(on pair: ScreenPanelPair, atContentX vx: CGFloat, contentYFromTop vy: CGFloat) {
        let primaryFrame = debugPrimaryScreenFrame()
        let frame = pair.drawerPanel.frame
        let x = frame.minX + vx
        let y = frame.maxY - vy
        let cg = CGPoint(x: x, y: primaryFrame.maxY - y)
        NSLog("click-probe injecting click at screen=%@ cg=%@", NSStringFromPoint(NSPoint(x: x, y: y)), NSStringFromPoint(cg))
        let source = CGEventSource(stateID: .combinedSessionState)
        let events: [(CGEventType, Double)] = [
            (.mouseMoved, 0.0),
            (.leftMouseDown, 0.18),
            (.leftMouseUp, 0.26),
        ]
        for (type, offset) in events {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: cg,
                    mouseButton: .left
                )
                event?.post(tap: .cghidEventTap)
            }
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
        let vy = pair.layout.compactHeight
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
            let primaryFrame = debugPrimaryScreenFrame()
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
