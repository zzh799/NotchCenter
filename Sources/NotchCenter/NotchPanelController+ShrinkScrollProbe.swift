#if DEBUG
import AppKit
import Foundation

// MARK: - 缩小场景滚动条探针（仅 DEBUG 构建）

extension NotchPanelController {
    // MARK: - 缩小场景滚动条逐帧诊断（NOTCHCENTER_SHRINKSCROLL_PROBE=1）

    /// 抽样器：逐帧输出抽屉宿主视图树下所有 NSScrollView 的内容高度/视口高度/
    /// 滚动条可见性。doc > clip 即“可滚动”= 滚动条亮起的充要条件；网格外层
    /// ScrollView 与插件块内部（如笔记编辑器）的滚动视图会同时出现，便于区分
    /// 用户看到的滚动条到底属于哪一层。
    func dumpScrollProbeSample(tag: String) {
        guard let pair = activePair ?? pairs.first, let host = pair.drawerHostingView else { return }
        NSLog("shrink-probe[%@] uiWindow=%@ uiContent=%@",
            tag,
            NSStringFromSize(uiState.drawerWindowSize),
            NSStringFromSize(uiState.drawerContentSize)
        )
        walkScrollViews(in: host, depth: 0, tag: tag)
    }

    private func walkScrollViews(in view: NSView, depth: Int, tag: String) {
        if depth < 24, let scroll = view as? NSScrollView {
            let docH = scroll.documentView?.frame.height ?? -1
            let clipH = scroll.contentView.bounds.height
            let vs = scroll.verticalScroller
            NSLog("shrink-probe[%@] SV d=%d %@ doc=%.1f clip=%.1f hasV=%@ vHidden=%@ vAlpha=%.2f",
                tag, depth, String(describing: type(of: scroll)), docH, clipH,
                String(describing: scroll.hasVerticalScroller),
                vs.map { String(describing: $0.isHidden) } ?? "nil",
                vs?.alphaValue ?? -1
            )
        }
        for sub in view.subviews {
            walkScrollViews(in: sub, depth: depth + 1, tag: tag)
        }
    }

    /// `NOTCHCENTER_SHRINKSCROLL_PROBE=1`（配 NOTCHCENTER_SMOKE_TEST=1）：
    /// 展开 → 进入编辑模式 → 按 NOTCHCENTER_SHRINK_KIND 执行一次多行→少行
    /// 缩小（remove=移除最底块；resize=合成鼠标把第一个多行块缩到 1 行；
    /// exitedit=退出编辑目录条收缩）→ 全程 30Hz 抽样 + 动画中逐帧自拍，
    /// 区分“外层网格滚动条”与“块内编辑器滚动条”。
    func runShrinkScrollProbe() {
        guard let pair = activePair ?? pairs.first else { return }
        let kind = ProcessInfo.processInfo.environment["NOTCHCENTER_SHRINK_KIND"] ?? "resize"

        var sampler: Timer?
        sampler = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.dumpScrollProbeSample(tag: "t")
            }
        }
        if let sampler { RunLoop.main.add(sampler, forMode: .common) }

        NSApp.activate(ignoringOtherApps: true)
        expand(animated: false, activate: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.startEditMode()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSLog("shrink-probe: kind=\(kind) target=\(ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_TARGET"] ?? "notes.notebook")")
            self.dumpScrollProbeSample(tag: "baseline")
            switch kind {
            case "remove":
                self.driveRemoveShrink()
            case "exitedit":
                self.stopEditMode()
            default:
                self.driveSyntheticShrinkResize(on: pair)
            }
        }

        // 动画中帧自拍（CGWindowListCreateImage 抓表现层，含过渡帧）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            self.captureDrawerWindowSamples(count: 40, interval: 0.05, prefix: "shrink")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
            self.dumpScrollProbeSample(tag: "final")
            self.capturePanelsForDebug(suffix: "_shrinkfinal")
            sampler?.invalidate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            NSApp.terminate(nil)
        }
    }

    /// 移除最底块（走与编辑模式 X 按钮完全相同的动作路径）。
    private func driveRemoveShrink() {
        guard let bottom = uiState.drawerElements.max(by: { lhs, rhs in
            let lrow = lhs.placement.originRow + lhs.placement.heightRows
            let rrow = rhs.placement.originRow + rhs.placement.heightRows
            return lrow < rrow
        }) else { return }
        NSLog("shrink-probe: removing \(bottom.placement.blockID)@(\(bottom.placement.originRow),\(bottom.placement.originColumn))")
        drawerActions().onRemoveBlock(bottom.placement.placementID)
    }

    /// 合成鼠标把第一个多行块缩小到 1 行（按下 → 上拖 → 抬起）。
    private func driveSyntheticShrinkResize(on pair: ScreenPanelPair) {
        let targetBlockID = ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_TARGET"] ?? "notes.notebook"
        guard let element = uiState.drawerElements.first(where: { $0.placement.blockID == targetBlockID })
            ?? uiState.drawerElements.first(where: { $0.placement.heightRows >= 2 })
            ?? uiState.drawerElements.first else {
            NSLog("shrink-probe: no drawer element found")
            return
        }
        let p = element.placement
        guard p.heightRows >= 2 else {
            NSLog("shrink-probe: target \(p.blockID) already 1 row")
            return
        }
        // 握把中心：块右下角向内 (5 padding + 11 半径) ≈ 16pt。
        let vx = NotchGridMetrics.contentPadding
            + CGFloat(p.originColumn) * (NotchGridMetrics.cellWidth + NotchGridMetrics.spacing)
            + NotchGridMetrics.contentWidth(columns: p.widthColumns) - 16
        let vy = pair.layout.compactHeight
            + NotchGridMetrics.drawerTopBarHeight
            + CGFloat(p.originRow) * (NotchGridMetrics.cellHeight + NotchGridMetrics.spacing)
            + NotchGridMetrics.contentHeight(rows: p.heightRows) - 16
        let frame = pair.drawerPanel.frame
        // 窗口固定满宽，可见面板在窗口内水平居中（DrawerPanelView L95-98
        // 同一几何；不补这个偏移会点到面板左侧的块上，手势永不触发）。
        let visibleMinX = frame.minX + (frame.width - uiState.drawerWindowSize.width) / 2
        var location = NSPoint(x: visibleMinX + vx, y: frame.maxY - vy)
        NSLog("shrink-probe: shrink target=%@ handle=%@ rows %d -> 1",
            p.blockID, NSStringFromPoint(location), p.heightRows
        )

        func send(_ type: NSEvent.EventType) {
            let primaryFrame = debugPrimaryScreenFrame()
            let cgLocation = CGPoint(x: location.x, y: primaryFrame.maxY - location.y)
            let mouseType: CGEventType = switch type {
            case .mouseMoved: .mouseMoved
            case .leftMouseDown: .leftMouseDown
            case .leftMouseDragged: .leftMouseDragged
            default: .leftMouseUp
            }
            CGEvent(
                mouseEventSource: CGEventSource(stateID: .combinedSessionState),
                mouseType: mouseType,
                mouseCursorPosition: cgLocation,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }

        let stepH = NotchGridMetrics.cellHeight + NotchGridMetrics.spacing
        let totalUp = CGFloat(p.heightRows - 1) * stepH  // 2 行 → 1 行 = 132pt
        let steps = max(Int(totalUp / 44.0), 4)
        let perStep = totalUp / CGFloat(steps)
        // 跳变事件会被光标轮询驱动的穿透（ignoresMouseEvents）丢掉：先
        // mouseMoved 停留让轮询翻转为可接收，再按下/逐帧拖动/抬起。
        // 与 driveSyntheticCatalogDrag 同一前提（见其注释）。
        send(.mouseMoved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            send(.leftMouseDown)
            self.dumpScrollProbeSample(tag: "down")
            for step in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(step)) {
                    location.y += perStep
                    send(.leftMouseDragged)
                    self.dumpScrollProbeSample(tag: "drag\(step)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + 0.15 * Double(steps) + 0.3) {
            send(.leftMouseUp)
            NSLog("shrink-probe: mouse up at %@", NSStringFromPoint(location))
        }
    }
}
#endif
